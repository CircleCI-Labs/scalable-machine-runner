package main

import (
	"bytes"
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"net"
	"net/http"
	"net/url"
	"strings"
	"time"
)

// docker is the small part of the Docker Engine API that container mode needs, over the engine's unix
// socket. The agent is the only component that holds the socket.
type docker struct {
	hc   *http.Client
	base string
}

const apiVersion = "v1.41" // Docker Engine 20.10 and later

func newDocker(socket string) *docker {
	tr := &http.Transport{DialContext: func(ctx context.Context, _, _ string) (net.Conn, error) {
		return (&net.Dialer{}).DialContext(ctx, "unix", socket)
	}}
	return &docker{hc: &http.Client{Transport: tr}, base: "http://docker/" + apiVersion}
}

// call sends one request. out is a pointer to decode the JSON response into, or a func(io.Reader) error that
// reads a streamed body (image pulls, container logs). A non-2xx answer is an error with the engine's message.
func (d *docker) call(ctx context.Context, method, path string, in, out any, hdr ...string) error {
	var body io.Reader
	if in != nil {
		b, err := json.Marshal(in)
		if err != nil {
			return err
		}
		body = bytes.NewReader(b)
	}
	req, err := http.NewRequestWithContext(ctx, method, d.base+path, body)
	if err != nil {
		return err
	}
	if in != nil {
		req.Header.Set("Content-Type", "application/json")
	}
	for i := 0; i+1 < len(hdr); i += 2 {
		req.Header.Set(hdr[i], hdr[i+1])
	}
	resp, err := d.hc.Do(req)
	if err != nil {
		return err
	}
	defer func() { _ = resp.Body.Close() }()
	if resp.StatusCode/100 != 2 {
		msg, _ := io.ReadAll(io.LimitReader(resp.Body, 4096))
		return fmt.Errorf("docker %s %s: %s: %s", method, strings.SplitN(path, "?", 2)[0], resp.Status, strings.TrimSpace(string(msg)))
	}
	switch o := out.(type) {
	case nil:
		_, _ = io.Copy(io.Discard, resp.Body)
		return nil
	case func(io.Reader) error:
		return o(resp.Body)
	default:
		return json.NewDecoder(resp.Body).Decode(out)
	}
}

// pull fetches image (a name with a tag or a digest). auth is the base64url X-Registry-Auth value, or "".
func (d *docker) pull(ctx context.Context, image, auth string) error {
	// The body is a stream of JSON progress messages; an error arrives in it after a 200.
	read := func(r io.Reader) error {
		for dec := json.NewDecoder(r); ; {
			var m struct{ Error string }
			if err := dec.Decode(&m); err == io.EOF {
				return nil
			} else if err != nil {
				return err
			} else if m.Error != "" {
				return errors.New(m.Error)
			}
		}
	}
	if err := d.call(ctx, "POST", "/images/create?fromImage="+url.QueryEscape(image), nil, read, "X-Registry-Auth", auth); err != nil {
		return fmt.Errorf("pull %s: %w", image, err)
	}
	return nil
}

func (d *docker) hasImage(ctx context.Context, image string) bool {
	return d.call(ctx, "GET", "/images/"+url.PathEscape(image)+"/json", nil, nil) == nil
}

// hostConfig and ctrSpec are the fields of POST /containers/create that container mode sets.
type hostConfig struct {
	NetworkMode   string
	Binds         []string `json:",omitempty"`
	NanoCpus      int64    `json:",omitempty"`
	Memory        int64    `json:",omitempty"`
	MemorySwap    int64    `json:",omitempty"` // equal to Memory: no swap
	PidsLimit     int64    `json:",omitempty"`
	CapDrop       []string `json:",omitempty"`
	RestartPolicy struct{ Name string }
	LogConfig     struct {
		Type   string
		Config map[string]string
	}
}

type ctrSpec struct {
	Image      string
	Hostname   string `json:",omitempty"`
	User       string `json:",omitempty"`
	WorkingDir string `json:",omitempty"`
	Entrypoint []string
	Cmd        []string
	Env        []string
	Tty        bool
	OpenStdin  bool
	Labels     map[string]string
	HostConfig hostConfig
}

func (d *docker) create(ctx context.Context, name string, s ctrSpec) (string, error) {
	s.HostConfig.RestartPolicy.Name = "no"
	s.HostConfig.LogConfig.Type = "local"
	s.HostConfig.LogConfig.Config = map[string]string{"max-size": "20m", "max-file": "2"}
	var r struct{ Id string }
	err := d.call(ctx, "POST", "/containers/create?name="+url.QueryEscape(name), s, &r)
	return r.Id, err
}

// launch creates and starts a container.
func (d *docker) launch(ctx context.Context, name string, s ctrSpec) (string, error) {
	id, err := d.create(ctx, name, s)
	if err == nil {
		err = d.call(ctx, "POST", "/containers/"+id+"/start", nil, nil)
	}
	return id, err
}

// wait blocks until the container stops and returns its exit code.
func (d *docker) wait(ctx context.Context, id string) (int, error) {
	var r struct{ StatusCode int }
	err := d.call(ctx, "POST", "/containers/"+id+"/wait?condition=not-running", nil, &r)
	return r.StatusCode, err
}

// tail returns the last lines of a container's output (used to explain an init failure).
func (d *docker) tail(ctx context.Context, id string) (out string) {
	_ = d.call(ctx, "GET", "/containers/"+id+"/logs?stdout=1&stderr=1&tail=20", nil, func(r io.Reader) error {
		b, _ := io.ReadAll(io.LimitReader(r, 4096))
		out = strings.ToValidUTF8(string(b), "")
		return nil
	})
	return out
}

func (d *docker) removeContainer(ctx context.Context, id string) error {
	return d.call(ctx, "DELETE", "/containers/"+id+"?force=1&v=1", nil, nil)
}

func (d *docker) createNetwork(ctx context.Context, name string, labels map[string]string) error {
	return d.call(ctx, "POST", "/networks/create", map[string]any{"Name": name, "Driver": "bridge", "Labels": labels}, nil)
}

func (d *docker) createVolume(ctx context.Context, name string, labels map[string]string) error {
	return d.call(ctx, "POST", "/volumes/create", map[string]any{"Name": name, "Labels": labels}, nil)
}

func filter(label string) string {
	b, _ := json.Marshal(map[string][]string{"label": {label}})
	return url.QueryEscape(string(b))
}

// sweep removes every container, network and volume that carries label, containers first. It is the garbage
// collection of orphans after a crash, and the cleanup of one task by its task label.
func (d *docker) sweep(ctx context.Context, label string) (n int, err error) {
	each := func(list string, out any, ids func() []string, del func(id string) string) {
		if e := d.call(ctx, "GET", list+"filters="+filter(label), nil, out); e != nil {
			err = e
		}
		for _, id := range ids() {
			if e := d.call(ctx, "DELETE", del(id), nil, nil); e != nil {
				err = e
			}
			n++
		}
	}
	var cs, ns []struct{ Id string }
	var vs struct{ Volumes []struct{ Name string } }
	each("/containers/json?all=1&", &cs, func() (r []string) {
		for _, c := range cs {
			r = append(r, c.Id)
		}
		return
	}, func(id string) string { return "/containers/" + id + "?force=1&v=1" })
	each("/networks?", &ns, func() (r []string) {
		for _, c := range ns {
			r = append(r, c.Id)
		}
		return
	}, func(id string) string { return "/networks/" + id })
	each("/volumes?", &vs, func() (r []string) {
		for _, v := range vs.Volumes {
			r = append(r, v.Name)
		}
		return
	}, func(id string) string { return "/volumes/" + id + "?force=1" })
	return n, err
}

func sleepCtx(ctx context.Context, d time.Duration) {
	t := time.NewTimer(d)
	defer t.Stop()
	select {
	case <-ctx.Done():
	case <-t.C:
	}
}
