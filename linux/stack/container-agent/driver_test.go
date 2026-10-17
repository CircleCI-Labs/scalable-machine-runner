package main

// Tests of the Docker driver across the Driver interface only: a spec goes in through NewTask, and the states, the result,
// the error and what is left on the engine come out through Run. The engine is the in-memory fake of fake_test.go.

import (
	"context"
	"errors"
	"fmt"
	"slices"
	"strings"
	"testing"
	"time"
)

func testSpec(id string) TaskSpec {
	return TaskSpec{
		ID: id,
		Containers: []ContainerSpec{
			{Image: "cimg/base:stable", Entrypoint: []string{"/bin/sh"}, Command: []string{"-c", "true"}, Environment: map[string]string{"A": "1"}},
			{Image: "cimg/postgres:16.0", Environment: map[string]string{"POSTGRES_USER": "u"}},
		},
		Token: "task-token-SENTINEL", Allocation: "alloc-1", InitImageTag: "agent", RunnerAPI: "https://runner.example", MaxRunTime: time.Hour,
	}
}

var testClass = ClassSettings{Name: "ns/docker", Primary: Limits{CPUs: 1, MemoryMB: 512}, Service: Limits{CPUs: 0.5, MemoryMB: 256}}

func newTestDriver(t *testing.T) (*dockerDriver, *fakeEngine) {
	t.Helper()
	e, sock := newFakeEngine(t)
	return newDockerDriver(dockerOptions{Socket: sock, PauseImage: "pause:1", Pull: "always"}), e
}

// engineEmpty fails the test when anything of container mode is left on the engine.
func engineEmpty(t *testing.T, e *fakeEngine) {
	t.Helper()
	e.mu.Lock()
	defer e.mu.Unlock()
	if len(e.ctrs)+len(e.networks)+len(e.volumes) != 0 {
		t.Errorf("left behind: %d containers, %d networks, %d volumes", len(e.ctrs), len(e.networks), len(e.volumes))
	}
}

func recordStates() (func(State), func() []State) {
	var got []State
	return func(s State) { got = append(got, s) }, func() []State { return got }
}

func TestDockerDriverMakesATaskWithoutTouchingTheEngine(t *testing.T) {
	drv, e := newTestDriver(t)
	task, err := drv.NewTask(testSpec("Task-1"), testClass)
	if err != nil {
		t.Fatal(err)
	}
	if task.ID() != shortID("Task-1") {
		t.Errorf("ID %q, want %q", task.ID(), shortID("Task-1"))
	}
	e.mu.Lock()
	defer e.mu.Unlock()
	if len(e.pulled)+len(e.order)+len(e.ctrs)+len(e.networks)+len(e.volumes) != 0 {
		t.Errorf("NewTask touched the engine: pulled %v, order %v", e.pulled, e.order)
	}
}

func TestDockerDriverRunReportsTheStatesInOrderAndCleansUp(t *testing.T) {
	drv, e := newTestDriver(t)
	task, err := drv.NewTask(testSpec("Task-2"), testClass)
	if err != nil {
		t.Fatal(err)
	}
	report, states := recordStates()
	res, err := task.Run(context.Background(), report)
	if err != nil || res.ExitCode != 0 {
		t.Fatalf("Run: %+v, %v", res, err)
	}
	if want := []State{StatePreparing, StateRunning, StateCleaningUp}; !slices.Equal(states(), want) {
		t.Errorf("states %v, want %v", states(), want)
	}
	engineEmpty(t, e)
}

func TestDockerDriverReportsTheExitCodeAsAResultNotAnError(t *testing.T) {
	drv, e := newTestDriver(t)
	e.exit["primary"] = 3
	task, _ := drv.NewTask(testSpec("Task-3"), testClass)
	res, err := task.Run(context.Background(), nil) // a nil report is allowed
	if err != nil || res.ExitCode != 3 {
		t.Fatalf("Run: %+v, %v; a failing job is a result with its exit code and no error", res, err)
	}
	engineEmpty(t, e)
}

func TestDockerDriverCleansUpWhenTheContextEnds(t *testing.T) {
	drv, e := newTestDriver(t)
	e.hold = time.Hour // the primary container never stops by itself
	task, _ := drv.NewTask(testSpec("Task-4"), testClass)
	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()
	var got []State
	done := make(chan error, 1)
	go func() {
		_, err := task.Run(ctx, func(s State) {
			got = append(got, s)
			if s == StateRunning {
				cancel() // the job is running: end the context
			}
		})
		done <- err
	}()
	select {
	case err := <-done:
		if err == nil || isNotStarted(err) {
			t.Errorf("error %v: a job that ran and was cut off is an error, and not a NotStartedError", err)
		}
		if !errors.Is(err, context.Canceled) {
			t.Errorf("error %v does not wrap the end of the context", err)
		}
	case <-time.After(10 * time.Second):
		t.Fatal("Run did not return after its context ended")
	}
	if want := []State{StatePreparing, StateRunning, StateCleaningUp}; !slices.Equal(got, want) {
		t.Errorf("states %v, want %v", got, want)
	}
	engineEmpty(t, e) // although the context was done, the removal ran
	e.mu.Lock()
	defer e.mu.Unlock()
	if !slices.Contains(e.removed, "cci-"+shortID("Task-4")+"-primary") {
		t.Errorf("the primary container was not removed: %v", e.removed)
	}
}

func TestDockerDriverSetupFailuresAreNotStartedAndLeaveNothing(t *testing.T) {
	for name, tc := range map[string]struct {
		setup func(e *fakeEngine)
		want  string
		steps []State
	}{
		"a pull that fails":                  {func(e *fakeEngine) { e.failPull = "cimg/postgres:16.0" }, "pull access denied", []State{StatePreparing, StateCleaningUp}},
		"an init step that exits with 1":     {func(e *fakeEngine) { e.exit["init"] = 1 }, "init step exited with code 1: boom", []State{StatePreparing, StateCleaningUp}},
		"a pause image that cannot be found": {func(e *fakeEngine) { e.failPull = "pause:1" }, "pause:1", []State{StatePreparing, StateCleaningUp}},
	} {
		t.Run(name, func(t *testing.T) {
			drv, e := newTestDriver(t)
			tc.setup(e)
			task, _ := drv.NewTask(testSpec("Task-5"), testClass)
			report, states := recordStates()
			_, err := task.Run(context.Background(), report)
			if err == nil || !isNotStarted(err) || !strings.Contains(err.Error(), tc.want) {
				t.Fatalf("error %v, want a NotStartedError that says %q", err, tc.want)
			}
			if !slices.Equal(states(), tc.steps) {
				t.Errorf("states %v, want %v (no running: the primary never started)", states(), tc.steps)
			}
			e.mu.Lock()
			for _, o := range e.order {
				if strings.HasSuffix(o, "-primary") {
					t.Errorf("the primary container was created: %v", e.order)
				}
			}
			e.mu.Unlock()
			engineEmpty(t, e)
		})
	}
}

func TestDockerDriverRefusesWhatItCannotRunBeforeAnythingHappens(t *testing.T) {
	drv, e := newTestDriver(t)
	spec := testSpec("Task-6")
	spec.Containers[1].AWSAuth = true
	if _, err := drv.NewTask(spec, testClass); err == nil || !isNotStarted(err) || !strings.Contains(err.Error(), "aws_auth") {
		t.Errorf("aws_auth: error %v, want a NotStartedError about aws_auth", err)
	}
	if _, err := drv.NewTask(TaskSpec{ID: "Task-7"}, testClass); err == nil {
		t.Error("a task with no container must be refused")
	}
	e.mu.Lock()
	defer e.mu.Unlock()
	if len(e.pulled)+len(e.order)+len(e.networks)+len(e.volumes) != 0 {
		t.Errorf("the engine was touched: %v %v", e.pulled, e.order)
	}
}

func TestDockerDriverRecoverRemovesItsOwnLeftoversOnly(t *testing.T) {
	drv, e := newTestDriver(t)
	drv.opts.KeepFailed = true
	e.exit["primary"] = 1
	task, _ := drv.NewTask(testSpec("Task-8"), testClass)
	if res, err := task.Run(context.Background(), nil); err != nil || res.ExitCode != 1 {
		t.Fatalf("Run: %+v, %v", res, err)
	}
	e.mu.Lock()
	kept := len(e.ctrs)
	e.ctrs["id-other"] = &fakeCtr{name: "other", spec: ctrSpec{Labels: map[string]string{"app": "other"}}}
	e.mu.Unlock()
	if kept == 0 {
		t.Fatal("KeepFailed left nothing for Recover")
	}
	var r Recoverer = drv
	n, err := r.Recover(context.Background())
	if err != nil || n < kept {
		t.Fatalf("Recover removed %d, %v; want at least %d", n, err, kept)
	}
	e.mu.Lock()
	defer e.mu.Unlock()
	if len(e.ctrs) != 1 || e.ctrs["id-other"] == nil || len(e.networks) != 0 || len(e.volumes) != 0 {
		t.Errorf("left: %v %v %v", e.ctrs, e.networks, e.volumes)
	}
}

func TestDockerDriverKeepsTheTokenInThePrimaryOnly(t *testing.T) {
	drv, e := newTestDriver(t)
	task, _ := drv.NewTask(testSpec("Task-9"), testClass)
	if _, err := task.Run(context.Background(), nil); err != nil {
		t.Fatal(err)
	}
	n := "cci-" + shortID("Task-9")
	e.mu.Lock()
	defer e.mu.Unlock()
	for _, role := range []string{"init", "pause", "svc1"} {
		if s := fmt.Sprint(e.specs[n+"-"+role]); strings.Contains(s, "SENTINEL") {
			t.Errorf("the task token reached the %s container: %s", role, s)
		}
	}
	if s := fmt.Sprint(e.specs[n+"-primary"].Env); !strings.Contains(s, "SENTINEL") {
		t.Errorf("the primary container has no task token: %s", s)
	}
}
