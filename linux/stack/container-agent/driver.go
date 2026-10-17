package main

// This file is the driver interface of the container agent: the one place that says what "run a Docker-executor job"
// means, apart from where it runs and how the job reaches the runner API.
//
// The agent has two sides, and each is in files of its own. The Swarm configs of container-mode.yaml deliver each file
// separately, so this is one package and not several, but the rule of the split holds as if it were several:
//
//	the driver  (this file, and driver_docker.go, docker.go)  creates and removes the containers of a task. It knows the
//	            container engine and the shape of a job (a primary container and its services). It knows nothing of the
//	            runner API, of claiming, of class tokens or of how many tasks run at once.
//	the wrapper (main.go, wrapper.go, api.go)  reads the settings, claims tasks from the runner API, hands each one to a
//	            Driver, tells the API how it ended, and handles signals and logs. It knows nothing of containers.
//
// Nothing in the driver files may use the wrapper's types (the runner API client, claim, taskConfig, class, config), and
// nothing in the wrapper files may call the container engine. A driver for another engine replaces driver_docker.go and
// docker.go and nothing else.

import (
	"context"
	"crypto/rand"
	"crypto/sha256"
	"encoding/hex"
	"errors"
	"time"
)

// Driver makes tasks that run on one container engine. It is safe for concurrent use: the wrapper runs several tasks of
// one Driver at the same time, each in its own Task.
type Driver interface {
	// NewTask checks the spec and the class settings and returns a Task that is ready to run. It has no effect on the
	// host: no image is pulled and no container, network or volume is created, so a Task that is never run leaves
	// nothing to clean up.
	//
	// It returns an error for a spec that this driver cannot run, for example a feature it does not support. An error
	// that is a *NotStartedError says that the task may be given back to the queue.
	NewTask(spec TaskSpec, class ClassSettings) (Task, error)
}

// Task is one claimed task, ready to run on a Driver.
type Task interface {
	// ID is a short name of the task, safe in a log line and in the name of a resource. It is shortID of the task ID of
	// the spec, and the driver puts it in the names and labels of what it creates, so that the task can be found by it.
	ID() string

	// Run runs the task to completion: it starts what the job needs, waits for the job's primary container to stop, and
	// returns its exit code. It runs at most once for a Task.
	//
	// When Run returns, in every case, it has removed everything that it created for this task, or has tried to for as
	// long as it reasonably can, and has logged what it could not remove. The cases are a job that ends, a job that fails,
	// a setup that fails half way, and a ctx that ends: cancel ctx to stop the job, and Run stops its containers and
	// removes them. The removal does not depend on ctx, which may be done by then. The exception is a driver that is set
	// to keep the resources of a failed task for debugging, which it says in the log, and which Recover then removes.
	//
	// Run calls report, if it is not nil, in the goroutine of Run and in the order of the states, once for each state it
	// reaches (a state that the task never reaches is not reported). report must return quickly.
	//
	// The error is nil when the primary container ran and stopped, whatever its exit code: look at Result. A non-nil
	// error is a failure of the driver or of the host. It is a *NotStartedError when nothing of the job ran, which makes
	// the task safe to run again elsewhere. An error that is not one, such as the end of ctx while the job ran, says that
	// the job may have run, partly or wholly.
	Run(ctx context.Context, report func(State)) (Result, error)
}

// Recoverer is an optional interface of a Driver: the wrapper calls Recover once at start-up if the driver has it.
type Recoverer interface {
	// Recover removes the resources of tasks that an earlier run of the agent created and did not remove, for example
	// after a crash, and returns how many it removed. It runs when no task of this driver can be running, so it may remove
	// everything that is the driver's.
	Recover(ctx context.Context) (removed int, err error)
}

// State is where a Task is in its life.
type State string

// The states of a Task, in the order that Run reports them.
const (
	// StatePreparing: Run has started and the job's primary container has not. The images are pulled, the network and the
	// volume are created, and the containers around the primary are started.
	StatePreparing State = "preparing"
	// StateRunning: the job's primary container has started.
	StateRunning State = "running"
	// StateCleaningUp: the job is over, or has failed, and the resources of the task are being removed.
	StateCleaningUp State = "cleaning-up"
)

// TaskSpec is what a driver needs to make a Task of a claimed task. All variables in it are already expanded: the
// driver sees no unexpanded reference and no secret that is not named below.
type TaskSpec struct {
	// ID is the ID of the task, as the runner API gives it. It may be empty, then the driver still needs a unique name.
	ID string
	// Containers are the containers of the job: the primary container first, then the services. There is at least one.
	Containers []ContainerSpec
	// Token is the task token of this one task. The driver gives it to the job's task agent, in the primary container
	// only, and to nothing else. It never appears in a log or an error message: it is a secret.
	Token secret
	// Allocation is the opaque allocation of the claim, which the task agent returns to the runner API.
	Allocation string
	// InitImageTag is the tag of the image that holds the task agent that the server expects, when the claim names one.
	// A driver that injects the task agent by an image uses it, unless its own settings name an image.
	InitImageTag string
	// RunnerAPI is the URL of the runner API that the job's task agent calls.
	RunnerAPI string
	// MaxRunTime is how long the job may run. The wrapper ends the ctx of Run when it is over, and the driver tells the
	// task agent, which stops the job itself.
	MaxRunTime time.Duration
}

// ContainerSpec is one container of the job, as the job configuration describes it.
type ContainerSpec struct {
	Image       string
	User        string
	WorkingDir  string
	Command     []string
	Entrypoint  []string
	Environment map[string]string
	// Auth is the credential for the registry of Image, or nil. It is for pulling Image only: the driver keeps it in
	// memory and writes it to no container, volume or file.
	Auth *RegistryAuth
	// AWSAuth is true when the job asks for registry authentication through AWS (ECR).
	AWSAuth bool
}

// RegistryAuth is the credential for one registry. Auth is the base64 of "user:password", an alternative to Password.
type RegistryAuth struct {
	Username      string
	Password      secret
	Auth          secret
	Email         string
	ServerAddress string
}

// ClassSettings are the settings of the resource class that claimed the task.
type ClassSettings struct {
	// Name is <namespace>/<class>, as in the resource_class of a job.
	Name string
	// Primary caps the primary container, and Service caps each service container. A zero field is no cap, except the
	// process limit, which a driver may default.
	Primary, Service Limits
}

// Limits caps one container. Zero means no cap.
type Limits struct {
	CPUs     float64 `json:"cpus"`
	MemoryMB int64   `json:"memory_mb"`
	Pids     int64   `json:"pids"`
}

// Result is how a job ended, when Run returns no error.
type Result struct {
	// ExitCode is the exit code of the primary container. Not zero means that the job failed.
	ExitCode int
}

// NotStartedError is the error of a Task that never ran its job: nothing of it started, so the task can be run again, on
// this node or on another one. Check for it with errors.As.
type NotStartedError struct{ Err error }

func (e *NotStartedError) Error() string { return e.Err.Error() }
func (e *NotStartedError) Unwrap() error { return e.Err }

// notStarted wraps err as a *NotStartedError.
func notStarted(err error) error { return &NotStartedError{Err: err} }

// isNotStarted reports whether err is, or wraps, a *NotStartedError.
func isNotStarted(err error) bool {
	var ns *NotStartedError
	return errors.As(err, &ns)
}

// secret keeps a token out of logs and error messages: fmt prints it as ***.
type secret string

func (secret) String() string   { return "***" }
func (s secret) Raw() string    { return string(s) }
func (secret) GoString() string { return "***" }

// shortID names a task in logs and in the resources of a driver: a prefix of the hash of the task ID, safe in any Docker
// name. A task with no ID gets a random one.
func shortID(taskID string) string {
	if taskID == "" {
		b := make([]byte, 6)
		_, _ = rand.Read(b)
		return hex.EncodeToString(b)
	}
	h := sha256.Sum256([]byte(taskID))
	return hex.EncodeToString(h[:6])
}
