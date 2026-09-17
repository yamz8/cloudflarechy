#!/usr/bin/env python3
"""A stand-in for the Cloudflare API, shaped like the real one.

Every field here was checked against a live account before it was written
down: the zone object carries `development_mode` as seconds (negative once it
has lapsed), tunnels carry `connections` as a list and a status drawn from
inactive/degraded/healthy/down, Workers scripts key their name as `id`, and
the GraphQL analytics endpoint answers `httpRequests1hGroups` with 24 hourly
buckets. If Cloudflare changes any of that, these tests keep passing and the
plugin still breaks — which is the honest limit of a fixture.

The one deliberate divergence: `uniques` is rejected here, because that is the
failure the plugin has a retry path for and a fixture that never fails it
would never exercise it.
"""
import json
import re
import sys
import datetime
from http.server import BaseHTTPRequestHandler, HTTPServer

ZONE = "a1b2c3d4e5f60718293a4b5c6d7e8f90"
# A zone on a plan that serves neither `uniques` nor `responseStatusMap`, so the
# query's last fallback rung gets walked.
ZONE2 = "b" * 32
ACCOUNT = "0f9e8d7c6b5a40312f1e0d9c8b7a6554"
# An account whose Workers list is readable but whose invocation analytics are
# not — the plugin should still list the scripts.
ACCOUNT_NO_METRICS = "1" * 32

STATE = {"security_level": "high", "development_mode": 0, "purges": 0}


def ok(result):
    return {"success": True, "errors": [], "messages": [], "result": result}


def denied(message="Unauthorized to access requested resource", code=9109):
    return {"success": False, "errors": [{"code": code, "message": message}],
            "messages": [], "result": None}


def zone_object(zone_id=ZONE, name="example.com"):
    return {
        "id": zone_id, "name": name, "status": "active", "paused": False,
        "plan": {"name": "Free Website"},
        "development_mode": STATE["development_mode"],
        "account": {"id": ACCOUNT, "name": "Acme Inc"},
    }


def hourly(with_status=False):
    now = datetime.datetime.now(datetime.timezone.utc).replace(
        minute=0, second=0, microsecond=0)
    out = []
    for i in range(24):
        t = now - datetime.timedelta(hours=23 - i)
        requests = 400 + i * 37
        group = {
            "dimensions": {"datetime": t.strftime("%Y-%m-%dT%H:00:00Z")},
            "sum": {"requests": requests, "bytes": requests * 2400,
                    "cachedRequests": int(requests * 0.82),
                    "cachedBytes": int(requests * 2400 * 0.77),
                    "threats": i % 5},
        }
        if with_status:
            # Ten 5xx and five 4xx an hour, the rest fine: enough that the
            # totals are exact and hand-checkable.
            group["sum"]["responseStatusMap"] = [
                {"edgeResponseStatus": 200, "requests": requests - 15},
                {"edgeResponseStatus": 404, "requests": 5},
                {"edgeResponseStatus": 503, "requests": 10},
            ]
        out.append(group)
    return out


class Handler(BaseHTTPRequestHandler):
    def log_message(self, *args):
        pass

    def reply(self, payload, code=200):
        body = json.dumps(payload).encode()
        self.send_response(code)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    # A token the tests can use to drive the unauthorised paths.
    def scoped_out(self):
        return self.headers.get("Authorization", "").endswith("read-only-token")

    def do_GET(self):
        path = self.path.split("?")[0]
        if path == "/user/tokens/verify":
            # The token the tests paste when they want a refusal.
            if self.headers.get("Authorization", "").endswith("bad-token"):
                return self.reply(denied("Invalid API Token", 1000), 403)
            return self.reply(ok({"id": "tok", "status": "active"}))
        if path == "/zones":
            return self.reply(ok([zone_object(),
                                  zone_object(ZONE2, "second.dev")]))
        if path == f"/zones/{ZONE}":
            return self.reply(ok(zone_object()))
        if path == f"/zones/{ZONE2}":
            return self.reply(ok(zone_object(ZONE2, "second.dev")))
        if re.fullmatch(r"/zones/\w+/settings/security_level", path):
            if self.scoped_out():
                return self.reply(denied(), 403)
            return self.reply(ok({"id": "security_level",
                                  "value": STATE["security_level"]}))
        if path == f"/accounts/{ACCOUNT}/cfd_tunnel":
            return self.reply(ok([
                {"id": "t1", "name": "homelab", "status": "healthy",
                 "connections": [{}, {}], "created_at": "2026-01-02T03:04:05Z"},
                {"id": "t2", "name": "staging", "status": "down",
                 "connections": [], "created_at": "2026-02-02T03:04:05Z"},
            ]))
        if path in (f"/accounts/{ACCOUNT}/workers/scripts",
                    f"/accounts/{ACCOUNT_NO_METRICS}/workers/scripts"):
            return self.reply(ok([
                {"id": "api-router", "modified_on": "2026-09-16T10:00:00Z"},
                {"id": "image-resize", "modified_on": "2026-09-01T10:00:00Z"},
                {"id": "cron-cleanup", "modified_on": "2026-08-01T10:00:00Z"},
            ]))
        return self.reply(denied("no route " + path, 7003), 404)

    def do_PATCH(self):
        length = int(self.headers.get("Content-Length", 0))
        body = json.loads(self.rfile.read(length) or b"{}")
        path = self.path.split("?")[0]
        if self.scoped_out():
            return self.reply(denied(), 403)
        if path.endswith("/settings/security_level"):
            STATE["security_level"] = body.get("value", "medium")
            return self.reply(ok({"id": "security_level",
                                  "value": STATE["security_level"]}))
        if path.endswith("/settings/development_mode"):
            on = body.get("value") == "on"
            STATE["development_mode"] = 10800 if on else 0
            return self.reply(ok({"id": "development_mode",
                                  "value": body.get("value"),
                                  "time_remaining": STATE["development_mode"]}))
        return self.reply(denied("no route " + path, 7003), 404)

    def do_POST(self):
        length = int(self.headers.get("Content-Length", 0))
        raw = self.rfile.read(length) or b"{}"
        path = self.path.split("?")[0]
        if path == "/graphql":
            body = json.loads(raw)
            query = body.get("query", "")
            variables = body.get("variables", {})

            if "workersInvocationsAdaptive" in query:
                if variables.get("account") == ACCOUNT_NO_METRICS:
                    return self.reply({"data": None, "errors": [
                        {"message": "account analytics are not readable with this token"}]})
                return self.reply({"data": {"viewer": {"accounts": [{
                    "workersInvocationsAdaptive": [
                        {"dimensions": {"scriptName": "api-router", "status": "success"},
                         "sum": {"requests": 3000, "errors": 0, "subrequests": 120},
                         "quantiles": {"cpuTimeP50": 8644}},
                        # A second, quieter status for the same script: requests
                        # add up, the p50 comes from the busier one.
                        {"dimensions": {"scriptName": "api-router", "status": "clientDisconnected"},
                         "sum": {"requests": 40, "errors": 0, "subrequests": 0},
                         "quantiles": {"cpuTimeP50": 99999}},
                        {"dimensions": {"scriptName": "image-resize", "status": "scriptThrewException"},
                         "sum": {"requests": 12, "errors": 12, "subrequests": 0},
                         "quantiles": {"cpuTimeP50": 457}},
                    ]}]}}, "errors": None})

            # Zone analytics. uniques is never available here; the second zone
            # additionally refuses status codes.
            if "uniques" in query:
                return self.reply({"data": None, "errors": [
                    {"message": "field uniques is not available on this plan"}]})
            wants_status = "responseStatusMap" in query
            if wants_status and variables.get("zone") == ZONE2:
                return self.reply({"data": None, "errors": [
                    {"message": "field responseStatusMap is not available on this plan"}]})
            return self.reply({"data": {"viewer": {"zones": [
                {"httpRequests1hGroups": hourly(wants_status)}]}}, "errors": None})
        if path.endswith("/purge_cache"):
            if self.scoped_out():
                return self.reply(denied(), 403)
            STATE["purges"] += 1
            return self.reply(ok({"id": ZONE}))
        return self.reply(denied("no route " + path, 7003), 404)


if __name__ == "__main__":
    port = int(sys.argv[1]) if len(sys.argv) > 1 else 8787
    HTTPServer(("127.0.0.1", port), Handler).serve_forever()
