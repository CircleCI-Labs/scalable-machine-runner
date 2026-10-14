#!/usr/bin/env python3
"""Stand-in for the orchestrator image of container runner (circleci/runner-init), for container-mode.sh.

It is installed in a fake init image as /orchestrator and /circleci-agent, the way the real image holds
them, and it does what the agent relies on:
  init [SRC [DST]]  copy both files to DST (default /opt/circleci/bin), then exit
  run-task          read CIRCLECI_GOAT_CONFIG, drop it from the environment, look around as a job would
                    (the service on localhost:5432, the environment, the socket, secrets, limits) and
                    report that to the fake API with the task token. Then hold for FAKE_HOLD seconds
                    and exit with FAKE_EXIT.
"""
import json
import os
import shutil
import socket
import sys
import time
import urllib.request

if len(sys.argv) > 1 and sys.argv[1] == "init":
    dst = sys.argv[3] if len(sys.argv) > 3 else "/opt/circleci/bin"
    for name in ("orchestrator", "circleci-agent"):
        shutil.copy2("/" + name, os.path.join(dst, name))
    sys.exit(0)

cfg = json.loads(os.environ.pop("CIRCLECI_GOAT_CONFIG"))


def first_line(path):
    try:
        with open(path) as f:
            return f.read().strip()
    except OSError:
        return None


report = {
    "token_ok": cfg["token"].startswith("task-token-") and cfg["allocation"].startswith("alloc-"),
    "task_agent_path": cfg["task_agent_path"],
    "user": cfg["user"],
    "uid": os.getuid(),
    "hostname": socket.gethostname(),
    "env_foo": os.environ.get("FOO"),
    "env_built": os.environ.get("BUILT"),
    "goat_config_in_env": "CIRCLECI_GOAT_CONFIG" in os.environ,
    "socket_present": os.path.exists("/var/run/docker.sock"),
    "secrets_dir": os.path.exists("/run/secrets"),
    "class_token_visible": any("SENTINEL-TOKEN" in v for v in os.environ.values()),
    "memory_max": first_line("/sys/fs/cgroup/memory.max"),
    "cpu_max": first_line("/sys/fs/cgroup/cpu.max"),
    "bin_files": sorted(os.listdir("/opt/circleci/bin")),
}
try:
    with socket.create_connection(("localhost", 5432), timeout=20) as s:
        s.sendall(b"GET / HTTP/1.0\r\n\r\n")
        report["service_reply"] = s.recv(32).decode(errors="replace").split("\r\n")[0]
except OSError as e:
    report["service_reply"] = "ERROR %s" % e

req = urllib.request.Request(cfg["runner_api_base_url"] + "/test/report", json.dumps(report).encode(),
                             {"Authorization": "Bearer " + cfg["token"], "Content-Type": "application/json"})
urllib.request.urlopen(req, timeout=20).read()
time.sleep(float(os.environ.get("FAKE_HOLD", "0")))
sys.exit(int(os.environ.get("FAKE_EXIT", "0")))
