package main

import (
	"bytes"
	"context"
	"encoding/json"
	"fmt"
	"io"
	"net/http"
	"strings"
	"time"
)

// runnerAPI is the part of the CircleCI runner API that container mode calls. The class token claims; the task
// token that the claim returns does everything else.
type runnerAPI struct {
	base string
	hc   *http.Client
	ua   string
}

func newRunnerAPI(base string) *runnerAPI {
	return &runnerAPI{base: strings.TrimRight(base, "/"), hc: &http.Client{Timeout: 2 * time.Minute}, ua: "CircleCI-Swarm-Container-Agent/" + version}
}

func (a *runnerAPI) do(ctx context.Context, method, path string, token secret, in, out any) (int, error) {
	var body io.Reader
	if in != nil {
		b, err := json.Marshal(in)
		if err != nil {
			return 0, err
		}
		body = bytes.NewReader(b)
	}
	req, err := http.NewRequestWithContext(ctx, method, a.base+path, body)
	if err != nil {
		return 0, err
	}
	req.Header.Set("Authorization", "Bearer "+token.Raw())
	req.Header.Set("User-Agent", a.ua)
	req.Header.Set("Accept", "application/json")
	if in != nil {
		req.Header.Set("Content-Type", "application/json")
	}
	resp, err := a.hc.Do(req)
	if err != nil {
		return 0, fmt.Errorf("%s %s: %w", method, path, err)
	}
	defer func() { _ = resp.Body.Close() }()
	if resp.StatusCode/100 != 2 {
		msg, _ := io.ReadAll(io.LimitReader(resp.Body, 512))
		return resp.StatusCode, fmt.Errorf("%s %s: %s: %s", method, path, resp.Status, strings.TrimSpace(string(msg)))
	}
	if out != nil && resp.StatusCode != http.StatusNoContent {
		return resp.StatusCode, json.NewDecoder(resp.Body).Decode(out)
	}
	return resp.StatusCode, nil
}

// claim is the response of POST /api/v3/runner/claim.
type claim struct {
	AgentVersion       string `json:"agent_version"`
	TaskToken          secret `json:"task_token"`
	ResourceClass      string `json:"resource_class"`
	RunnerInitImageTag string `json:"runner_init_image_tag"`
	Allocation         string `json:"allocation"`
}

// claimTask returns nil, nil when there is no task (204).
func (a *runnerAPI) claimTask(ctx context.Context, classToken secret, name, host string) (*claim, error) {
	var c claim
	code, err := a.do(ctx, "POST", "/api/v3/runner/claim", classToken, map[string]string{"name": name, "hostname": host, "version": version}, &c)
	if err != nil || code == http.StatusNoContent {
		return nil, err
	}
	if c.TaskToken == "" {
		return nil, fmt.Errorf("claim response has no task_token")
	}
	return &c, nil
}

type authConfig struct {
	Username      string `json:"username"`
	Password      secret `json:"password"`
	Auth          secret `json:"auth"`
	Email         string `json:"email"`
	ServerAddress string `json:"serveraddress"`
}

// containerCfg is one entry of job.config.docker: the primary container first, then the services.
type containerCfg struct {
	Name        string            `json:"name"`
	Image       string            `json:"image"`
	User        string            `json:"user"`
	WorkingDir  string            `json:"working_dir"`
	Command     []string          `json:"command"`
	Entrypoint  []string          `json:"entrypoint"`
	Environment map[string]string `json:"environment"`
	Auth        *authConfig       `json:"auth"`
	AWSAuth     *struct{}         `json:"aws_auth"`
}

type taskConfig struct {
	TaskID string `json:"task_id"`
	Job    struct {
		Config struct {
			WorkingDirectory string         `json:"working_directory"`
			Docker           []containerCfg `json:"docker"`
		} `json:"config"`
	} `json:"job"`
	Environment struct {
		Secret  map[string]secret `json:"secret"`
		BuiltIn map[string]string `json:"built_in"`
	} `json:"environment"`
}

func (a *runnerAPI) taskConfig(ctx context.Context, tok secret) (*taskConfig, error) {
	var tc taskConfig
	_, err := a.do(ctx, "GET", "/api/v2/task/config", tok, nil, &tc)
	return &tc, err
}

// fail reports an infrastructure failure. The message is a byte slice in the API, so it travels as base64.
func (a *runnerAPI) fail(ctx context.Context, tok secret, allocation, msg string) error {
	_, err := a.do(ctx, "POST", "/api/v2/task/event/fail", tok, map[string]any{
		"allocation": allocation, "timestamp": time.Now().UnixMilli(), "message": []byte(msg)}, nil)
	return err
}

func (a *runnerAPI) cleanup(ctx context.Context, tok secret) error {
	_, err := a.do(ctx, "POST", "/api/v2/task/event/cleanup", tok, nil, nil)
	return err
}

// unclaim puts the task back in the queue. The server answers 409 when the task has no retries left.
func (a *runnerAPI) unclaim(ctx context.Context, tok secret, taskID string) error {
	_, err := a.do(ctx, "POST", "/api/v3/runner/unclaim", tok, map[string]string{"task_id": taskID, "task_token": tok.Raw()}, nil)
	return err
}
