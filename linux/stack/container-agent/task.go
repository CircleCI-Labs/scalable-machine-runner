package main

import (
	"context"
	"crypto/rand"
	"crypto/sha256"
	"encoding/base64"
	"encoding/hex"
	"encoding/json"
	"fmt"
	"log"
	"os"
	"strings"
	"sync"
	"time"
)

const (
	labelManaged = "machine-runner-swarm.container-mode=1"
	labelTask    = "machine-runner-swarm.task"
	agentsDir    = "/opt/circleci/bin" // where the init step puts GOAT and the task agent, and the job container finds them
	defaultInit  = "circleci/runner-init"
	runnerSaaS   = "https://runner.circleci.com"
)

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

// expand substitutes $VAR and ${VAR} from the secret and built-in variables of the task, as container runner does.
func expand(s string, tc *taskConfig) string {
	return os.Expand(s, func(k string) string {
		if v, ok := tc.Environment.Secret[k]; ok {
			return v.Raw()
		}
		return tc.Environment.BuiltIn[k]
	})
}

func registryAuth(c *containerCfg) (string, error) {
	if c.AWSAuth != nil {
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

func (l limits) apply(h *hostConfig) {
	h.NanoCpus = int64(l.CPUs * 1e9)
	h.Memory = l.MemoryMB << 20
	h.MemorySwap = h.Memory // no swap beyond the limit
	h.PidsLimit = l.Pids
	if l.Pids == 0 {
		h.PidsLimit = 4096
	}
	h.CapDrop = []string{"NET_RAW", "MKNOD"} // as the machine-mode classes
}

// shortID names the resources of a task: a prefix of the hash of the task ID, safe in any Docker name.
func shortID(taskID string) string {
	if taskID == "" {
		b := make([]byte, 6)
		_, _ = rand.Read(b)
		return hex.EncodeToString(b)
	}
	h := sha256.Sum256([]byte(taskID))
	return hex.EncodeToString(h[:6])
}

// runTask runs one claimed task from start to finish and reports the outcome. It never panics out.
func (a *agent) runTask(ctx context.Context, cl *class, c *claim) {
	tok := c.TaskToken
	tc, err := a.api.taskConfig(ctx, tok)
	if err != nil {
		a.reportFail(ctx, tok, c, "", fmt.Errorf("could not get the task config: %w", err))
		return
	}
	id := shortID(tc.TaskID)
	log.Printf("task %s (%s): start, %d container(s)", id, cl.Name, len(tc.Job.Config.Docker))
	if len(tc.Job.Config.Docker) == 0 {
		a.reportFail(ctx, tok, c, tc.TaskID, fmt.Errorf("this is a machine job; %s is a container-mode class: use a machine class for machine jobs", cl.Name))
		return
	}
	taskCtx, cancel := context.WithTimeout(ctx, a.cfg.MaxRunTime+time.Minute)
	defer cancel()

	exit, runErr := a.execute(taskCtx, cl, c, tc, id)
	// Remove everything first, then tell the API (container runner does it in this order).
	cctx, ccancel := context.WithTimeout(context.WithoutCancel(ctx), 2*time.Minute)
	defer ccancel()
	if a.cfg.KeepFailed && (runErr != nil || exit != 0) {
		log.Printf("task %s: MACHINE_RUNNER_SWARM_CONTAINER_KEEP_FAILED is set: the containers stay (label %s=%s) until the agent restarts", id, labelTask, id)
	} else if err := a.removeTask(cctx, id); err != nil {
		log.Printf("task %s: cleanup problem: %v", id, err)
	}
	switch {
	case runErr != nil && !a.reportRetry(cctx, tok, tc.TaskID, id, runErr):
		a.reportFail(cctx, tok, c, tc.TaskID, runErr)
	case runErr == nil && exit != 0:
		a.reportFail(cctx, tok, c, tc.TaskID, fmt.Errorf("primary container exited with code %d. Check the job output for details", exit))
	case runErr == nil:
		log.Printf("task %s: finished", id)
	}
	if err := a.api.cleanup(cctx, tok); err != nil && runErr == nil {
		log.Printf("task %s: cleanup event: %v", id, err)
	}
}

// reportRetry puts a task whose containers never started back in the queue. It reports false if that is not possible.
func (a *agent) reportRetry(ctx context.Context, tok secret, taskID, id string, cause error) bool {
	if _, setup := cause.(setupError); !setup {
		return false
	}
	if err := a.api.unclaim(ctx, tok, taskID); err != nil {
		log.Printf("task %s: unclaim: %v", id, err)
		return false
	}
	log.Printf("task %s: unclaimed for a retry after: %v", id, cause)
	return true
}

func (a *agent) reportFail(ctx context.Context, tok secret, c *claim, taskID string, cause error) {
	log.Printf("task %s: failed: %v", shortID(taskID), cause)
	if err := a.api.fail(ctx, tok, c.Allocation, cause.Error()); err != nil {
		log.Printf("task %s: fail event: %v", shortID(taskID), err)
	}
}

// setupError marks a failure before the primary container started: the task can go back to the queue.
type setupError struct{ error }

func (a *agent) removeTask(ctx context.Context, id string) (err error) {
	for i := 0; i < 3; i++ {
		if _, err = a.d.sweep(ctx, labelTask+"="+id); err == nil {
			return nil
		}
		sleepCtx(ctx, 2*time.Second)
	}
	return err
}

// execute creates the pod-like group of containers and waits for the primary. It returns the exit code of the primary.
func (a *agent) execute(ctx context.Context, cl *class, c *claim, tc *taskConfig, id string) (exit int, err error) {
	cfgs := tc.Job.Config.Docker
	name := "cci-" + id
	labels := map[string]string{"machine-runner-swarm.container-mode": "1", labelTask: id, "machine-runner-swarm.class": cl.Name}
	role := func(r string) map[string]string {
		m := map[string]string{"machine-runner-swarm.role": r}
		for k, v := range labels {
			m[k] = v
		}
		return m
	}
	fail := func(format string, args ...any) (int, error) { return 0, setupError{fmt.Errorf(format, args...)} }

	// Expand variables and collect the images. Registry credentials stay in memory: they are passed to the
	// engine for the pull and are never written to a container, a volume or a file.
	initImage := a.cfg.InitImage
	if initImage == "" {
		tag := c.RunnerInitImageTag
		if tag == "" {
			tag = "agent"
		}
		initImage = defaultInit + ":" + tag
	}
	auths := map[string]string{}
	for i := range cfgs {
		cfgs[i].Image = expand(cfgs[i].Image, tc)
		if cfgs[i].Auth != nil {
			cfgs[i].Auth = &authConfig{Username: expand(cfgs[i].Auth.Username, tc), Password: secret(expand(cfgs[i].Auth.Password.Raw(), tc)),
				Auth: secret(expand(cfgs[i].Auth.Auth.Raw(), tc)), Email: expand(cfgs[i].Auth.Email, tc), ServerAddress: expand(cfgs[i].Auth.ServerAddress, tc)}
		}
		var aerr error
		if auths[cfgs[i].Image], aerr = registryAuth(&cfgs[i]); aerr != nil {
			return fail("%v", aerr)
		}
	}
	auths[initImage], auths[a.cfg.PauseImage] = "", ""

	if err := a.pullAll(ctx, auths); err != nil {
		return fail("%v", err)
	}
	if err := a.d.createNetwork(ctx, name, labels); err != nil {
		return fail("%v", err)
	}
	vol := name + "-bin"
	if err := a.d.createVolume(ctx, vol, labels); err != nil {
		return fail("%v", err)
	}

	// 1. The init step: copy GOAT and the task agent into the per-task volume.
	initSpec := ctrSpec{Image: initImage, Labels: role("init"), HostConfig: hostConfig{NetworkMode: "none", Binds: []string{vol + ":" + agentsDir},
		Memory: 128 << 20, MemorySwap: 128 << 20, PidsLimit: 64}}
	if code, out, err := a.runOnce(ctx, name+"-init", initSpec); err != nil {
		return fail("init step: %v", err)
	} else if code != 0 {
		return fail("init step exited with code %d: %s", code, out)
	}

	// 2. The pause container holds the network namespace, so every container of the task shares localhost.
	pause, err := a.d.launch(ctx, name+"-pause", ctrSpec{Image: a.cfg.PauseImage, Hostname: name, Labels: role("pause"),
		HostConfig: hostConfig{NetworkMode: name, Memory: 16 << 20, MemorySwap: 16 << 20, PidsLimit: 16}})
	if err != nil {
		return fail("pause container: %v", err)
	}

	// 3. Service containers, then the primary: they join the pause container's network.
	for i := 1; i < len(cfgs); i++ {
		s := ctrSpec{Image: cfgs[i].Image, Entrypoint: cfgs[i].Entrypoint, Cmd: cfgs[i].Command, Env: envList(cfgs[i].Environment, tc),
			WorkingDir: cfgs[i].WorkingDir, User: cfgs[i].User, Tty: true, OpenStdin: true, Labels: role("service"),
			HostConfig: hostConfig{NetworkMode: "container:" + pause}}
		cl.Service.apply(&s.HostConfig)
		if _, err := a.d.launch(ctx, fmt.Sprintf("%s-svc%d", name, i), s); err != nil {
			return fail("service container %d (%s): %v", i, cfgs[i].Image, err)
		}
	}

	p := cfgs[0]
	goat, _ := json.Marshal(goatConfig{Cmd: append(append([]string{}, p.Entrypoint...), p.Command...), TaskID: tc.TaskID,
		Token: c.TaskToken.Raw(), TaskAgentPath: agentsDir + "/circleci-agent", RunnerAPIBaseURL: a.cfg.RunnerAPI, Allocation: c.Allocation, MaxRunTime: a.cfg.MaxRunTime})
	penv := envList(p.Environment, tc)
	if a.cfg.RunnerAPI != runnerSaaS { // as container runner on CircleCI server
		penv = append(penv, "CIRCLE_URL="+a.cfg.RunnerAPI)
	}
	penv = append(penv, "CIRCLECI_GOAT_CONFIG="+string(goat))
	ps := ctrSpec{Image: p.Image, Entrypoint: []string{agentsDir + "/orchestrator"}, Cmd: []string{"run-task"}, Env: penv, WorkingDir: p.WorkingDir,
		User: p.User, Tty: true, OpenStdin: true, Labels: role("primary"),
		HostConfig: hostConfig{NetworkMode: "container:" + pause, Binds: []string{vol + ":" + agentsDir}}}
	cl.Primary.apply(&ps.HostConfig)
	pid, err := a.d.launch(ctx, name+"-primary", ps)
	if err != nil {
		return fail("primary container: %v", err)
	}
	exit, err = a.d.wait(ctx, pid)
	if err != nil {
		return 0, fmt.Errorf("waiting for the primary container (max run time %s): %w", a.cfg.MaxRunTime, err)
	}
	return exit, nil
}

// runOnce runs a short-lived container to its end. It returns the exit code and the tail of its output.
func (a *agent) runOnce(ctx context.Context, name string, s ctrSpec) (int, string, error) {
	id, err := a.d.launch(ctx, name, s)
	if err != nil {
		return 0, "", err
	}
	code, err := a.d.wait(ctx, id)
	if err != nil {
		return 0, "", err
	}
	out := ""
	if code != 0 {
		out = strings.TrimSpace(a.d.tail(ctx, id))
	}
	return code, out, nil
}

func (a *agent) pullAll(ctx context.Context, auths map[string]string) error {
	var wg sync.WaitGroup
	errs := make(chan error, len(auths))
	for image, auth := range auths {
		wg.Add(1)
		go func() {
			defer wg.Done()
			// A digest never changes, so a pinned image is pulled once. Tags are pulled every time by default.
			if (a.cfg.Pull == "missing" || strings.Contains(image, "@sha256:")) && a.d.hasImage(ctx, image) {
				return
			}
			if err := a.d.pull(ctx, image, auth); err != nil {
				errs <- err
			}
		}()
	}
	wg.Wait()
	close(errs)
	return <-errs
}

func envList(m map[string]string, tc *taskConfig) []string {
	out := make([]string, 0, len(m))
	for k, v := range m {
		out = append(out, k+"="+expand(v, tc))
	}
	return out
}
