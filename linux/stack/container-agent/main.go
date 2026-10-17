// Command container-agent runs CircleCI Docker-executor jobs ("container mode") on the Docker engine of a Swarm
// node. One copy runs on every opted-in node, as a global Swarm service. It claims tasks for its resource
// classes, starts the containers of each job through the Docker Engine API and removes them afterwards. It is
// the only component with the engine socket: a job container never gets the socket or a class token.
//
// This file is the entry point of the thin wrapper: the settings, the signals and the logging. The claim loop is in
// wrapper.go. It hands each task to a Driver (driver.go), and the Docker driver (driver_docker.go) is what makes containers.
package main

import (
	"context"
	"encoding/json"
	"fmt"
	"log"
	"os"
	"os/signal"
	"strconv"
	"strings"
	"syscall"
	"time"
)

var version = "0.1.0-prototype"

// class is one container-mode resource class this agent serves.
type class struct {
	Name      string `json:"name"`       // <namespace>/<name>, as in a job's resource_class
	TokenFile string `json:"token_file"` // a Swarm secret: the class token, or a runner config with api.auth_token
	Primary   Limits `json:"primary"`
	Service   Limits `json:"service"` // each service container
	token     secret
}

// settings are the part of a class that a driver sees: its name and the limits, never its token.
func (c *class) settings() ClassSettings {
	return ClassSettings{Name: c.Name, Primary: c.Primary, Service: c.Service}
}

type config struct {
	RunnerAPI  string
	MaxTasks   int
	MaxRunTime time.Duration
	PollEvery  time.Duration
	Name       string
	Classes    []*class
	Docker     dockerOptions // the settings of the Docker driver
}

func env(k, def string) string {
	if v := strings.TrimSpace(os.Getenv(k)); v != "" {
		return v
	}
	return def
}

// dockerOptionsFromEnv reads the settings of the Docker driver from the environment.
func dockerOptionsFromEnv() dockerOptions {
	return dockerOptions{
		Socket:     env("MACHINE_RUNNER_SWARM_CONTAINER_DOCKER_SOCKET", "/var/run/docker.sock"),
		InitImage:  env("MACHINE_RUNNER_SWARM_CONTAINER_INIT_IMAGE", ""),
		PauseImage: env("MACHINE_RUNNER_SWARM_CONTAINER_PAUSE_IMAGE", "registry.k8s.io/pause:3.10"),
		Pull:       env("MACHINE_RUNNER_SWARM_CONTAINER_PULL", "always"),
		KeepFailed: env("MACHINE_RUNNER_SWARM_CONTAINER_KEEP_FAILED", "") == "true",
	}
}

func loadConfig() (*config, error) {
	host, _ := os.Hostname()
	c := &config{
		RunnerAPI: env("MACHINE_RUNNER_SWARM_CONTAINER_RUNNER_API", runnerSaaS),
		Name:      env("MACHINE_RUNNER_SWARM_CONTAINER_NAME", host),
		Docker:    dockerOptionsFromEnv(),
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

func main() {
	log.SetFlags(log.LstdFlags | log.LUTC)
	cfg, err := loadConfig()
	if err != nil {
		log.Printf("configuration error: %v", err)
		os.Exit(80) // as the runner entrypoint: a bad setting, not a crash worth retrying quickly
	}
	w := &wrapper{cfg: cfg, api: newRunnerAPI(cfg.RunnerAPI), driver: newDockerDriver(cfg.Docker), sem: make(chan struct{}, cfg.MaxTasks)}
	ctx, stop := signal.NotifyContext(context.Background(), syscall.SIGTERM, syscall.SIGINT)
	defer stop()
	w.recoverOrphans(ctx) // the orphans of an earlier crash
	names := make([]string, 0, len(cfg.Classes))
	for _, cl := range cfg.Classes {
		names = append(names, cl.Name)
	}
	log.Printf("container-agent %s: classes %s, up to %d task(s) at a time", version, strings.Join(names, ","), cfg.MaxTasks)
	w.run(ctx)
}
