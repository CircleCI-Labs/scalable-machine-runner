package main

// The Docker implementation of Driver (driver.go): one task is a group of containers on the engine of this node that
// share a network namespace, as the containers of a pod do. This file and docker.go, the client of the Engine API, are
// the only code that knows about containers.
//
// The group of one task, in the order of its start:
//
//	a network and a volume, both removed at the end
//	init     fills the volume with the orchestrator (GOAT) and the task agent, and exits. It has no network
//	pause    holds the network namespace, so that the other containers share localhost
//	service  one container for each service of the job, on the pause container's network
//	primary  GOAT, which runs the job's entrypoint and the task agent, on the pause container's network

import (
	"context"
	"encoding/base64"
	"encoding/json"
	"fmt"
	"log"
	"strings"
	"sync"
	"time"
)

const (
	labelManaged = "machine-runner-swarm.container-mode=1" // on everything this driver creates, for Recover
	labelTask    = "machine-runner-swarm.task"             // the task's ID (shortID), on everything of one task
	agentsDir    = "/opt/circleci/bin"                     // where the init step puts GOAT and the task agent, and the job container finds them
	defaultInit  = "circleci/runner-init"
	runnerSaaS   = "https://runner.circleci.com"
)

// dockerOptions are the settings of the Docker driver. They are the same for every task.
type dockerOptions struct {
	Socket     string // the engine's unix socket
	InitImage  string // empty: circleci/runner-init:<tag of the claim>
	PauseImage string
	Pull       string // "always" (the container runner default) or "missing"
	KeepFailed bool   // leave the containers of a failed task for inspection (debugging)
}

// dockerDriver is the Driver for the Docker engine of this node.
type dockerDriver struct {
	opts dockerOptions
	d    *docker
}

var (
	_ Driver    = (*dockerDriver)(nil)
	_ Recoverer = (*dockerDriver)(nil)
	_ Task      = (*dockerTask)(nil)
)

func newDockerDriver(opts dockerOptions) *dockerDriver {
	return &dockerDriver{opts: opts, d: newDocker(opts.Socket)}
}

// dockerTask is one task of a dockerDriver.
type dockerTask struct {
	drv       *dockerDriver
	spec      TaskSpec
	class     ClassSettings
	id        string
	initImage string
	auths     map[string]string // image -> X-Registry-Auth value, or "": every image that Run pulls
}

// NewTask checks the registry credentials and works out the images to pull. It does not touch the engine.
func (dr *dockerDriver) NewTask(spec TaskSpec, class ClassSettings) (Task, error) {
	if len(spec.Containers) == 0 {
		return nil, fmt.Errorf("the task has no container")
	}
	t := &dockerTask{drv: dr, spec: spec, class: class, id: shortID(spec.ID), initImage: dr.opts.InitImage, auths: map[string]string{}}
	if t.initImage == "" {
		tag := spec.InitImageTag
		if tag == "" {
			tag = "agent"
		}
		t.initImage = defaultInit + ":" + tag
	}
	// Registry credentials stay in memory: they are passed to the engine for the pull and are never written to a
	// container, a volume or a file.
	for i := range spec.Containers {
		auth, err := registryAuth(&spec.Containers[i])
		if err != nil {
			return nil, notStarted(err)
		}
		t.auths[spec.Containers[i].Image] = auth
	}
	t.auths[t.initImage], t.auths[dr.opts.PauseImage] = "", ""
	return t, nil
}

// Recover removes every container, network and volume that carries the label of this driver.
func (dr *dockerDriver) Recover(ctx context.Context) (int, error) {
	return dr.d.sweep(ctx, labelManaged)
}

func (t *dockerTask) ID() string { return t.id }

// Run runs the task, and removes its containers, network and volume when it is done, also when ctx ends first.
func (t *dockerTask) Run(ctx context.Context, report func(State)) (res Result, err error) {
	if report == nil {
		report = func(State) {}
	}
	report(StatePreparing)
	defer func() {
		report(StateCleaningUp)
		t.cleanup(ctx, err != nil || res.ExitCode != 0)
	}()
	exit, err := t.execute(ctx, report)
	return Result{ExitCode: exit}, err
}

// cleanup removes the task's resources, in a context of its own: ctx may have ended, and that is when it matters most.
func (t *dockerTask) cleanup(ctx context.Context, failed bool) {
	cctx, cancel := context.WithTimeout(context.WithoutCancel(ctx), 2*time.Minute)
	defer cancel()
	if t.drv.opts.KeepFailed && failed {
		log.Printf("task %s: MACHINE_RUNNER_SWARM_CONTAINER_KEEP_FAILED is set: the containers stay (label %s=%s) until the agent restarts", t.id, labelTask, t.id)
		return
	}
	if err := t.remove(cctx); err != nil {
		log.Printf("task %s: cleanup problem: %v", t.id, err)
	}
}

func (t *dockerTask) remove(ctx context.Context) (err error) {
	for i := 0; i < 3; i++ {
		if _, err = t.drv.d.sweep(ctx, labelTask+"="+t.id); err == nil {
			return nil
		}
		sleepCtx(ctx, 2*time.Second)
	}
	return err
}

// execute creates the pod-like group of containers and waits for the primary. It returns the exit code of the primary.
func (t *dockerTask) execute(ctx context.Context, report func(State)) (exit int, err error) {
	d, opts, spec, class := t.drv.d, t.drv.opts, t.spec, t.class
	cfgs := spec.Containers
	name := "cci-" + t.id
	labels := map[string]string{"machine-runner-swarm.container-mode": "1", labelTask: t.id, "machine-runner-swarm.class": class.Name}
	role := func(r string) map[string]string {
		m := map[string]string{"machine-runner-swarm.role": r}
		for k, v := range labels {
			m[k] = v
		}
		return m
	}
	fail := func(format string, args ...any) (int, error) { return 0, notStarted(fmt.Errorf(format, args...)) }

	if err := t.pullAll(ctx); err != nil {
		return fail("%v", err)
	}
	if err := d.createNetwork(ctx, name, labels); err != nil {
		return fail("%v", err)
	}
	vol := name + "-bin"
	if err := d.createVolume(ctx, vol, labels); err != nil {
		return fail("%v", err)
	}

	// 1. The init step: copy GOAT and the task agent into the per-task volume.
	initSpec := ctrSpec{Image: t.initImage, Labels: role("init"), HostConfig: hostConfig{NetworkMode: "none", Binds: []string{vol + ":" + agentsDir},
		Memory: 128 << 20, MemorySwap: 128 << 20, PidsLimit: 64}}
	if code, out, err := t.runOnce(ctx, name+"-init", initSpec); err != nil {
		return fail("init step: %v", err)
	} else if code != 0 {
		return fail("init step exited with code %d: %s", code, out)
	}

	// 2. The pause container holds the network namespace, so every container of the task shares localhost.
	pause, err := d.launch(ctx, name+"-pause", ctrSpec{Image: opts.PauseImage, Hostname: name, Labels: role("pause"),
		HostConfig: hostConfig{NetworkMode: name, Memory: 16 << 20, MemorySwap: 16 << 20, PidsLimit: 16}})
	if err != nil {
		return fail("pause container: %v", err)
	}

	// 3. Service containers, then the primary: they join the pause container's network.
	for i := 1; i < len(cfgs); i++ {
		s := ctrSpec{Image: cfgs[i].Image, Entrypoint: cfgs[i].Entrypoint, Cmd: cfgs[i].Command, Env: envList(cfgs[i].Environment),
			WorkingDir: cfgs[i].WorkingDir, User: cfgs[i].User, Tty: true, OpenStdin: true, Labels: role("service"),
			HostConfig: hostConfig{NetworkMode: "container:" + pause}}
		applyLimits(class.Service, &s.HostConfig)
		if _, err := d.launch(ctx, fmt.Sprintf("%s-svc%d", name, i), s); err != nil {
			return fail("service container %d (%s): %v", i, cfgs[i].Image, err)
		}
	}

	p := cfgs[0]
	goat, _ := json.Marshal(goatConfig{Cmd: append(append([]string{}, p.Entrypoint...), p.Command...), TaskID: spec.ID,
		Token: spec.Token.Raw(), TaskAgentPath: agentsDir + "/circleci-agent", RunnerAPIBaseURL: spec.RunnerAPI, Allocation: spec.Allocation, MaxRunTime: spec.MaxRunTime})
	penv := envList(p.Environment)
	if spec.RunnerAPI != runnerSaaS { // as container runner on CircleCI server
		penv = append(penv, "CIRCLE_URL="+spec.RunnerAPI)
	}
	penv = append(penv, "CIRCLECI_GOAT_CONFIG="+string(goat))
	ps := ctrSpec{Image: p.Image, Entrypoint: []string{agentsDir + "/orchestrator"}, Cmd: []string{"run-task"}, Env: penv, WorkingDir: p.WorkingDir,
		User: p.User, Tty: true, OpenStdin: true, Labels: role("primary"),
		HostConfig: hostConfig{NetworkMode: "container:" + pause, Binds: []string{vol + ":" + agentsDir}}}
	applyLimits(class.Primary, &ps.HostConfig)
	pid, err := d.launch(ctx, name+"-primary", ps)
	if err != nil {
		return fail("primary container: %v", err)
	}
	report(StateRunning)
	exit, err = d.wait(ctx, pid)
	if err != nil {
		return 0, fmt.Errorf("waiting for the primary container (max run time %s): %w", spec.MaxRunTime, err)
	}
	return exit, nil
}

// goatConfig is what GOAT (the orchestrator, PID 1 of the primary container) reads from CIRCLECI_GOAT_CONFIG.
// It carries the task token, so it exists only in the environment of the primary container. User stays empty: the job's
// user is the user of the container, because GOAT can switch users only when it starts as root.
type goatConfig struct {
	Cmd                 []string      `json:"cmd"`
	User                string        `json:"user"`
	TaskID              string        `json:"task_id"`
	EnableUnsafeRetries bool          `json:"enable_unsafe_retries"`
	ReadinessFilePath   string        `json:"readiness_file_path"`
	Token               string        `json:"token"`
	TaskAgentPath       string        `json:"task_agent_path"`
	RunnerAPIBaseURL    string        `json:"runner_api_base_url"`
	Allocation          string        `json:"allocation"`
	SSHAdvertiseAddr    string        `json:"ssh_advertise_addr"`
	MaxRunTime          time.Duration `json:"max_run_time"`
}

func registryAuth(c *ContainerSpec) (string, error) {
	if c.AWSAuth {
		return "", fmt.Errorf("aws_auth (ECR) is not supported in container mode yet")
	}
	if c.Auth == nil {
		return "", nil
	}
	user, pass := c.Auth.Username, c.Auth.Password.Raw()
	if pass == "" && c.Auth.Auth != "" { // "auth" is base64(user:password)
		if b, err := base64.StdEncoding.DecodeString(c.Auth.Auth.Raw()); err == nil {
			user, pass, _ = strings.Cut(string(b), ":")
		}
	}
	b, _ := json.Marshal(map[string]string{"username": user, "password": pass, "email": c.Auth.Email, "serveraddress": c.Auth.ServerAddress})
	return base64.URLEncoding.EncodeToString(b), nil
}

func applyLimits(l Limits, h *hostConfig) {
	h.NanoCpus = int64(l.CPUs * 1e9)
	h.Memory = l.MemoryMB << 20
	h.MemorySwap = h.Memory // no swap beyond the limit
	h.PidsLimit = l.Pids
	if l.Pids == 0 {
		h.PidsLimit = 4096
	}
	h.CapDrop = []string{"NET_RAW", "MKNOD"} // as the machine-mode classes
}

// runOnce runs a short-lived container to its end. It returns the exit code and the tail of its output.
func (t *dockerTask) runOnce(ctx context.Context, name string, s ctrSpec) (int, string, error) {
	d := t.drv.d
	id, err := d.launch(ctx, name, s)
	if err != nil {
		return 0, "", err
	}
	code, err := d.wait(ctx, id)
	if err != nil {
		return 0, "", err
	}
	out := ""
	if code != 0 {
		out = strings.TrimSpace(d.tail(ctx, id))
	}
	return code, out, nil
}

func (t *dockerTask) pullAll(ctx context.Context) error {
	var wg sync.WaitGroup
	errs := make(chan error, len(t.auths))
	for image, auth := range t.auths {
		wg.Add(1)
		go func() {
			defer wg.Done()
			// A digest never changes, so a pinned image is pulled once. Tags are pulled every time by default.
			if (t.drv.opts.Pull == "missing" || strings.Contains(image, "@sha256:")) && t.drv.d.hasImage(ctx, image) {
				return
			}
			if err := t.drv.d.pull(ctx, image, auth); err != nil {
				errs <- err
			}
		}()
	}
	wg.Wait()
	close(errs)
	return <-errs
}

func envList(m map[string]string) []string {
	out := make([]string, 0, len(m))
	for k, v := range m {
		out = append(out, k+"="+v)
	}
	return out
}
