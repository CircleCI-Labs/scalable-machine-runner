package main

import (
	"encoding/json"
	"io"
	"net"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"strings"
	"sync"
	"testing"
	"time"
)

// fakeEngine is an in-memory Docker Engine: just the endpoints that container mode calls.
type fakeEngine struct {
	mu         sync.Mutex
	order      []string // "create:<name>" and "start:<name>" in call order
	ctrs       map[string]*fakeCtr
	networks   map[string]map[string]string
	volumes    map[string]map[string]string
	pulled     []string
	failPull   string
	exit       map[string]int // role -> exit code
	hold       time.Duration  // how long a primary runs
	running    int
	maxRunning int
	removed    []string
}

type fakeCtr struct {
	name string
	spec ctrSpec
}

func newFakeEngine(t *testing.T) (*fakeEngine, string) {
	t.Helper()
	f := &fakeEngine{ctrs: map[string]*fakeCtr{}, networks: map[string]map[string]string{}, volumes: map[string]map[string]string{}, exit: map[string]int{}}
	dir, err := os.MkdirTemp("", "cca")
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { _ = os.RemoveAll(dir) })
	sock := filepath.Join(dir, "d.sock")
	l, err := net.Listen("unix", sock)
	if err != nil {
		t.Fatal(err)
	}
	srv := &http.Server{Handler: http.HandlerFunc(f.serve)}
	go func() { _ = srv.Serve(l) }()
	t.Cleanup(func() { _ = srv.Close() })
	return f, sock
}

func matches(labels map[string]string, filters string) bool {
	var f map[string][]string
	_ = json.Unmarshal([]byte(filters), &f)
	for _, kv := range f["label"] {
		k, v, _ := strings.Cut(kv, "=")
		if labels[k] != v {
			return false
		}
	}
	return true
}

func (f *fakeEngine) serve(w http.ResponseWriter, r *http.Request) {
	f.mu.Lock()
	unlock := true
	defer func() {
		if unlock {
			f.mu.Unlock()
		}
	}()
	p := strings.TrimPrefix(r.URL.Path, "/"+apiVersion)
	q := r.URL.Query()
	reply := func(code int, v any) {
		w.WriteHeader(code)
		if v != nil {
			_ = json.NewEncoder(w).Encode(v)
		}
	}
	seg := strings.Split(strings.Trim(p, "/"), "/")
	switch {
	case p == "/images/create":
		img := q.Get("fromImage")
		f.pulled = append(f.pulled, img)
		if img == f.failPull {
			reply(200, map[string]string{"error": "pull access denied"})
			return
		}
		reply(200, map[string]string{"status": "ok"})
	case seg[0] == "images":
		reply(404, map[string]string{"message": "no such image"})
	case p == "/networks/create" || p == "/volumes/create":
		var b struct {
			Name   string
			Labels map[string]string
		}
		_ = json.NewDecoder(r.Body).Decode(&b)
		if p == "/networks/create" {
			f.networks[b.Name] = b.Labels
		} else {
			f.volumes[b.Name] = b.Labels
		}
		reply(201, map[string]string{"Id": b.Name, "Name": b.Name})
	case p == "/networks" && r.Method == "GET":
		out := []map[string]string{}
		for n, l := range f.networks {
			if matches(l, q.Get("filters")) {
				out = append(out, map[string]string{"Id": n})
			}
		}
		reply(200, out)
	case p == "/volumes" && r.Method == "GET":
		out := []map[string]string{}
		for n, l := range f.volumes {
			if matches(l, q.Get("filters")) {
				out = append(out, map[string]string{"Name": n})
			}
		}
		reply(200, map[string]any{"Volumes": out})
	case seg[0] == "networks" && r.Method == "DELETE":
		delete(f.networks, seg[1])
		reply(204, nil)
	case seg[0] == "volumes" && r.Method == "DELETE":
		delete(f.volumes, seg[1])
		reply(204, nil)
	case p == "/containers/create":
		var s ctrSpec
		_ = json.NewDecoder(r.Body).Decode(&s)
		name := q.Get("name")
		f.ctrs["id-"+name] = &fakeCtr{name: name, spec: s}
		f.order = append(f.order, "create:"+name)
		reply(201, map[string]string{"Id": "id-" + name})
	case p == "/containers/json":
		out := []map[string]string{}
		for id, c := range f.ctrs {
			if matches(c.spec.Labels, q.Get("filters")) {
				out = append(out, map[string]string{"Id": id})
			}
		}
		reply(200, out)
	case seg[0] == "containers" && seg[len(seg)-1] == "start":
		c := f.ctrs[seg[1]]
		f.order = append(f.order, "start:"+c.name)
		if c.spec.Labels["machine-runner-swarm.role"] == "primary" {
			f.running++
			f.maxRunning = max(f.maxRunning, f.running)
		}
		reply(204, nil)
	case seg[0] == "containers" && seg[len(seg)-1] == "wait":
		c := f.ctrs[seg[1]]
		role := c.spec.Labels["machine-runner-swarm.role"]
		hold := time.Duration(0)
		if role == "primary" {
			hold = f.hold
		}
		code := f.exit[role]
		f.mu.Unlock()
		unlock = false
		select {
		case <-time.After(hold):
		case <-r.Context().Done():
			return
		}
		f.mu.Lock()
		unlock = true
		if role == "primary" {
			f.running--
		}
		reply(200, map[string]int{"StatusCode": code})
	case seg[0] == "containers" && seg[len(seg)-1] == "logs":
		_, _ = io.WriteString(w, "boom")
	case seg[0] == "containers" && r.Method == "DELETE":
		f.removed = append(f.removed, f.ctrs[seg[1]].name)
		delete(f.ctrs, seg[1])
		reply(204, nil)
	default:
		reply(404, map[string]string{"message": "unexpected " + r.Method + " " + p})
	}
}

func (f *fakeEngine) byRole(role string) []*fakeCtr {
	var out []*fakeCtr
	for _, c := range f.ctrs {
		if c.spec.Labels["machine-runner-swarm.role"] == role {
			out = append(out, c)
		}
	}
	return out
}

// fakeRunner is the runner API: a queue of claims, a task config, and a record of the events.
type fakeRunner struct {
	mu          sync.Mutex
	classToken  string
	tasks       []*taskConfig // one claim per entry
	claimed     int
	events      []string // "fail:<message>", "cleanup", "unclaim:<task id>", all with the task token that sent them
	tokens      map[string]bool
	failMessage string
	unclaim409  bool
	srv         *httptest.Server
}

func newFakeRunner(t *testing.T, classToken string, tasks ...*taskConfig) *fakeRunner {
	t.Helper()
	f := &fakeRunner{classToken: classToken, tasks: tasks, tokens: map[string]bool{}}
	f.srv = httptest.NewServer(http.HandlerFunc(f.serve))
	t.Cleanup(f.srv.Close)
	return f
}

func (f *fakeRunner) serve(w http.ResponseWriter, r *http.Request) {
	f.mu.Lock()
	defer f.mu.Unlock()
	bearer := strings.TrimPrefix(r.Header.Get("Authorization"), "Bearer ")
	var body map[string]any
	_ = json.NewDecoder(r.Body).Decode(&body)
	idx := func() int { return int(bearer[len(bearer)-1] - '0') }
	switch r.URL.Path {
	case "/api/v3/runner/claim":
		if bearer != f.classToken {
			http.Error(w, "bad class token", http.StatusUnauthorized)
		} else if f.claimed >= len(f.tasks) {
			w.WriteHeader(http.StatusNoContent)
		} else {
			f.claimed++
			_ = json.NewEncoder(w).Encode(map[string]string{"task_token": "task-token-" + string(rune('0'+f.claimed-1)), "resource_class": "ns/docker",
				"runner_init_image_tag": "agent", "allocation": "alloc-1"})
		}
	case "/api/v2/task/config":
		f.tokens[bearer] = true
		_ = json.NewEncoder(w).Encode(f.tasks[idx()])
	case "/api/v2/task/event/fail":
		msg, _ := body["message"].(string) // base64 of the message, as in the real API
		f.events = append(f.events, "fail:"+msg)
	case "/api/v2/task/event/cleanup":
		f.events = append(f.events, "cleanup")
	case "/api/v3/runner/unclaim":
		f.events = append(f.events, "unclaim:"+body["task_id"].(string))
		if f.unclaim409 {
			http.Error(w, "retries exhausted", http.StatusConflict)
		}
	default:
		http.NotFound(w, r)
	}
}

func (f *fakeRunner) eventsCopy() []string {
	f.mu.Lock()
	defer f.mu.Unlock()
	return append([]string(nil), f.events...)
}
