#!/usr/bin/env python3
"""Stand-in for the CircleCI runner API, for tests only (drain.sh, task.sh).

Serves what the real circleci-runner needs to start, idle and run tasks: the task agent download (a
small shell script, see AGENT), "no task" (204) for a claim, or, for the first TASKS claims, a task
whose job config is empty. The runner starts the agent through its command_prefix, as for a real job;
the agent prints what it can see (its user, sudo, the token file, the working directory) to
stderr, which the runner passes on to its own output (stdout goes to the API). No token is checked. Usage: fake-api.py [PORT [TASKS]]
"""
import hashlib
import http.server
import json
import sys

PORT = int(sys.argv[1]) if len(sys.argv) > 1 else 8099
TASKS = int(sys.argv[2]) if len(sys.argv) > 2 else 0
AGENT = b"""#!/bin/sh
w=${*#*--workDir=}; w=${w%% *}
case $1 in _internal) ;; *) exit 0 ;; esac   # the runner also runs "version" and the like
echo "TASK uid=$(id -u) user=$(id -un) home=$HOME workdir=$w residue=$(ls -A "$w" 2>/dev/null | wc -l)" \\
  "sudo=$(sudo -n true 2>/dev/null && echo yes || echo no)" \\
  "config=$(cat /run/secrets/circleci_runner_config.yaml >/dev/null 2>&1 && echo READABLE || echo denied)" \\
  "token_env=$(env | grep -c API_AUTH_TOKEN)" >&2
mkdir -p "$w/project/.git/objects" "$w/project/sub" && echo data > "$w/project/.git/objects/pack" && echo x > "$w/project/sub/file"
exit 0
"""
state = {"claims": 0}


class Handler(http.server.BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"

    def _reply(self, code, body=b"", ctype="application/json"):
        self.send_response(code)
        self.send_header("Content-Type", ctype)
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def _drain_request_body(self):
        if self.headers.get("Transfer-Encoding", "").lower() == "chunked":
            while True:
                size = int(self.rfile.readline().strip() or b"0", 16)
                self.rfile.read(size + 2)
                if size == 0:
                    break
        else:
            self.rfile.read(int(self.headers.get("Content-Length") or 0))

    def do_GET(self):
        if self.path.startswith("/api/v2/tasks/download"):
            doc = {
                "version": "1.0.0",
                "url": "http://%s/agent" % self.headers["Host"],
                "checksum": hashlib.sha256(AGENT).hexdigest(),
            }
            self._reply(200, json.dumps(doc).encode())
        elif self.path == "/agent":
            self._reply(200, AGENT, "application/octet-stream")
        elif self.path.startswith("/api/v2/task/config"):
            self._reply(200, b'{"job":{"config":{}}}')
        else:
            self._reply(404)

    def do_POST(self):
        self._drain_request_body()
        if self.path.startswith("/api/v3/runner/claim") and state["claims"] < TASKS:
            state["claims"] += 1
            self._reply(200, b'{"allocation":"a%d"}' % state["claims"])
        elif self.path.startswith("/api/v3/runner/claim"):
            self._reply(204)
        else:
            self._reply(200, b"{}")

    def log_message(self, *args):
        pass


http.server.ThreadingHTTPServer(("0.0.0.0", PORT), Handler).serve_forever()
