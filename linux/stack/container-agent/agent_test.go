package main

import (
	"bytes"
	"context"
	"encoding/base64"
	"encoding/json"
	"fmt"
	"log"
	"os"
	"slices"
	"strings"
	"testing"
	"time"
)

const classToken = "class-token-SENTINEL"

func dockerTask(id string) *taskConfig {
	tc := &taskConfig{TaskID: id}
	tc.Job.Config.Docker = []containerCfg{
		{Image: "cimg/base:stable", Entrypoint: []string{"/bin/sh"}, Command: []string{"-c", "sleep 1"}, User: "circleci", Environment: map[string]string{"A": "1", "B": "${BUILT}"}},
		{Image: "cimg/postgres:16.0", Environment: map[string]string{"POSTGRES_USER": "u"}},
	}
	tc.Environment.BuiltIn = map[string]string{"BUILT": "built-in-value"}
	return tc
}

type harness struct {
	a  *agent
	e  *fakeEngine
	r  *fakeRunner
	cl *class
}

func newHarness(t *testing.T, tasks ...*taskConfig) *harness {
	t.Helper()
	e, sock := newFakeEngine(t)
	r := newFakeRunner(t, classToken, tasks...)
	cl := &class{Name: "ns/docker", token: secret(classToken), Primary: limits{CPUs: 2, MemoryMB: 4096}, Service: limits{CPUs: 0.5, MemoryMB: 1024, Pids: 100}}
	cfg := &config{RunnerAPI: r.srv.URL, PauseImage: "pause:1", MaxTasks: 2, MaxRunTime: time.Hour, PollEvery: 10 * time.Millisecond, Name: "node-1",
		Pull: "always", Classes: []*class{cl}}
	return &harness{a: &agent{cfg: cfg, api: newRunnerAPI(r.srv.URL), d: newDocker(sock), sem: make(chan struct{}, cfg.MaxTasks)}, e: e, r: r, cl: cl}
}

func (h *harness) runClaimed(t *testing.T) {
	t.Helper()
	c, err := h.a.api.claimTask(context.Background(), h.cl.token, "node-1", "node-1")
	if err != nil || c == nil {
		t.Fatalf("claim: %v %v", c, err)
	}
	h.a.runTask(context.Background(), h.cl, c)
}

func (h *harness) assertClean(t *testing.T) {
	t.Helper()
	h.e.mu.Lock()
	defer h.e.mu.Unlock()
	if len(h.e.ctrs)+len(h.e.networks)+len(h.e.volumes) != 0 {
		t.Errorf("left behind: %d containers, %d networks, %d volumes", len(h.e.ctrs), len(h.e.networks), len(h.e.volumes))
	}
}

func TestTaskPodLayout(t *testing.T) {
	h := newHarness(t, dockerTask("Task-0001"))
	h.runClaimed(t)

	h.e.mu.Lock()
	order := slices.Clone(h.e.order)
	h.e.mu.Unlock()
	n := "cci-" + shortID("Task-0001")
	want := []string{"create:" + n + "-init", "start:" + n + "-init", "create:" + n + "-pause", "start:" + n + "-pause",
		"create:" + n + "-svc1", "start:" + n + "-svc1", "create:" + n + "-primary", "start:" + n + "-primary"}
	if !slices.Equal(order, want) {
		t.Fatalf("order %v, want %v", order, want)
	}
	if ev := h.r.eventsCopy(); !slices.Equal(ev, []string{"cleanup"}) {
		t.Errorf("events %v, want only cleanup", ev)
	}
	h.assertClean(t)
	if !slices.Contains(h.e.pulled, "circleci/runner-init:agent") || !slices.Contains(h.e.pulled, "pause:1") {
		t.Errorf("pulled %v", h.e.pulled)
	}
}

func TestContainerSpecs(t *testing.T) {
	h := newHarness(t, dockerTask("Task-0001"))
	// execute alone leaves the containers in the fake engine, so the specs can be read; runTask would remove them
	c, _ := h.a.api.claimTask(context.Background(), h.cl.token, "n", "n")
	tc, _ := h.a.api.taskConfig(context.Background(), c.TaskToken)
	exit, err := h.a.execute(context.Background(), h.cl, c, tc, "t1")
	if err != nil || exit != 0 {
		t.Fatalf("execute: %d %v", exit, err)
	}
	h.e.mu.Lock()
	primary, svc, pause, init := h.e.byRole("primary")[0].spec, h.e.byRole("service")[0].spec, h.e.byRole("pause")[0].spec, h.e.byRole("init")[0].spec
	h.e.mu.Unlock()

	if got := primary.HostConfig.NetworkMode; got != "container:id-cci-t1-pause" || svc.HostConfig.NetworkMode != got {
		t.Errorf("primary and service must join the pause container's network: %q %q", got, svc.HostConfig.NetworkMode)
	}
	if pause.HostConfig.NetworkMode != "cci-t1" || init.HostConfig.NetworkMode != "none" {
		t.Errorf("pause on the task network, init on none: %q %q", pause.HostConfig.NetworkMode, init.HostConfig.NetworkMode)
	}
	if !slices.Equal(primary.Entrypoint, []string{"/opt/circleci/bin/orchestrator"}) || !slices.Equal(primary.Cmd, []string{"run-task"}) {
		t.Errorf("primary command %v %v", primary.Entrypoint, primary.Cmd)
	}
	if !slices.Equal(primary.HostConfig.Binds, []string{"cci-t1-bin:/opt/circleci/bin"}) || len(svc.HostConfig.Binds) != 0 {
		t.Errorf("only the primary mounts the init volume: %v %v", primary.HostConfig.Binds, svc.HostConfig.Binds)
	}
	for _, s := range []ctrSpec{primary, svc, pause, init} {
		for _, b := range s.HostConfig.Binds {
			if strings.Contains(b, "docker.sock") {
				t.Errorf("a job container got the socket: %v", b)
			}
		}
	}
	if primary.HostConfig.NanoCpus != 2e9 || primary.HostConfig.Memory != 4096<<20 || primary.HostConfig.MemorySwap != primary.HostConfig.Memory {
		t.Errorf("primary limits: %+v", primary.HostConfig)
	}
	if svc.HostConfig.NanoCpus != 5e8 || svc.HostConfig.Memory != 1024<<20 || svc.HostConfig.PidsLimit != 100 {
		t.Errorf("service limits: %+v", svc.HostConfig)
	}
	if primary.User != "circleci" || !slices.Contains(primary.Env, "B=built-in-value") || !slices.Contains(primary.Env, "A=1") {
		t.Errorf("primary user %q env %v (the job user is the container user, variables expand)", primary.User, primary.Env)
	}
	var goat goatConfig
	for _, e := range primary.Env {
		if v, ok := strings.CutPrefix(e, "CIRCLECI_GOAT_CONFIG="); ok {
			if err := json.Unmarshal([]byte(v), &goat); err != nil {
				t.Fatal(err)
			}
		}
	}
	if goat.Token != "task-token-0" || goat.Allocation != "alloc-1" || goat.User != "" || goat.TaskAgentPath != "/opt/circleci/bin/circleci-agent" ||
		goat.RunnerAPIBaseURL != h.r.srv.URL || !slices.Equal(goat.Cmd, []string{"/bin/sh", "-c", "sleep 1"}) || goat.MaxRunTime != time.Hour {
		t.Errorf("goat config %+v", goat)
	}
	for _, s := range []ctrSpec{svc, pause, init} {
		for _, e := range s.Env {
			if strings.Contains(e, "task-token") || strings.Contains(e, "GOAT") {
				t.Errorf("the task token reached a container other than the primary: %v", e)
			}
		}
	}
	if !slices.Equal(svc.Env, []string{"POSTGRES_USER=u"}) {
		t.Errorf("service env %v", svc.Env)
	}
}

func TestPrimaryFailureReportsAndCleansUp(t *testing.T) {
	h := newHarness(t, dockerTask("Task-0002"))
	h.e.exit["primary"] = 3
	h.runClaimed(t)
	ev := h.r.eventsCopy()
	if len(ev) != 2 || !strings.HasPrefix(ev[0], "fail:") || ev[1] != "cleanup" {
		t.Fatalf("events %v", ev)
	}
	msg, _ := base64.StdEncoding.DecodeString(strings.TrimPrefix(ev[0], "fail:"))
	if !strings.Contains(string(msg), "exited with code 3") {
		t.Errorf("message %q", msg)
	}
	h.assertClean(t)
}

func TestKeepFailedLeavesTheContainersOfAFailedTask(t *testing.T) {
	h := newHarness(t, dockerTask("Task-0009"), dockerTask("Task-0010"))
	h.a.cfg.KeepFailed = true
	h.e.exit["primary"] = 1
	h.runClaimed(t)
	if len(h.e.ctrs) == 0 || len(h.e.networks) != 1 {
		t.Errorf("a failed task must stay for inspection: %d containers, %d networks", len(h.e.ctrs), len(h.e.networks))
	}
	h.e.exit["primary"] = 0
	h.runClaimed(t)
	if n, _ := h.a.d.sweep(context.Background(), labelManaged); n == 0 {
		t.Error("the start-up sweep must remove what was kept")
	}
	h.assertClean(t)
}

func TestSetupFailureIsUnclaimedAndCleanedUp(t *testing.T) {
	h := newHarness(t, dockerTask("Task-0003"))
	h.e.failPull = "cimg/postgres:16.0"
	h.runClaimed(t)
	if ev := h.r.eventsCopy(); len(ev) != 2 || ev[0] != "unclaim:Task-0003" || ev[1] != "cleanup" {
		t.Fatalf("events %v", ev)
	}
	h.assertClean(t)
	if len(h.e.order) != 0 {
		t.Errorf("containers started although a pull failed: %v", h.e.order)
	}
}

func TestSetupFailureWithNoRetriesLeftFails(t *testing.T) {
	h := newHarness(t, dockerTask("Task-0004"))
	h.e.failPull = "cimg/base:stable"
	h.r.unclaim409 = true
	h.runClaimed(t)
	ev := h.r.eventsCopy()
	if len(ev) != 3 || !strings.HasPrefix(ev[0], "unclaim:") || !strings.HasPrefix(ev[1], "fail:") {
		t.Fatalf("events %v", ev)
	}
}

func TestMachineJobOnContainerClassFails(t *testing.T) {
	h := newHarness(t, &taskConfig{TaskID: "m1"})
	h.runClaimed(t)
	ev := h.r.eventsCopy()
	if len(ev) != 1 || !strings.HasPrefix(ev[0], "fail:") || len(h.e.order) != 0 {
		t.Fatalf("events %v, containers %v", ev, h.e.order)
	}
}

func TestStartupSweepRemovesOnlyOurOrphans(t *testing.T) {
	h := newHarness(t)
	ours := map[string]string{"machine-runner-swarm.container-mode": "1"}
	h.e.ctrs["id-a"] = &fakeCtr{name: "a", spec: ctrSpec{Labels: ours}}
	h.e.ctrs["id-b"] = &fakeCtr{name: "b", spec: ctrSpec{Labels: map[string]string{"app": "other"}}}
	h.e.networks["n1"], h.e.networks["n2"] = ours, map[string]string{}
	h.e.volumes["v1"], h.e.volumes["v2"] = ours, map[string]string{}
	n, err := h.a.d.sweep(context.Background(), labelManaged)
	if err != nil || n != 3 {
		t.Fatalf("sweep: %d %v", n, err)
	}
	if len(h.e.ctrs) != 1 || h.e.ctrs["id-b"] == nil || len(h.e.networks) != 1 || len(h.e.volumes) != 1 {
		t.Errorf("left: %v %v %v", h.e.ctrs, h.e.networks, h.e.volumes)
	}
}

func TestConcurrencyCapAndClaimOnlyWithFreeSlot(t *testing.T) {
	h := newHarness(t, dockerTask("Task-0005"), dockerTask("Task-0006"), dockerTask("Task-0007"))
	h.a.cfg.MaxTasks = 1
	h.a.sem = make(chan struct{}, 1)
	h.e.hold = 150 * time.Millisecond
	ctx, cancel := context.WithCancel(context.Background())
	done := make(chan struct{})
	go func() { h.a.run(ctx); close(done) }()
	deadline := time.Now().Add(10 * time.Second)
	for time.Now().Before(deadline) {
		if ev := h.r.eventsCopy(); len(ev) == 3 {
			break
		}
		time.Sleep(20 * time.Millisecond)
	}
	cancel()
	<-done
	h.e.mu.Lock()
	defer h.e.mu.Unlock()
	if h.e.maxRunning != 1 {
		t.Errorf("max concurrent primaries %d, want 1", h.e.maxRunning)
	}
	if len(h.r.eventsCopy()) != 3 {
		t.Errorf("events %v", h.r.eventsCopy())
	}
}

func TestTokensStayOutOfLogsAndErrors(t *testing.T) {
	var buf bytes.Buffer
	log.SetOutput(&buf)
	defer log.SetOutput(os.Stderr)
	h := newHarness(t, dockerTask("Task-0008"))
	h.e.exit["primary"] = 1
	h.e.failPull = "pause:1"
	h.runClaimed(t)
	h.e.failPull = ""
	h.runClaimedMissing(t)
	if strings.Contains(buf.String(), "task-token") || strings.Contains(buf.String(), classToken) {
		t.Errorf("a token is in the log:\n%s", buf.String())
	}
	if s := fmt.Sprintf("%v %+v %s", claim{TaskToken: "task-token-x"}, secret("task-token-x"), secret("task-token-x")); strings.Contains(s, "task-token") {
		t.Errorf("secret prints as %q", s)
	}
}

// runClaimedMissing runs a claim whose config call fails (unknown task), to exercise that error path.
func (h *harness) runClaimedMissing(t *testing.T) {
	t.Helper()
	h.a.runTask(context.Background(), h.cl, &claim{TaskToken: "task-token-9", Allocation: "x"})
}

func TestReadToken(t *testing.T) {
	dir := t.TempDir()
	for body, want := range map[string]string{"abc123\n": "abc123", "api:\n  auth_token: \"xyz\"\n": "xyz", "api:\n  auth_token: plain\n": "plain"} {
		p := dir + "/t"
		_ = os.WriteFile(p, []byte(body), 0o600)
		got, err := readToken(p)
		if err != nil || got.Raw() != want {
			t.Errorf("%q: got %q, %v", body, got.Raw(), err)
		}
	}
	_ = os.WriteFile(dir+"/e", []byte("  \n"), 0o600)
	if _, err := readToken(dir + "/e"); err == nil {
		t.Error("an empty token file must fail")
	}
}

func TestRegistryAuthAndAWS(t *testing.T) {
	c := containerCfg{Auth: &authConfig{Auth: secret(base64.StdEncoding.EncodeToString([]byte("user:pw"))), ServerAddress: "r.example"}}
	a, err := registryAuth(&c)
	if err != nil {
		t.Fatal(err)
	}
	b, _ := base64.URLEncoding.DecodeString(a)
	var m map[string]string
	_ = json.Unmarshal(b, &m)
	if m["username"] != "user" || m["password"] != "pw" || m["serveraddress"] != "r.example" {
		t.Errorf("auth %v", m)
	}
	if _, err := registryAuth(&containerCfg{AWSAuth: &struct{}{}}); err == nil {
		t.Error("aws_auth must be rejected until it is supported")
	}
}
