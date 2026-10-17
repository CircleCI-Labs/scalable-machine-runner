#!/usr/bin/env python3
"""Stand-in for the CircleCI runner API, for tests only (drain.sh, task.sh).

Serves what the real circleci-runner needs to start, idle and run tasks: the task agent download (a
small shell script, see AGENT), "no task" (204) for a claim, or, for the first TASKS claims, a task
whose job config is empty. The runner starts the agent through its command_prefix, as for a real job;
the agent prints what it can see (its user, sudo, the token file, the working directory) to
stderr, which the runner passes on to its own output (stdout goes to the API). No token is checked. Usage: fake-api.py [PORT [TASKS [SLEEP]]]
SLEEP: seconds the agent runs (a long job), then it prints TASKEND to stderr. GET /_arm/N hands out N more tasks.

By default no token is checked and nothing is logged. proxy.sh turns on, with environment variables:
  CLASS_TOKENS=label=token,...  a claim must carry one of these tokens (else 401)
  PLACEHOLDER_TOKEN=token       the made-up token of the runners, to tell it apart in the log
  LOG_REQUESTS=1                one line per request, "REQ <method> <path> auth=<label> ua=<user agent>", never a token:
                                the label is CLASS:<label>, PLACEHOLDER, TASK (the task token of a claim), OTHER or NONE
The queue is held (every claim gets 204, no task) while the file /tmp/hold exists.
GET /api/v3/runner/scale answers like CircleCI's scale call for the class of the bearer token (with CLASS_TOKENS set, any other
token gets 401): {"data":{"attributes":{"unclaimed_task_count":N,"running_task_count":R}}}, the two names that CircleCI's own scale endpoint uses and
that the proxy reads, and nothing else. R is what GET /_running/R last set
(default 0: the test says how many tasks run, because the fake agent does not report the end of its job). While the file
/tmp/scale-fail exists the call answers 500. While the file /tmp/drop exists a claim is read and the connection is closed without an answer.
"""
import hashlib
import http.server
import json
import os
import sys

PORT = int(sys.argv[1]) if len(sys.argv) > 1 else 8099
TASKS = int(sys.argv[2]) if len(sys.argv) > 2 else 0
SLEEP = int(sys.argv[3]) if len(sys.argv) > 3 else 0
CLASS_TOKENS = dict(kv.split("=", 1)[::-1] for kv in os.environ.get("CLASS_TOKENS", "").split(",") if kv)  # token -> label
PLACEHOLDER = os.environ.get("PLACEHOLDER_TOKEN", "")
LOG_REQUESTS = os.environ.get("LOG_REQUESTS") == "1"
AGENT = b"""#!/bin/sh
w=${*#*--workDir=}; w=${w%% *}
case $1 in _internal) ;; *) exit 0 ;; esac   # the runner also runs "version" and the like
echo "TASK uid=$(id -u) user=$(id -un) home=$HOME workdir=$w residue=$(ls -A "$w" 2>/dev/null | wc -l)" \\
  "sudo=$(sudo -n true 2>/dev/null && echo yes || echo no)" \\
  "config=$(cat /run/secrets/circleci_runner_config.yaml >/dev/null 2>&1 && echo READABLE || echo denied)" \\
  "token_env=$(env | grep -c API_AUTH_TOKEN)" "no_new_privs=$(sed -n 's/^NoNewPrivs:[[:space:]]*//p' /proc/self/status)" >&2
mkdir -p "$w/project/.git/objects" "$w/project/sub" && echo data > "$w/project/.git/objects/pack" && echo x > "$w/project/sub/file"
""" + (b'sleep %d; echo TASKEND >&2\n' % SLEEP if SLEEP else b"") + b"""exit 0
"""
state = {"claims": 0, "limit": TASKS, "running": 0}


class Handler(http.server.BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"

    def _auth(self):
        a = self.headers.get("Authorization", "")
        t = a[len("Bearer "):] if a.startswith("Bearer ") else a
        if not a:
            return "NONE"
        if t in CLASS_TOKENS:
            return "CLASS:" + CLASS_TOKENS[t]
        return "PLACEHOLDER" if t and t == PLACEHOLDER else "TASK" if t.startswith("TASK-TOKEN-") else "OTHER"

    def _log(self):
        if LOG_REQUESTS:
            print("REQ %s %s auth=%s ua=%s" % (self.command, self.path.split("?")[0], self._auth(), self.headers.get("User-Agent", "-")), flush=True)

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
        self._log()
        if self.path.startswith("/api/v2/tasks/download"):
            doc = {
                "version": "1.0.0",
                "url": "http://%s/agent" % self.headers["Host"],
                "checksum": hashlib.sha256(AGENT).hexdigest(),
            }
            self._reply(200, json.dumps(doc).encode())
        elif self.path == "/agent":
            self._reply(200, AGENT, "application/octet-stream")
        elif self.path.startswith("/api/v3/runner/scale"):
            if os.path.exists("/tmp/scale-fail"):
                self._reply(500, b'{"error":{"title":"scale is down"}}')
            elif CLASS_TOKENS and not self._auth().startswith("CLASS:"):
                self._reply(401, b'{"message":"bad resource class token"}')
            else:
                doc = {"data": {"type": "scale", "attributes": {"unclaimed_task_count": 0, "running_task_count": state["running"]}}}
                self._reply(200, json.dumps(doc).encode())
        elif self.path.startswith("/_running/"):
            state["running"] = int(self.path.rsplit("/", 1)[1])
            self._reply(200, b"{}")
        elif self.path.startswith("/_arm/"):
            state["claims"], state["limit"] = 0, int(self.path.rsplit("/", 1)[1])
            self._reply(200, b"{}")
        elif self.path.startswith("/api/v2/task/config"):
            self._reply(200, b'{"job":{"config":{}}}')
        else:
            self._reply(404)

    def do_POST(self):
        self._drain_request_body()
        self._log()
        claim = self.path.startswith("/api/v3/runner/claim")
        if claim and os.path.exists("/tmp/drop"):
            self.close_connection = True   # no answer: the caller cannot tell whether the claim was acted on
            return
        if claim and CLASS_TOKENS and not self._auth().startswith("CLASS:"):
            self._reply(401, b'{"message":"bad resource class token"}')
        elif claim and state["claims"] < state["limit"] and not os.path.exists("/tmp/hold"):
            state["claims"] += 1
            self._reply(200, b'{"allocation":"a%d","task_token":"TASK-TOKEN-%d"}' % (state["claims"], state["claims"]))
        elif claim:
            self._reply(204)
        else:
            self._reply(200, b"{}")

    def log_message(self, *args):
        pass


http.server.ThreadingHTTPServer(("0.0.0.0", PORT), Handler).serve_forever()
