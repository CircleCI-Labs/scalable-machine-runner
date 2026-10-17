package main

// The wrapper side of the agent (see driver.go): the claim loop and the life of a claimed task as the runner API sees it.
// It claims tasks for its classes, only while a slot is free, turns each into a TaskSpec, runs it on the Driver, and tells the
// runner API how it ended. It does not know what a container is.

import (
	"context"
	"fmt"
	"log"
	"math/rand"
	"os"
	"sync"
	"time"
)

// wrapper holds what every task shares.
type wrapper struct {
	cfg    *config
	api    *runnerAPI
	driver Driver
	sem    chan struct{} // the concurrency cap of this node
	wg     sync.WaitGroup
}

// run claims until ctx ends. It claims only while a slot is free, because a claim assigns the task to this
// agent. Running tasks always finish: they use their own context.
func (w *wrapper) run(ctx context.Context) {
	var cw sync.WaitGroup
	for _, cl := range w.cfg.Classes {
		cw.Add(1)
		go func() {
			defer cw.Done()
			w.claimLoop(ctx, cl)
		}()
	}
	cw.Wait()
	log.Printf("draining: waiting for %d running task(s)", len(w.sem))
	w.wg.Wait()
}

func (w *wrapper) claimLoop(ctx context.Context, cl *class) {
	backoff := w.cfg.PollEvery
	for ctx.Err() == nil {
		select {
		case w.sem <- struct{}{}:
		case <-ctx.Done():
			return
		}
		c, err := w.api.claimTask(ctx, cl.token, w.cfg.Name, w.cfg.Name)
		if err != nil || c == nil {
			<-w.sem
			if err != nil && ctx.Err() == nil {
				log.Printf("class %s: claim failed: %v", cl.Name, err)
				backoff = min(backoff*2, 30*time.Second)
			} else {
				backoff = w.cfg.PollEvery
			}
			wait(ctx, backoff+time.Duration(rand.Int63n(int64(backoff)/4+1)))
			continue
		}
		backoff = w.cfg.PollEvery
		w.wg.Add(1)
		go func() {
			defer w.wg.Done()
			defer func() { <-w.sem }()
			w.runTask(context.WithoutCancel(ctx), cl, c)
		}()
	}
}

// recoverOrphans removes what an earlier crash left, if the driver can. Nothing of ours can be running yet, because Swarm updates
// the service stop-first.
func (w *wrapper) recoverOrphans(ctx context.Context) {
	r, ok := w.driver.(Recoverer)
	if !ok {
		return
	}
	if n, err := r.Recover(ctx); err != nil {
		log.Printf("startup cleanup: removed %d, then: %v", n, err)
	} else {
		log.Printf("startup cleanup: removed %d orphaned container(s), network(s) and volume(s)", n)
	}
}

// runTask runs one claimed task from start to finish and reports the outcome. It never panics out.
func (w *wrapper) runTask(ctx context.Context, cl *class, c *claim) {
	tok := c.TaskToken
	tc, err := w.api.taskConfig(ctx, tok)
	if err != nil {
		w.reportFail(ctx, tok, c, "", fmt.Errorf("could not get the task config: %w", err))
		return
	}
	id := shortID(tc.TaskID)
	log.Printf("task %s (%s): start, %d container(s)", id, cl.Name, len(tc.Job.Config.Docker))
	if len(tc.Job.Config.Docker) == 0 {
		w.reportFail(ctx, tok, c, tc.TaskID, fmt.Errorf("this is a machine job; %s is a container-mode class: use a machine class for machine jobs", cl.Name))
		return
	}
	taskCtx, cancel := context.WithTimeout(ctx, w.cfg.MaxRunTime+time.Minute)
	defer cancel()

	// The driver removes what it created before Run returns, and the API is told after that (container runner does it in this order).
	exit, runErr := w.execute(taskCtx, cl, c, tc, id)
	cctx, ccancel := context.WithTimeout(context.WithoutCancel(ctx), 2*time.Minute)
	defer ccancel()
	switch {
	case runErr != nil && !w.reportRetry(cctx, tok, tc.TaskID, id, runErr):
		w.reportFail(cctx, tok, c, tc.TaskID, runErr)
	case runErr == nil && exit != 0:
		w.reportFail(cctx, tok, c, tc.TaskID, fmt.Errorf("primary container exited with code %d. Check the job output for details", exit))
	case runErr == nil:
		log.Printf("task %s: finished", id)
	}
	if err := w.api.cleanup(cctx, tok); err != nil && runErr == nil {
		log.Printf("task %s: cleanup event: %v", id, err)
	}
}

// execute makes the task on the driver and runs it. It returns the exit code of the job's primary container.
func (w *wrapper) execute(ctx context.Context, cl *class, c *claim, tc *taskConfig, id string) (int, error) {
	task, err := w.driver.NewTask(w.taskSpec(c, tc), cl.settings())
	if err != nil {
		return 0, err
	}
	res, err := task.Run(ctx, func(s State) { log.Printf("task %s: %s", id, s) })
	return res.ExitCode, err
}

// taskSpec turns a claim and its task configuration into the spec of a driver. Variables are expanded here, from the
// secret and built-in variables of the task, as container runner does, so the driver sees only final values.
func (w *wrapper) taskSpec(c *claim, tc *taskConfig) TaskSpec {
	spec := TaskSpec{ID: tc.TaskID, Token: c.TaskToken, Allocation: c.Allocation, InitImageTag: c.RunnerInitImageTag,
		RunnerAPI: w.cfg.RunnerAPI, MaxRunTime: w.cfg.MaxRunTime}
	for _, dc := range tc.Job.Config.Docker {
		cs := ContainerSpec{Image: expand(dc.Image, tc), User: dc.User, WorkingDir: dc.WorkingDir, Command: dc.Command,
			Entrypoint: dc.Entrypoint, AWSAuth: dc.AWSAuth != nil, Environment: make(map[string]string, len(dc.Environment))}
		for k, v := range dc.Environment {
			cs.Environment[k] = expand(v, tc)
		}
		if a := dc.Auth; a != nil {
			cs.Auth = &RegistryAuth{Username: expand(a.Username, tc), Password: secret(expand(a.Password.Raw(), tc)),
				Auth: secret(expand(a.Auth.Raw(), tc)), Email: expand(a.Email, tc), ServerAddress: expand(a.ServerAddress, tc)}
		}
		spec.Containers = append(spec.Containers, cs)
	}
	return spec
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

// reportRetry puts a task whose containers never started back in the queue. It reports false if that is not possible.
func (w *wrapper) reportRetry(ctx context.Context, tok secret, taskID, id string, cause error) bool {
	if !isNotStarted(cause) {
		return false
	}
	if err := w.api.unclaim(ctx, tok, taskID); err != nil {
		log.Printf("task %s: unclaim: %v", id, err)
		return false
	}
	log.Printf("task %s: unclaimed for a retry after: %v", id, cause)
	return true
}

func (w *wrapper) reportFail(ctx context.Context, tok secret, c *claim, taskID string, cause error) {
	log.Printf("task %s: failed: %v", shortID(taskID), cause)
	if err := w.api.fail(ctx, tok, c.Allocation, cause.Error()); err != nil {
		log.Printf("task %s: fail event: %v", shortID(taskID), err)
	}
}

// wait sleeps for d, or until ctx ends. (The driver has its own copy, sleepCtx: neither side uses the other's helpers.)
func wait(ctx context.Context, d time.Duration) {
	t := time.NewTimer(d)
	defer t.Stop()
	select {
	case <-ctx.Done():
	case <-t.C:
	}
}
