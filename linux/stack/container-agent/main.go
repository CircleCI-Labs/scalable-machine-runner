// Command container-agent runs CircleCI Docker-executor jobs ("container mode") on the Docker engine of a Swarm
// node. One copy runs on every opted-in node, as a global Swarm service. It claims tasks for its resource
// classes, starts the containers of each job through the Docker Engine API and removes them afterwards. It is
// the only component with the engine socket: a job container never gets the socket or a class token.
package main

import (
	"context"
	"encoding/json"
	"fmt"
	"log"
	"math/rand"
	"os"
	"os/signal"
	"strconv"
	"strings"
	"sync"
	"syscall"
	"time"
)

var version = "0.1.0-prototype"

// limits caps one container of a job. Zero means no cap.
type limits struct {
	CPUs     float64 `json:"cpus"`
	MemoryMB int64   `json:"memory_mb"`
	Pids     int64   `json:"pids"`
}

// class is one container-mode resource class this agent serves.
type class struct {
	Name      string `json:"name"`       // <namespace>/<name>, as in a job's resource_class
	TokenFile string `json:"token_file"` // a Swarm secret: the class token, or a runner config with api.auth_token
	Primary   limits `json:"primary"`
	Service   limits `json:"service"` // each service container
	token     secret
}

type config struct {
	RunnerAPI  string
	InitImage  string // empty: circleci/runner-init:<tag from the claim>
	PauseImage string
	Pull       string // "always" (the container runner default) or "missing"
	KeepFailed bool   // leave the containers of a failed task for inspection (debugging)
	MaxTasks   int
	MaxRunTime time.Duration
	PollEvery  time.Duration
	Name       string
	Socket     string
	Classes    []*class
}

func env(k, def string) string {
	if v := strings.TrimSpace(os.Getenv(k)); v != "" {
		return v
	}
	return def
}

func loadConfig() (*config, error) {
	host, _ := os.Hostname()
	c := &config{
		RunnerAPI:  env("MACHINE_RUNNER_SWARM_CONTAINER_RUNNER_API", "https://runner.circleci.com"),
		InitImage:  env("MACHINE_RUNNER_SWARM_CONTAINER_INIT_IMAGE", ""),
		PauseImage: env("MACHINE_RUNNER_SWARM_CONTAINER_PAUSE_IMAGE", "registry.k8s.io/pause:3.10"),
		Pull:       env("MACHINE_RUNNER_SWARM_CONTAINER_PULL", "always"),
		Name:       env("MACHINE_RUNNER_SWARM_CONTAINER_NAME", host),
		Socket:     env("MACHINE_RUNNER_SWARM_CONTAINER_DOCKER_SOCKET", "/var/run/docker.sock"),
		KeepFailed: env("MACHINE_RUNNER_SWARM_CONTAINER_KEEP_FAILED", "") == "true",
	}
	var err error
	if c.MaxTasks, err = strconv.Atoi(env("MACHINE_RUNNER_SWARM_CONTAINER_MAX_TASKS", "2")); err != nil || c.MaxTasks < 1 {
		return nil, fmt.Errorf("MACHINE_RUNNER_SWARM_CONTAINER_MAX_TASKS must be a positive number")
	}
	if c.MaxRunTime, err = time.ParseDuration(env("MACHINE_RUNNER_SWARM_CONTAINER_MAX_RUN_TIME", "5h")); err != nil {
		return nil, fmt.Errorf("MACHINE_RUNNER_SWARM_CONTAINER_MAX_RUN_TIME: %w", err)
	}
	if c.PollEvery, err = time.ParseDuration(env("MACHINE_RUNNER_SWARM_CONTAINER_POLL_INTERVAL", "3s")); err != nil {
		return nil, fmt.Errorf("MACHINE_RUNNER_SWARM_CONTAINER_POLL_INTERVAL: %w", err)
	}
	if err = json.Unmarshal([]byte(env("MACHINE_RUNNER_SWARM_CONTAINER_CLASSES", "[]")), &c.Classes); err != nil || len(c.Classes) == 0 {
		return nil, fmt.Errorf("MACHINE_RUNNER_SWARM_CONTAINER_CLASSES must be a JSON array with at least one class: %v", err)
	}
	for _, cl := range c.Classes {
		if cl.Name == "" || cl.TokenFile == "" {
			return nil, fmt.Errorf("every class needs a name and a token_file")
		}
		if cl.token, err = readToken(cl.TokenFile); err != nil {
			return nil, err
		}
	}
	return c, nil
}

// readToken accepts the bare token, or a runner config file with an auth_token line (the format of the
// machine-mode secrets, so one secret can serve both).
func readToken(path string) (secret, error) {
	b, err := os.ReadFile(path)
	if err != nil {
		return "", fmt.Errorf("read token file: %w", err)
	}
	for _, line := range strings.Split(string(b), "\n") {
		line = strings.TrimSpace(line)
		if v, ok := strings.CutPrefix(line, "auth_token:"); ok {
			line = strings.Trim(strings.TrimSpace(v), `"'`)
			return secret(line), nil
		}
	}
	t := strings.TrimSpace(string(b))
	if t == "" || strings.ContainsAny(t, " \n:") {
		return "", fmt.Errorf("token file %s is empty or not a token", path)
	}
	return secret(t), nil
}

// agent holds what every task shares.
type agent struct {
	cfg *config
	api *runnerAPI
	d   *docker
	sem chan struct{} // the concurrency cap of this node
	wg  sync.WaitGroup
}

// run claims until ctx ends. It claims only while a slot is free, because a claim assigns the task to this
// agent. Running tasks always finish: they use their own context.
func (a *agent) run(ctx context.Context) {
	var cw sync.WaitGroup
	for _, cl := range a.cfg.Classes {
		cw.Add(1)
		go func() {
			defer cw.Done()
			a.claimLoop(ctx, cl)
		}()
	}
	cw.Wait()
	log.Printf("draining: waiting for %d running task(s)", len(a.sem))
	a.wg.Wait()
}

func (a *agent) claimLoop(ctx context.Context, cl *class) {
	backoff := a.cfg.PollEvery
	for ctx.Err() == nil {
		select {
		case a.sem <- struct{}{}:
		case <-ctx.Done():
			return
		}
		c, err := a.api.claimTask(ctx, cl.token, a.cfg.Name, a.cfg.Name)
		if err != nil || c == nil {
			<-a.sem
			if err != nil && ctx.Err() == nil {
				log.Printf("class %s: claim failed: %v", cl.Name, err)
				backoff = min(backoff*2, 30*time.Second)
			} else {
				backoff = a.cfg.PollEvery
			}
			sleepCtx(ctx, backoff+time.Duration(rand.Int63n(int64(backoff)/4+1)))
			continue
		}
		backoff = a.cfg.PollEvery
		a.wg.Add(1)
		go func() {
			defer a.wg.Done()
			defer func() { <-a.sem }()
			a.runTask(context.WithoutCancel(ctx), cl, c)
		}()
	}
}

func main() {
	log.SetFlags(log.LstdFlags | log.LUTC)
	cfg, err := loadConfig()
	if err != nil {
		log.Printf("configuration error: %v", err)
		os.Exit(80) // as the runner entrypoint: a bad setting, not a crash worth retrying quickly
	}
	a := &agent{cfg: cfg, api: newRunnerAPI(cfg.RunnerAPI), d: newDocker(cfg.Socket), sem: make(chan struct{}, cfg.MaxTasks)}
	ctx, stop := signal.NotifyContext(context.Background(), syscall.SIGTERM, syscall.SIGINT)
	defer stop()
	// Orphans of an earlier crash: nothing of ours can be running yet, because Swarm updates this service stop-first.
	if n, err := a.d.sweep(ctx, labelManaged); err != nil {
		log.Printf("startup cleanup: removed %d, then: %v", n, err)
	} else {
		log.Printf("startup cleanup: removed %d orphaned container(s), network(s) and volume(s)", n)
	}
	names := make([]string, 0, len(cfg.Classes))
	for _, cl := range cfg.Classes {
		names = append(names, cl.Name)
	}
	log.Printf("container-agent %s: classes %s, up to %d task(s) at a time", version, strings.Join(names, ","), cfg.MaxTasks)
	a.run(ctx)
}
