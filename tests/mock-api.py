#!/usr/bin/env python3
"""A stand-in for the Cloudflare API, shaped like the real one.

Every field here was checked against a live account before it was written
down: the zone object carries `development_mode` as seconds (negative once it
has lapsed), tunnels carry `connections` as a list and a status drawn from
inactive/degraded/healthy/down, Workers scripts key their name as `id`, and
the GraphQL analytics endpoint answers `httpRequests1hGroups` with 48 hourly
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
# A zone younger than the 48-hour window: it has a last 24 hours and nothing
# before them, which is the case where a delta has no baseline to report.
ZONE_NEW = "c" * 32
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
    """Forty-eight hourly buckets: the last 24 hours, and the 24 before them.

    The script asks for 48 hours and splits them on the midpoint to compute a
    period-over-period delta, so a fixture of 24 could not tell a working split
    from one that compares the window against itself.

    The two halves are chosen so the deltas are exact rather than approximate:
    19812 requests against 13208 is precisely +50%, and the same 2400-byte
    multiplier makes bytes land on +50% too. The earlier half caches at 0.41
    against 0.82, so the cache ratio moves as well and a delta wired to the
    wrong field cannot pass by accident.
    """
    now = datetime.datetime.now(datetime.timezone.utc).replace(
        minute=0, second=0, microsecond=0)
    out = []
    for i in range(48):
        t = now - datetime.timedelta(hours=47 - i)
        recent = i >= 24
        if recent:
            requests = 400 + (i - 24) * 37
            cache_fraction = 0.82
            threats = (i - 24) % 5
        else:
            # 8 hours of 551 and 16 of 550 sum to 13208, two thirds of the
            # recent window. Nothing rides on the shape, only on the total.
            requests = 551 if i < 8 else 550
            cache_fraction = 0.41
            threats = 0
        group = {
            "dimensions": {"datetime": t.strftime("%Y-%m-%dT%H:00:00Z")},
            "sum": {"requests": requests, "bytes": requests * 2400,
                    "cachedRequests": int(requests * cache_fraction),
                    "cachedBytes": int(requests * 2400 * 0.77),
                    "threats": threats},
        }
        if with_status:
            # Ten 5xx and five 4xx an hour, the rest fine: enough that the
            # totals are exact and hand-checkable. Only the recent window
            # carries them, so a status total that silently includes the
            # baseline shows up as a wrong number rather than a wrong shape.
            if recent:
                group["sum"]["responseStatusMap"] = [
                    {"edgeResponseStatus": 200, "requests": requests - 15},
                    {"edgeResponseStatus": 404, "requests": 5},
                    {"edgeResponseStatus": 503, "requests": 10},
                ]
            else:
                group["sum"]["responseStatusMap"] = [
                    {"edgeResponseStatus": 200, "requests": requests},
                ]
        out.append(group)
    return out


def daily(buckets, with_status=False):
    """`buckets` daily rows, the newest half being the window under test.

    Same split as the hourly fixture and the same reason for it, at the other
    resolution: 7- and 30-day ranges come from httpRequests1dGroups, which is a
    different dataset keyed on `date` rather than `datetime`, so a query built
    for one and pointed at the other has to fail visibly.

    The recent half runs 1000, 2000, 3000 ... and the earlier half exactly half
    of that, so requests and bytes both land on +100%. Caching is 0.6 against
    0.4, which makes the ratio delta +50% — a different number from the other
    two, so a delta reading the wrong field cannot pass.
    """
    today = datetime.datetime.now(datetime.timezone.utc).date()
    window = buckets // 2
    out = []
    for i in range(buckets):
        d = today - datetime.timedelta(days=buckets - 1 - i)
        recent = i >= window
        step = (i - window + 1) if recent else (i + 1)
        requests = (1000 if recent else 500) * step
        cache_fraction = 0.6 if recent else 0.4
        group = {
            "dimensions": {"date": d.strftime("%Y-%m-%d")},
            "sum": {"requests": requests, "bytes": requests * 2400,
                    "cachedRequests": int(requests * cache_fraction),
                    "cachedBytes": int(requests * 2400 * 0.77),
                    "threats": 2 if recent else 0},
        }
        if with_status:
            group["sum"]["responseStatusMap"] = (
                [{"edgeResponseStatus": 200, "requests": requests - 30},
                 {"edgeResponseStatus": 404, "requests": 10},
                 {"edgeResponseStatus": 503, "requests": 20}]
                if recent else
                [{"edgeResponseStatus": 200, "requests": requests}])
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
                                  zone_object(ZONE2, "second.dev"),
                                  zone_object(ZONE_NEW, "brandnew.dev")]))
        if path == f"/zones/{ZONE}":
            return self.reply(ok(zone_object()))
        if path == f"/zones/{ZONE2}":
            return self.reply(ok(zone_object(ZONE2, "second.dev")))
        if path == f"/zones/{ZONE_NEW}":
            return self.reply(ok(zone_object(ZONE_NEW, "brandnew.dev")))
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

                # The detail query asks for an hour dimension and filters to one
                # script. Exact, hand-checkable numbers: 24 hours of 100 good
                # requests, and two hours that also threw five exceptions.
                if "datetimeHour" in query:
                    script = variables.get("script", "")
                    if script != "api-router":
                        return self.reply({"data": {"viewer": {"accounts": [
                            {"workersInvocationsAdaptive": []}]}}, "errors": None})
                    now = datetime.datetime.now(datetime.timezone.utc).replace(
                        minute=0, second=0, microsecond=0)
                    rows = []
                    for i in range(24):
                        hour = (now - datetime.timedelta(hours=23 - i)).strftime(
                            "%Y-%m-%dT%H:00:00Z")
                        rows.append({
                            "dimensions": {"datetimeHour": hour, "status": "success"},
                            "sum": {"requests": 100, "errors": 0, "subrequests": 2},
                            "quantiles": {"cpuTimeP50": 8644, "cpuTimeP99": 20000},
                        })
                        if i in (5, 6):
                            rows.append({
                                "dimensions": {"datetimeHour": hour,
                                               "status": "scriptThrewException"},
                                "sum": {"requests": 5, "errors": 5, "subrequests": 0},
                                "quantiles": {"cpuTimeP50": 457, "cpuTimeP99": 900},
                            })
                    return self.reply({"data": {"viewer": {"accounts": [
                        {"workersInvocationsAdaptive": rows}]}}, "errors": None})
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
            # Which dataset answers is the script's decision, not ours: it
            # picks one per range and the mock has to honour whichever it
            # named, including the bucket count it asked for.
            daily_query = "httpRequests1dGroups" in query
            key = "httpRequests1dGroups" if daily_query else "httpRequests1hGroups"
            limit = int((re.search(r"limit:\s*(\d+)", query) or [0, 48])[1])
            groups = daily(limit, wants_status) if daily_query else hourly(wants_status)
            if variables.get("zone") == ZONE_NEW:
                # Only the recent half exists, so there is no baseline.
                groups = groups[len(groups) // 2:]
            return self.reply({"data": {"viewer": {"zones": [
                {key: groups}]}}, "errors": None})
        if path.endswith("/purge_cache"):
            if self.scoped_out():
                return self.reply(denied(), 403)
            STATE["purges"] += 1
            return self.reply(ok({"id": ZONE}))
        return self.reply(denied("no route " + path, 7003), 404)


if __name__ == "__main__":
    port = int(sys.argv[1]) if len(sys.argv) > 1 else 8787
    HTTPServer(("127.0.0.1", port), Handler).serve_forever()
