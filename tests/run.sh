#!/usr/bin/env bash
# Contract tests for bin/cloudflarechy against tests/mock-api.py.
#
# These pin the shape of what the script promises the panel — one JSON object
# per subcommand, named fields, errors as data — and the behaviour that is easy
# to break by accident: the write guard, the security-level save/restore, the
# analytics retry, and the read cache.
#
# They run against a fixture, so they cannot tell you Cloudflare still answers
# this way. They can tell you the plugin still does.
#
# Everything happens under a temporary HOME. The suite never reads or writes
# the real ~/.config/cloudflarechy, the real cache, or the real wrangler login.
set -uo pipefail

HERE=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
SCRIPT="$HERE/../bin/cloudflarechy"
PORT="${CLOUDFLARECHY_TEST_PORT:-18787}"
ZONE=a1b2c3d4e5f60718293a4b5c6d7e8f90
ZONE2=bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb
ACCOUNT=0f9e8d7c6b5a40312f1e0d9c8b7a6554
ACCOUNT_NO_METRICS=11111111111111111111111111111111
ZONE_NEW=cccccccccccccccccccccccccccccccc
ZONE_QUIET=dddddddddddddddddddddddddddddddd

passed=0
failed=0

pass() { printf '  \033[32mok\033[0m   %s\n' "$1"; passed=$((passed + 1)); }
fail() { printf '  \033[31mFAIL\033[0m %s\n       %s\n' "$1" "$2"; failed=$((failed + 1)); }

assert_eq() { # label expected actual
  if [[ "$2" == "$3" ]]; then pass "$1"; else fail "$1" "expected '$2', got '$3'"; fi
}

assert_contains() { # label needle haystack
  if [[ "$3" == *"$2"* ]]; then pass "$1"; else fail "$1" "expected to contain '$2', got '$3'"; fi
}

SANDBOX=$(mktemp -d)
MOCK_PID=""
cleanup() {
  [[ -n $MOCK_PID ]] && kill "$MOCK_PID" 2>/dev/null
  rm -rf "$SANDBOX"
}
trap cleanup EXIT

python3 "$HERE/mock-api.py" "$PORT" >/dev/null 2>&1 &
MOCK_PID=$!
for _ in $(seq 1 50); do
  curl -sS --max-time 1 "http://127.0.0.1:$PORT/zones" >/dev/null 2>&1 && break
  sleep 0.1
done

# Every invocation is sandboxed: its own HOME, config, cache and state.
export HOME="$SANDBOX/home"
export XDG_CONFIG_HOME="$SANDBOX/home/.config"
export XDG_CACHE_HOME="$SANDBOX/home/.cache"
export XDG_STATE_HOME="$SANDBOX/home/.local/state"
mkdir -p "$XDG_CONFIG_HOME" "$XDG_CACHE_HOME" "$XDG_STATE_HOME"
export CLOUDFLARECHY_API_BASE="http://127.0.0.1:$PORT"

# No inherited credential may leak into a run.
unset CLOUDFLARE_API_TOKEN CF_API_TOKEN

run() { "$SCRIPT" "$@" 2>/dev/null; }
field() { jq -r "$1" 2>/dev/null; }

write_wrangler_config() { # expires_at
  mkdir -p "$XDG_CONFIG_HOME/.wrangler/config"
  cat > "$XDG_CONFIG_HOME/.wrangler/config/default.toml" <<TOML
oauth_token = "cfoa.test-token"
expiration_time = "$1"
refresh_token = "test-refresh"
scopes = [ "zone:read" ]
TOML
}

echo
echo "credentials"

out=$(run status)
assert_eq "no credential at all is reported, not guessed" "false" "$(field .token <<<"$out")"
assert_eq "  ... and named" "no API token" "$(field .message <<<"$out")"
assert_contains "  ... with a way out" "wrangler login" "$(field .hint <<<"$out")"

write_wrangler_config "2020-01-01T00:00:00.000Z"
out=$(run status)
assert_eq "an expired wrangler session is not used" "false" "$(field .token <<<"$out")"
assert_eq "  ... and says which" "wrangler session expired" "$(field .message <<<"$out")"

write_wrangler_config "2099-01-01T00:00:00.000Z"
out=$(run status)
assert_eq "a live wrangler session is used" "true" "$(field .token <<<"$out")"
assert_eq "  ... as an oauth credential" "oauth" "$(field .token_kind <<<"$out")"
assert_eq "  ... marked read-only" "true" "$(field .read_only <<<"$out")"
assert_eq "  ... and probed without /user/tokens/verify" "active" "$(field .message <<<"$out")"

echo
echo "the write guard"

for args in "devmode $ZONE on" "attack $ZONE on" "purge $ZONE"; do
  # shellcheck disable=SC2086
  out=$(run $args)
  assert_contains "wrangler cannot ${args%% *}" "read-only" "$(field .error <<<"$out")"
done

echo
echo "reads"

export CLOUDFLARE_API_TOKEN=test-api-token
out=$(run status)
assert_eq "an API token outranks wrangler" "api" "$(field .token_kind <<<"$out")"
assert_eq "  ... and is not read-only" "false" "$(field .read_only <<<"$out")"

out=$(run --fresh zones)
assert_eq "zones are listed" "4" "$(field '.zones | length' <<<"$out")"
assert_eq "  ... with the account attached" "$ACCOUNT" "$(field '.zones[0].account_id' <<<"$out")"
assert_eq "  ... and the plan" "Free Website" "$(field '.zones[0].plan' <<<"$out")"

out=$(run --fresh overview "$ZONE")
assert_eq "analytics fills a 24 hour window" "24" "$(field '.analytics.series | length' <<<"$out")"
assert_eq "  ... totals requests" "19812" "$(field '.analytics.requests' <<<"$out")"
assert_eq "  ... and reports no error" "" "$(field '.analytics_error' <<<"$out")"
assert_eq "a plan without uniques still returns traffic" "false" "$(field '.analytics.uniques_known' <<<"$out")"
assert_eq "  ... rather than claiming zero visitors" "0" "$(field '.analytics.uniques' <<<"$out")"
assert_eq "the zone's security level is read" "high" "$(field '.security_level' <<<"$out")"

# Which Workers run on this domain. Zone-scoped, unlike the script list, and
# the only Workers view that belongs under the zone picker.
assert_eq "the zone's Workers routes are listed" "3" \
  "$(field '.routes | length' <<<"$out")"
assert_eq "  ... sorted by pattern, not by the order they arrived" "assets.example.com/*" \
  "$(field '.routes[0].pattern' <<<"$out")"
assert_eq "  ... carrying the script that answers it" "image-resize" \
  "$(field '.routes[0].script' <<<"$out")"
assert_eq "  ... and a route with no Worker keeps an empty one" "" \
  "$(field '.routes[] | select(.id == "r3") | .script' <<<"$out")"
assert_eq "  ... with no error" "" "$(field '.routes_error' <<<"$out")"

# 10 fives and 5 fours an hour for 24 hours, against 19812 requests.
assert_eq "server errors are counted" "240" "$(field '.analytics.server_errors' <<<"$out")"
assert_eq "  ... separately from client errors" "120" "$(field '.analytics.client_errors' <<<"$out")"
assert_eq "  ... and kept per code, summed over the window" "240" \
  "$(field '.analytics.statuses["503"]' <<<"$out")"
assert_eq "  ... including the successful ones" "19452" \
  "$(field '.analytics.statuses["200"]' <<<"$out")"
assert_eq "  ... as a share of traffic" "1.21" \
  "$(field '(.analytics.error_ratio * 10000 | round) / 100' <<<"$out")"
assert_eq "status codes are marked as known" "true" "$(field '.analytics.statuses_known' <<<"$out")"

# The window is fetched 48 hours wide and split on its midpoint, so the graph
# must stay 24 buckets and the status totals must cover only the recent half —
# a split that leaked the baseline would inflate both.
assert_eq "the baseline is compared, not drawn" "24" \
  "$(field '.analytics.series | length' <<<"$out")"
assert_eq "  ... and not counted into the totals" "19812" \
  "$(field '.analytics.requests' <<<"$out")"

# 19812 requests against 13208 in the 24 hours before them: exactly +50%.
assert_eq "requests carry a period-over-period delta" "0.5" \
  "$(field '.analytics.requests_delta' <<<"$out")"
assert_eq "  ... and so do bytes" "0.5" \
  "$(field '.analytics.bytes_delta' <<<"$out")"
assert_eq "  ... with the baseline reported alongside" "13208" \
  "$(field '.analytics.previous.requests' <<<"$out")"
assert_eq "  ... and the period named" "previous 24 hours" \
  "$(field '.analytics.comparison' <<<"$out")"

# 0.82 against 0.41 is a doubling of the ratio, so the delta is relative and
# not a difference in points — which is what Cloudflare's own cards report. A
# delta computed in points would read as 41, not 1.0.
assert_eq "the cache ratio moves relatively, not in points" "1.0044" \
  "$(field '(.analytics.cache_ratio_delta * 10000 | round) / 10000' <<<"$out")"

# The second zone's plan serves neither optional field, which walks the query
# down to its last rung.
out2=$(run --fresh overview "$ZONE2")
assert_eq "a plan with no status codes still returns traffic" "19812" \
  "$(field '.analytics.requests' <<<"$out2")"
assert_eq "  ... and says the codes are unknown" "false" \
  "$(field '.analytics.statuses_known' <<<"$out2")"
assert_eq "  ... rather than reporting zero 5xx as fact" "0" \
  "$(field '.analytics.server_errors' <<<"$out2")"
assert_eq "  ... with no error surfaced" "" "$(field '.analytics_error' <<<"$out2")"

# A zone that has no routes is not the same as a token that cannot look.
assert_eq "a zone with no routes reports none" "0" \
  "$(field '.routes | length' <<<"$out2")"
assert_eq "  ... rather than an error" "" "$(field '.routes_error' <<<"$out2")"

# Routes sit behind their own scope. A token without it loses the section and
# keeps the rest of the zone, the same way a missing Zone Settings scope costs
# the Under Attack switch rather than the panel.
out_noroutes=$(CLOUDFLARE_API_TOKEN=read-only-token run --fresh overview "$ZONE")
assert_eq "a token that cannot read routes still reads the zone" "example.com" \
  "$(field '.zone.name' <<<"$out_noroutes")"
assert_eq "  ... and its traffic" "19812" \
  "$(field '.analytics.requests' <<<"$out_noroutes")"
assert_eq "  ... while the routes come back empty" "0" \
  "$(field '.routes | length' <<<"$out_noroutes")"
assert_contains "  ... with the reason kept" "Unauthorized" \
  "$(field '.routes_error' <<<"$out_noroutes")"

# A zone younger than 48 hours has a window but no baseline. A percent change
# against nothing is not zero, so nothing is what gets reported.
out3=$(run --fresh overview "$ZONE_NEW")
assert_eq "a zone with no baseline still reports traffic" "19812" \
  "$(field '.analytics.requests' <<<"$out3")"
assert_eq "  ... and suppresses the delta rather than calling it zero" "null" \
  "$(field '.analytics.requests_delta' <<<"$out3")"
assert_eq "  ... for every stat that carries one" "null" \
  "$(field '.analytics.cache_ratio_delta' <<<"$out3")"
assert_eq "  ... naming no comparison period" "" \
  "$(field '.analytics.comparison' <<<"$out3")"
assert_eq "  ... and offering no baseline to read" "null" \
  "$(field '.analytics.previous' <<<"$out3")"

# Cloudflare omits a bucket entirely when nothing happened in it, so the window
# has to be rebuilt from the clock rather than from the rows. A graph fed the
# rows alone draws twenty bars for a day and widens each one to cover the gap,
# which reads as steady traffic through hours that had none.
out_quiet=$(run --fresh overview "$ZONE_QUIET")
assert_eq "an hour with no traffic still gets a bucket" "24" \
  "$(field '.analytics.series | length' <<<"$out_quiet")"
assert_eq "  ... drawn as zero rather than left out" "4" \
  "$(field '[.analytics.series[] | select(.requests == 0)] | length' <<<"$out_quiet")"
assert_eq "  ... in the place on the clock where it happened" "0" \
  "$(field '.analytics.series[6].requests' <<<"$out_quiet")"
assert_eq "  ... and the hours around it keep their own figures" "437" \
  "$(field '.analytics.series[1].requests' <<<"$out_quiet")"

# 7 and 30 days come from a different dataset than 24 hours, keyed on a `date`
# of GraphQL type Date rather than a `datetime` of type Time. A query built for
# one and aimed at the other fails outright, so each range is walked.
out7=$(run --fresh overview "$ZONE" 7d)
assert_eq "seven days is a week of buckets" "7" \
  "$(field '.analytics.series | length' <<<"$out7")"
assert_eq "  ... dated, not stamped by the hour" "true" \
  "$(field '.analytics.series[0].t | test("^[0-9]{4}-[0-9]{2}-[0-9]{2}$")' <<<"$out7")"
assert_eq "  ... totalling the daily rows" "28000" \
  "$(field '.analytics.requests' <<<"$out7")"
assert_eq "  ... against the week before it" "1" \
  "$(field '.analytics.requests_delta' <<<"$out7")"
assert_eq "  ... and saying so" "previous 7 days" \
  "$(field '.analytics.comparison' <<<"$out7")"
# 0.6 against 0.4 is +50%, a different number from the +100% on requests and
# bytes, so a delta reading the wrong field cannot pass here either.
assert_eq "  ... with the cache ratio moved separately" "0.5" \
  "$(field '(.analytics.cache_ratio_delta * 100 | round) / 100' <<<"$out7")"
assert_eq "  ... and no error" "" "$(field '.analytics_error' <<<"$out7")"

out30=$(run --fresh overview "$ZONE" 30d)
assert_eq "thirty days is a month of buckets" "30" \
  "$(field '.analytics.series | length' <<<"$out30")"
assert_eq "  ... totalling the daily rows" "465000" \
  "$(field '.analytics.requests' <<<"$out30")"
assert_eq "  ... against the month before it" "1" \
  "$(field '.analytics.requests_delta' <<<"$out30")"
assert_eq "  ... and saying so" "previous 30 days" \
  "$(field '.analytics.comparison' <<<"$out30")"

assert_eq "the range is reported back" "24h" "$(field '.range' <<<"$out")"
assert_eq "  ... alongside the ones on offer" "24h 7d 30d" \
  "$(field '.ranges | join(" ")' <<<"$out")"
out_bad=$(run --fresh overview "$ZONE" 90d)
assert_contains "an unknown range is refused" "unknown range" \
  "$(field '.error' <<<"$out_bad")"
assert_contains "  ... naming the ones that work" "24h 7d 30d" \
  "$(field '.hint' <<<"$out_bad")"

# Each range caches under its own key. Sharing one would answer a week from a
# day's entry for as long as it stayed warm.
run overview "$ZONE" 7d >/dev/null
assert_eq "each range caches separately" "1" \
  "$(ls "$XDG_CACHE_HOME/cloudflarechy/overview.$ZONE.7d.json" 2>/dev/null | wc -l)"
printf '{"range":"7d","analytics":{"requests":777}}' \
  > "$XDG_CACHE_HOME/cloudflarechy/overview.$ZONE.7d.json"
assert_eq "  ... and is served from its own" "777" \
  "$(run overview "$ZONE" 7d | field '.analytics.requests')"
assert_eq "  ... leaving the other range alone" "19812" \
  "$(run --fresh overview "$ZONE" 24h | field '.analytics.requests')"

out=$(run --fresh tunnels "$ACCOUNT")
assert_eq "tunnels are listed" "2" "$(field '.tunnels | length' <<<"$out")"
assert_eq "  ... with connection counts" "2" "$(field '.tunnels[0].connections' <<<"$out")"
assert_eq "  ... and a status" "down" "$(field '.tunnels[1].status' <<<"$out")"

out=$(run --fresh workers "$ACCOUNT")
assert_eq "workers are busiest first" "api-router" "$(field '.workers[0].name' <<<"$out")"
assert_eq "  ... with requests summed across statuses" "2410" "$(field '.workers[0].requests' <<<"$out")"
assert_eq "  ... and the p50 of the busiest status, not an average" "8644" \
  "$(field '.workers[0].cpu_p50_us' <<<"$out")"
assert_eq "  ... and subrequests" "48" "$(field '.workers[0].subrequests' <<<"$out")"
assert_eq "a failing worker reports its errors" "12" \
  "$(field '.workers | map(select(.name == "image-resize"))[0].errors' <<<"$out")"
# A script nobody invoked has no analytics row at all, which is not the same as
# one that ran zero times — it must not be rendered as "0 req".
assert_eq "an uninvoked worker has no request count" "null" \
  "$(field '.workers | map(select(.name == "cron-cleanup"))[0].requests' <<<"$out")"
assert_eq "  ... and sorts last" "cron-cleanup" "$(field '.workers[-1].name' <<<"$out")"

# Workers analytics need a scope the script list does not.
out=$(run --fresh workers "$ACCOUNT_NO_METRICS")
assert_eq "without analytics the scripts are still listed" "3" "$(field '.workers | length' <<<"$out")"
assert_contains "  ... and the reason is reported" "not readable" "$(field '.metrics_error' <<<"$out")"
assert_eq "  ... with no invented traffic" "null" "$(field '.workers[0].requests' <<<"$out")"

echo
echo "one worker in detail"

out=$(run --fresh worker "$ACCOUNT" api-router)
assert_eq "requests total across statuses" "2410" "$(field '.worker.requests' <<<"$out")"
assert_eq "errors total" "10" "$(field '.worker.errors' <<<"$out")"
assert_eq "subrequests total" "48" "$(field '.worker.subrequests' <<<"$out")"
assert_eq "the headline p50 is the busiest status's" "8644" "$(field '.worker.cpu_p50_us' <<<"$out")"
assert_eq "  ... and so is p99" "20000" "$(field '.worker.cpu_p99_us' <<<"$out")"
assert_eq "success ratio is not rounded to 1" "0.9959" \
  "$(field '(.worker.success_ratio * 10000 | round) / 10000' <<<"$out")"
assert_eq "statuses come busiest first" "success" "$(field '.statuses[0].status' <<<"$out")"
assert_eq "  ... and the failing one keeps its own quantile" "457" \
  "$(field '.statuses[1].cpu_p50_us' <<<"$out")"
assert_eq "  ... and its errors" "10" "$(field '.statuses[1].errors' <<<"$out")"
assert_eq "an hour per bucket" "24" "$(field '.series | length' <<<"$out")"
assert_eq "  ... carrying that hour's errors" "5" "$(field '.series[5].errors' <<<"$out")"
assert_eq "  ... and its requests" "105" "$(field '.series[5].requests' <<<"$out")"

# The panel lists a Worker and then opens it. Checked against each other
# rather than each against its own constant, because the way these drifted was
# that both were individually right and together nonsense: the list said 3.0K
# requests and no errors, the detail said 2.4K and ten.
for script in api-router image-resize; do
  listed=$(run --fresh workers "$ACCOUNT" \
           | jq -c --arg s "$script" '.workers | map(select(.name == $s))[0]')
  detail=$(run --fresh worker "$ACCOUNT" "$script")
  assert_eq "$script reads the same listed as opened" \
    "$(field '.requests' <<<"$listed")" "$(field '.worker.requests' <<<"$detail")"
  assert_eq "  ... down to its errors" \
    "$(field '.errors' <<<"$listed")" "$(field '.worker.errors' <<<"$detail")"
done

# Same rule for a Worker: one that answers a cron a few times a day is idle for
# most of it, and the idle hours are the shape of the thing.
out=$(run --fresh worker "$ACCOUNT" image-resize)
assert_eq "a Worker idle most of the day still gets the whole day" "24" \
  "$(field '.series | length' <<<"$out")"
assert_eq "  ... with the quiet hours at zero" "22" \
  "$(field '[.series[] | select(.requests == 0)] | length' <<<"$out")"
assert_eq "  ... and the busy ones adding up to what it did" "12" \
  "$(field '[.series[].requests] | add' <<<"$out")"

out=$(run --fresh worker "$ACCOUNT" nonexistent-script)
assert_eq "a script with no invocations is empty, not an error" "0" \
  "$(field '.statuses | length' <<<"$out")"
assert_eq "  ... with no error surfaced" "" "$(field '.error' <<<"$out")"

out=$(run --fresh worker "$ACCOUNT_NO_METRICS" api-router)
assert_contains "without analytics the reason is reported" "not readable" "$(field '.error' <<<"$out")"

out=$(run worker "$ACCOUNT")
assert_contains "a missing script name is refused" "needs a script" "$(field '.error' <<<"$out")"

echo
echo "writes"

out=$(run devmode "$ZONE" on)
assert_eq "development mode goes on" "on" "$(field .value <<<"$out")"
assert_eq "  ... with the time Cloudflare gave it" "10800" "$(field .time_remaining <<<"$out")"
assert_eq "the zone reports it" "10800" "$(run --fresh overview "$ZONE" | field '.zone.development_mode')"
run devmode "$ZONE" off >/dev/null

run attack "$ZONE" on >/dev/null
assert_eq "under attack records the level it replaced" "high" \
  "$(cat "$XDG_STATE_HOME/cloudflarechy/security_level.$ZONE" 2>/dev/null)"
out=$(run attack "$ZONE" off)
assert_eq "  ... and puts it back, rather than guessing" "high" "$(field .value <<<"$out")"

# The happy path always has a record to restore. This is the other one: the
# zone was already under attack before this plugin ever saw it, or the state
# was cleared. "Off" still has to mean something defensible.
run attack "$ZONE" on >/dev/null
rm -f "$XDG_STATE_HOME/cloudflarechy/security_level.$ZONE"
out=$(run attack "$ZONE" off)
assert_eq "with nothing recorded, off falls back to medium" "medium" "$(field .value <<<"$out")"

# A token that cannot read the security level cannot say Under Attack is off.
# The zone is put under attack first so this has teeth: with the zone really
# under attack, "false" is not an unconfirmed answer but a wrong one — and it
# is the answer the script used to give, because it derived the flag from an
# empty string.
run attack "$ZONE" on >/dev/null
out=$(run --fresh overview "$ZONE")
assert_eq "under attack is reported when the level is readable" "true" \
  "$(field '.under_attack' <<<"$out")"
out=$(CLOUDFLARE_API_TOKEN=read-only-token run --fresh overview "$ZONE")
assert_eq "  ... and unknown, not off, when it is not" "null" \
  "$(field '.under_attack' <<<"$out")"
assert_contains "  ... with the refusal carried alongside" "Unauthorized" \
  "$(field '.security_level_error' <<<"$out")"
run attack "$ZONE" off >/dev/null

out=$(run purge "$ZONE")
assert_eq "the cache can be purged" "everything" "$(field .purged <<<"$out")"

# A write changes what every window of this zone would report, so it has to
# clear all of them. This is pinned by behaviour rather than by key name on
# purpose: when the range went into the cache key, the three write commands
# went on dropping the key that existed before it, and the panel hid the
# breakage by reloading with --fresh anyway. A name assertion would have
# drifted with them; emptying the directory and counting what survives a
# write does not.
for r in 24h 7d 30d; do run overview "$ZONE" "$r" >/dev/null; done
assert_eq "every window of a zone is cached" "3" \
  "$(ls "$XDG_CACHE_HOME"/cloudflarechy/overview."$ZONE".*.json 2>/dev/null | wc -l)"
run devmode "$ZONE" on >/dev/null
assert_eq "  ... and development mode clears all of them" "0" \
  "$(ls "$XDG_CACHE_HOME"/cloudflarechy/overview."$ZONE".*.json 2>/dev/null | wc -l)"

for r in 24h 7d 30d; do run overview "$ZONE" "$r" >/dev/null; done
run attack "$ZONE" on >/dev/null
assert_eq "  ... so does under attack" "0" \
  "$(ls "$XDG_CACHE_HOME"/cloudflarechy/overview."$ZONE".*.json 2>/dev/null | wc -l)"
run attack "$ZONE" off >/dev/null

for r in 24h 7d 30d; do run overview "$ZONE" "$r" >/dev/null; done
run purge "$ZONE" >/dev/null
assert_eq "  ... and so does a purge" "0" \
  "$(ls "$XDG_CACHE_HOME"/cloudflarechy/overview."$ZONE".*.json 2>/dev/null | wc -l)"

# The neighbouring zone's windows are not collateral: the prefix has to end at
# the zone id, or one zone's switch would blank another's.
run overview "$ZONE2" 24h >/dev/null
for r in 24h 7d 30d; do run overview "$ZONE" "$r" >/dev/null; done
run devmode "$ZONE" off >/dev/null
assert_eq "  ... without touching another zone" "1" \
  "$(ls "$XDG_CACHE_HOME"/cloudflarechy/overview."$ZONE2".*.json 2>/dev/null | wc -l)"

out=$(run devmode "$ZONE" sideways)
assert_contains "a bad argument is refused" "on or off" "$(field .error <<<"$out")"
out=$(run purge)
assert_contains "a missing zone is refused" "needs a zone id" "$(field .error <<<"$out")"

echo
echo "the read cache"

run --fresh zones >/dev/null
assert_eq "a read is cached" "1" "$(ls "$XDG_CACHE_HOME/cloudflarechy/zones.json" 2>/dev/null | wc -l)"
printf '{"zones":[{"id":"cached"}]}' > "$XDG_CACHE_HOME/cloudflarechy/zones.json"
assert_eq "  ... and served from cache" "cached" "$(run zones | field '.zones[0].id')"
assert_eq "  ... until --fresh" "4" "$(run --fresh zones | field '.zones | length')"

echo
echo "saving a token"

unset CLOUDFLARE_API_TOKEN
TOKEN_FILE="$XDG_CONFIG_HOME/cloudflarechy/token"
out=$(printf 'bad-token\n' | run save-token)
assert_contains "a token Cloudflare rejects is refused" "Invalid API Token" "$(field .error <<<"$out")"
assert_eq "  ... and not written" "missing" "$([[ -e $TOKEN_FILE ]] && echo present || echo missing)"

out=$(printf '\n' | run save-token)
assert_contains "an empty token is refused" "no token" "$(field .error <<<"$out")"

out=$(printf 'good-token\n' | run save-token)
assert_eq "a working token is saved" "true" "$(field .ok <<<"$out")"
assert_eq "  ... with the contents given" "good-token" "$(cat "$TOKEN_FILE" 2>/dev/null)"
assert_eq "  ... readable only by its owner" "600" "$(stat -c %a "$TOKEN_FILE" 2>/dev/null)"
assert_eq "  ... in a directory to match" "700" "$(stat -c %a "$(dirname "$TOKEN_FILE")" 2>/dev/null)"
assert_eq "the saved token is then used" "api" "$(run status | field .token_kind)"

out=$(run forget-token)
assert_eq "forgetting removes it" "true" "$(field .removed <<<"$out")"
assert_eq "  ... from disk" "missing" "$([[ -e $TOKEN_FILE ]] && echo present || echo missing)"
assert_eq "  ... and falls back to wrangler" "oauth" "$(run status | field .token_kind)"

echo
echo "setup"

out=$(run setup)
assert_eq "the live wrangler session is reported" "active" "$(field .wrangler_session <<<"$out")"
export CLOUDFLARE_API_TOKEN=test-api-token
assert_eq "an environment token is named, not printed" "CLOUDFLARE_API_TOKEN" "$(run setup | field .env_var)"
assert_eq "  ... and its value never appears" "null" "$(run setup | jq -r '.value // "null"')"

echo
printf '%d passed, %d failed\n' "$passed" "$failed"
[[ $failed -eq 0 ]]
