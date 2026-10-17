package main

// Tests of the wrapper across the Driver interface only: a fake driver stands in for the container engine, so these
// tests say what the wrapper asks of a driver, what it does with each kind of answer, and nothing about containers.

import (
	"bytes"
	"context"
	"encoding/base64"
	"errors"
	"fmt"
	"log"
	"os"
	"slices"
	"strings"
	"sync"
	"testing"
	"time"
)

// fakeDriver is a Driver whose tasks run a script. It records what the wrapper gave it.
type fakeDriver struct {
	mu         sync.Mutex
	newErr     error                                                    // NewTask fails with this
	script     func(ctx context.Context, spec TaskSpec) (Result, error) // what Run does after it reports its states; nil: exit 0
	states     []State                                                  // what Run reports first
	specs      []TaskSpec
	classes    []ClassSettings
	runs       int // Run calls that started
	inRun      int
	maxInRun   int
	ctxs       []context.Context
	hasReports bool // the report function was not nil
}

func (f *fakeDriver) NewTask(spec TaskSpec, class ClassSettings) (Task, error) {
	f.mu.Lock()
	defer f.mu.Unlock()
	f.specs = append(f.specs, spec)
	f.classes = append(f.classes, class)
	if f.newErr != nil {
		return nil, f.newErr
	}
	return &fakeTask{f: f, spec: spec}, nil
}

type fakeTask struct {
	f    *fakeDriver
	spec TaskSpec
}

func (t *fakeTask) ID() string { return shortID(t.spec.ID) }

func (t *fakeTask) Run(ctx context.Context, report func(State)) (Result, error) {
	f := t.f
	f.mu.Lock()
	f.runs++
	f.inRun++
	f.maxInRun = max(f.maxInRun, f.inRun)
	f.ctxs = append(f.ctxs, ctx)
	f.hasReports = report != nil
	states, script := f.states, f.script
	f.mu.Unlock()
	defer func() {
		f.mu.Lock()
		f.inRun--
		f.mu.Unlock()
	}()
	for _, s := range states {
		report(s)
	}
	if script == nil {
		return Result{}, nil
	}
	return script(ctx, t.spec)
}

// recoveringDriver is a fakeDriver that also has the optional Recover.
type recoveringDriver struct {
	*fakeDriver
	calls int
	n     int
	err   error
}

func (r *recoveringDriver) Recover(context.Context) (int, error) { r.calls++; return r.n, r.err }

var (
	_ Driver    = (*fakeDriver)(nil)
	_ Recoverer = (*recoveringDriver)(nil)
)

type wrapperHarness struct {
	w  *wrapper
	r  *fakeRunner
	cl *class
}

func newWrapperHarness(t *testing.T, drv Driver, tasks ...*taskConfig) *wrapperHarness {
	t.Helper()
	r := newFakeRunner(t, classToken, tasks...)
	cl := &class{Name: "ns/docker", token: secret(classToken), Primary: Limits{CPUs: 2, MemoryMB: 4096}, Service: Limits{CPUs: 0.5, MemoryMB: 1024, Pids: 100}}
	cfg := &config{RunnerAPI: r.srv.URL, MaxTasks: 2, MaxRunTime: time.Hour, PollEvery: 10 * time.Millisecond, Name: "node-1", Classes: []*class{cl}}
	return &wrapperHarness{w: &wrapper{cfg: cfg, api: newRunnerAPI(r.srv.URL), driver: drv, sem: make(chan struct{}, cfg.MaxTasks)}, r: r, cl: cl}
}

func (h *wrapperHarness) runClaimed(t *testing.T) {
	t.Helper()
	c, err := h.w.api.claimTask(context.Background(), h.cl.token, "node-1", "node-1")
	if err != nil || c == nil {
		t.Fatalf("claim: %v %v", c, err)
	}
	h.w.runTask(context.Background(), h.cl, c)
}

func captureLog(t *testing.T) *bytes.Buffer {
	t.Helper()
	var buf bytes.Buffer
	log.SetOutput(&buf)
	t.Cleanup(func() { log.SetOutput(os.Stderr) })
	return &buf
}

func TestWrapperGivesTheDriverTheTaskAndTheClassSettings(t *testing.T) {
	d := &fakeDriver{}
	h := newWrapperHarness(t, d, jobConfig("Task-0001"))
	h.runClaimed(t)

	if len(d.specs) != 1 || len(d.classes) != 1 || d.runs != 1 {
		t.Fatalf("NewTask %d, classes %d, Run %d: want one of each", len(d.specs), len(d.classes), d.runs)
	}
	spec, class := d.specs[0], d.classes[0]
	if spec.ID != "Task-0001" || spec.Token.Raw() != "task-token-0" || spec.Allocation != "alloc-1" || spec.InitImageTag != "agent" ||
		spec.RunnerAPI != h.r.srv.URL || spec.MaxRunTime != time.Hour {
		t.Errorf("spec %+v", spec)
	}
	if len(spec.Containers) != 2 || spec.Containers[0].Image != "cimg/base:stable" || spec.Containers[1].Image != "cimg/postgres:16.0" {
		t.Fatalf("containers %+v: the primary must come first, then the services", spec.Containers)
	}
	p := spec.Containers[0]
	if p.User != "circleci" || !slices.Equal(p.Entrypoint, []string{"/bin/sh"}) || !slices.Equal(p.Command, []string{"-c", "sleep 1"}) ||
		p.Environment["A"] != "1" || p.Environment["B"] != "built-in-value" {
		t.Errorf("primary %+v: the variables must arrive expanded", p)
	}
	if class.Name != "ns/docker" || class.Primary != (Limits{CPUs: 2, MemoryMB: 4096}) || class.Service != (Limits{CPUs: 0.5, MemoryMB: 1024, Pids: 100}) {
		t.Errorf("class settings %+v", class)
	}
	if s := fmt.Sprintf("%+v %#v", spec, class); strings.Contains(s, classToken) {
		t.Error("the class token reached the driver")
	}
	if ev := h.r.eventsCopy(); !slices.Equal(ev, []string{"cleanup"}) {
		t.Errorf("events %v, want only cleanup", ev)
	}
}

func TestWrapperExpandsVariablesAndCredentialsBeforeTheDriverSeesThem(t *testing.T) {
	tc := jobConfig("Task-0002")
	tc.Environment.Secret = map[string]secret{"REGISTRY_PW": "s3cret"}
	tc.Job.Config.Docker[0].Image = "registry.example/${NAMESPACE}/app:${TAG}"
	tc.Environment.BuiltIn["NAMESPACE"], tc.Environment.BuiltIn["TAG"] = "team", "v1"
	tc.Job.Config.Docker[0].Auth = &authConfig{Username: "bot", Password: "$REGISTRY_PW", ServerAddress: "registry.example"}
	d := &fakeDriver{}
	h := newWrapperHarness(t, d, tc)
	h.runClaimed(t)

	p := d.specs[0].Containers[0]
	if p.Image != "registry.example/team/app:v1" {
		t.Errorf("image %q", p.Image)
	}
	if p.Auth == nil || p.Auth.Username != "bot" || p.Auth.Password.Raw() != "s3cret" || p.Auth.ServerAddress != "registry.example" {
		t.Errorf("auth %+v", p.Auth)
	}
	if s := fmt.Sprintf("%v %+v", p.Auth, p.Auth); strings.Contains(s, "s3cret") {
		t.Errorf("the password prints as %q", s)
	}
}

func TestWrapperMapsWhatTheDriverAnswersToEventsOfTheAPI(t *testing.T) {
	notStarted409 := func(h *wrapperHarness) { h.r.unclaim409 = true }
	for name, tc := range map[string]struct {
		d      *fakeDriver
		setup  func(h *wrapperHarness)
		events []string // "fail" stands for a fail event, whose message is checked by msg
		msg    string
	}{
		"a job that ends well":      {d: &fakeDriver{}, events: []string{"cleanup"}},
		"a job that exits with 3":   {d: &fakeDriver{script: result(3, nil)}, events: []string{"fail", "cleanup"}, msg: "primary container exited with code 3"},
		"a failure of the host":     {d: &fakeDriver{script: result(0, errors.New("the engine is gone"))}, events: []string{"fail", "cleanup"}, msg: "the engine is gone"},
		"a task that did not start": {d: &fakeDriver{script: result(0, notStarted(errors.New("pull failed")))}, events: []string{"unclaim:Task-0003", "cleanup"}},
		"a wrapped NotStartedError": {d: &fakeDriver{script: result(0, fmt.Errorf("setup: %w", notStarted(errors.New("pull failed"))))},
			events: []string{"unclaim:Task-0003", "cleanup"}},
		"a task that did not start and has no retries left": {d: &fakeDriver{script: result(0, notStarted(errors.New("pull failed")))}, setup: notStarted409,
			events: []string{"unclaim:Task-0003", "fail", "cleanup"}, msg: "pull failed"},
		"a spec the driver refuses":            {d: &fakeDriver{newErr: errors.New("unsupported")}, events: []string{"fail", "cleanup"}, msg: "unsupported"},
		"a spec the driver refuses, retryable": {d: &fakeDriver{newErr: notStarted(errors.New("no aws_auth"))}, events: []string{"unclaim:Task-0003", "cleanup"}},
	} {
		t.Run(name, func(t *testing.T) {
			h := newWrapperHarness(t, tc.d, jobConfig("Task-0003"))
			if tc.setup != nil {
				tc.setup(h)
			}
			h.runClaimed(t)
			var kinds []string
			var msg string
			for _, e := range h.r.eventsCopy() {
				if m, ok := strings.CutPrefix(e, "fail:"); ok {
					b, _ := base64.StdEncoding.DecodeString(m)
					msg = string(b)
					e = "fail"
				}
				kinds = append(kinds, e)
			}
			if !slices.Equal(kinds, tc.events) {
				t.Errorf("events %v, want %v", kinds, tc.events)
			}
			if !strings.Contains(msg, tc.msg) {
				t.Errorf("fail message %q, want it to say %q", msg, tc.msg)
			}
		})
	}
}

func result(code int, err error) func(context.Context, TaskSpec) (Result, error) {
	return func(context.Context, TaskSpec) (Result, error) { return Result{ExitCode: code}, err }
}

func TestWrapperTellsTheAPIOnlyAfterTheDriverIsDone(t *testing.T) {
	var h *wrapperHarness
	var atReturn []string
	d := &fakeDriver{script: func(context.Context, TaskSpec) (Result, error) {
		// the driver is still in Run here: nothing may have been reported about this task yet
		atReturn = h.r.eventsCopy()
		return Result{ExitCode: 1}, nil
	}}
	h = newWrapperHarness(t, d, jobConfig("Task-0004"))
	h.runClaimed(t)
	if len(atReturn) != 0 {
		t.Errorf("events %v were sent while the driver ran: the driver removes its resources before the API is told", atReturn)
	}
	if ev := h.r.eventsCopy(); len(ev) != 2 {
		t.Errorf("events %v, want fail and cleanup after Run", ev)
	}
}

func TestWrapperRefusesAMachineJobWithoutAskingTheDriver(t *testing.T) {
	d := &fakeDriver{}
	h := newWrapperHarness(t, d, &taskConfig{TaskID: "m1"})
	h.runClaimed(t)
	if len(d.specs) != 0 || d.runs != 0 {
		t.Errorf("the driver was asked about a machine job: %d NewTask, %d Run", len(d.specs), d.runs)
	}
	if ev := h.r.eventsCopy(); len(ev) != 1 || !strings.HasPrefix(ev[0], "fail:") {
		t.Errorf("events %v, want one fail", ev)
	}
}

func TestWrapperLogsTheStatesThatTheDriverReports(t *testing.T) {
	buf := captureLog(t)
	d := &fakeDriver{states: []State{StatePreparing, StateRunning, StateCleaningUp}}
	h := newWrapperHarness(t, d, jobConfig("Task-0005"))
	h.runClaimed(t)
	id := shortID("Task-0005")
	last := -1
	for _, s := range d.states {
		i := strings.Index(buf.String(), fmt.Sprintf("task %s: %s\n", id, s))
		if i < 0 || i < last {
			t.Fatalf("the log does not show %q in order:\n%s", s, buf)
		}
		last = i
	}
	if !d.hasReports {
		t.Error("the wrapper passed no report function")
	}
}

func TestWrapperGivesRunAContextWithTheRunTimeLimit(t *testing.T) {
	d := &fakeDriver{}
	h := newWrapperHarness(t, d, jobConfig("Task-0006"))
	h.w.cfg.MaxRunTime = 2 * time.Hour
	before := time.Now()
	h.runClaimed(t)
	dl, ok := d.ctxs[0].Deadline()
	if !ok || dl.Sub(before) < 2*time.Hour || dl.Sub(before) > 2*time.Hour+2*time.Minute {
		t.Errorf("deadline %v (set %v): want the run time plus a minute for the driver's own end", dl, ok)
	}
}

func TestWrapperLetsARunningTaskFinishWhenItStopsClaiming(t *testing.T) {
	started, release := make(chan struct{}), make(chan struct{})
	var runCtx context.Context
	d := &fakeDriver{script: func(ctx context.Context, _ TaskSpec) (Result, error) {
		runCtx = ctx
		close(started)
		<-release
		return Result{}, ctx.Err()
	}}
	h := newWrapperHarness(t, d, jobConfig("Task-0007"))
	ctx, stop := context.WithCancel(context.Background())
	done := make(chan struct{})
	go func() { h.w.run(ctx); close(done) }()
	select {
	case <-started:
	case <-time.After(10 * time.Second):
		t.Fatal("the task did not start")
	}
	stop() // SIGTERM: stop claiming
	select {
	case <-done:
		t.Fatal("run returned while a task was running: it must drain")
	case <-time.After(100 * time.Millisecond):
	}
	if runCtx.Err() != nil {
		t.Fatalf("the context of the running task ended with the wrapper's: %v", runCtx.Err())
	}
	close(release)
	select {
	case <-done:
	case <-time.After(10 * time.Second):
		t.Fatal("run did not return after the task ended")
	}
	if ev := h.r.eventsCopy(); !slices.Equal(ev, []string{"cleanup"}) {
		t.Errorf("events %v, want the task to finish normally", ev)
	}
}

func TestWrapperCapsTheTasksOfADriverAtTheSlots(t *testing.T) {
	d := &fakeDriver{script: func(ctx context.Context, _ TaskSpec) (Result, error) {
		time.Sleep(50 * time.Millisecond)
		return Result{}, nil
	}}
	h := newWrapperHarness(t, d, jobConfig("Task-0008"), jobConfig("Task-0009"), jobConfig("Task-0010"))
	h.w.cfg.MaxTasks = 1
	h.w.sem = make(chan struct{}, 1)
	ctx, stop := context.WithCancel(context.Background())
	done := make(chan struct{})
	go func() { h.w.run(ctx); close(done) }()
	deadline := time.Now().Add(10 * time.Second)
	for time.Now().Before(deadline) && len(h.r.eventsCopy()) < 3 {
		time.Sleep(10 * time.Millisecond)
	}
	stop()
	<-done
	if d.maxInRun != 1 || d.runs != 3 {
		t.Errorf("most tasks at once %d (want 1), tasks run %d (want 3)", d.maxInRun, d.runs)
	}
}

func TestWrapperRecoversOnlyWithADriverThatCan(t *testing.T) {
	buf := captureLog(t)
	rd := &recoveringDriver{fakeDriver: &fakeDriver{}, n: 3}
	newWrapperHarness(t, rd).w.recoverOrphans(context.Background())
	if rd.calls != 1 || !strings.Contains(buf.String(), "startup cleanup: removed 3 orphaned") {
		t.Errorf("Recover called %d times, log:\n%s", rd.calls, buf)
	}
	buf.Reset()
	rd = &recoveringDriver{fakeDriver: &fakeDriver{}, n: 1, err: errors.New("engine down")}
	newWrapperHarness(t, rd).w.recoverOrphans(context.Background())
	if !strings.Contains(buf.String(), "startup cleanup: removed 1, then: engine down") {
		t.Errorf("log:\n%s", buf)
	}
	buf.Reset()
	newWrapperHarness(t, &fakeDriver{}).w.recoverOrphans(context.Background()) // no Recover: no panic, no line
	if buf.Len() != 0 {
		t.Errorf("a driver without Recover logged %q", buf)
	}
}
