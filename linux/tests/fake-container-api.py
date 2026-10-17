#!/usr/bin/env python3
"""Stand-in for the CircleCI runner API, for the container-mode test only (container-mode.sh).

Serves a claim (POST /api/v3/runner/claim, checked against the class token) for each of two Docker-executor
tasks, the task config (GET /api/v2/task/config, checked against the task token of the claim), the events
(fail, cleanup, unclaim), and what the fake GOAT in the job reports (POST /test/report). GET /test/state
returns everything the test asserts on. Usage: fake-container-api.py PORT CLASS_TOKEN IMAGE
  task 0: succeeds. task 1: its primary exits with code 3.
Both hold the primary for a few seconds, so that two tasks would overlap if the agent let them.
"""
import http.server
import json
import sys
import threading

PORT, CLASS_TOKEN, IMAGE = int(sys.argv[1]), sys.argv[2], sys.argv[3]
lock = threading.Lock()
state = {"claims": 0, "inflight": 0, "max_inflight": 0, "events": [], "reports": []}


def task_config(n):
    primary_env = {"FOO": "bar", "BUILT": "${CIRCLE_JOB}", "FAKE_HOLD": "4", "FAKE_EXIT": "3" if n == 1 else "0"}
    return {
        "task_id": "00000000-0000-0000-0000-00000000000%d" % n,
        "job": {"config": {"docker": [
            {"image": IMAGE, "user": "circleci", "environment": primary_env},
            # the service: anything that listens on 5432, as a database would
            {"image": IMAGE, "entrypoint": ["python3", "-m", "http.server", "5432"], "environment": {"POSTGRES_PASSWORD": "x"}},
        ]}},
        "environment": {"built_in": {"CIRCLE_JOB": "build"}, "secret": {}},
    }


class Handler(http.server.BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"

    def _reply(self, code, obj=None):
        body = json.dumps(obj).encode() if obj is not None else b""
        self.send_response(code)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def _body(self):
        n = int(self.headers.get("Content-Length") or 0)
        return json.loads(self.rfile.read(n) or b"{}")

    def _bearer(self):
        return self.headers.get("Authorization", "").removeprefix("Bearer ")

    def _task(self):
        t = self._bearer()
        return int(t.removeprefix("task-token-")) if t.startswith("task-token-") else None

    def do_GET(self):
        with lock:
            if self.path == "/test/state":
                return self._reply(200, state)
            n = self._task()
            if self.path.startswith("/api/v2/task/config") and n is not None:
                return self._reply(200, task_config(n))
        self._reply(404)

    def do_POST(self):
        body = self._body()
        with lock:
            path = self.path
            if path == "/api/v3/runner/claim":
                if self._bearer() != CLASS_TOKEN:
                    return self._reply(401)
                if state["claims"] >= 2:
                    return self._reply(204)
                n = state["claims"]
                state["claims"] += 1
                state["inflight"] += 1
                state["max_inflight"] = max(state["max_inflight"], state["inflight"])
                return self._reply(200, {"task_token": "task-token-%d" % n, "resource_class": "ns/docker-default",
                                         "runner_init_image_tag": "agent", "allocation": "alloc-%d" % n})
            n = self._task()
            if n is None:
                return self._reply(401)
            if path == "/test/report":
                state["reports"].append(dict(body, task=n))
            elif path == "/api/v2/task/event/cleanup":
                state["events"].append({"task": n, "event": "cleanup"})
                state["inflight"] -= 1
            elif path == "/api/v2/task/event/fail":
                state["events"].append({"task": n, "event": "fail", "message": __import__("base64").b64decode(body["message"]).decode()})
            elif path == "/api/v3/runner/unclaim":
                state["events"].append({"task": n, "event": "unclaim"})
            else:
                return self._reply(404)
        self._reply(200, {})

    def log_message(self, *args):
        pass


http.server.ThreadingHTTPServer(("0.0.0.0", PORT), Handler).serve_forever()
