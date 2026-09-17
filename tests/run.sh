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
assert_eq "zones are listed" "2" "$(field '.zones | length' <<<"$out")"
assert_eq "  ... with the account attached" "$ACCOUNT" "$(field '.zones[0].account_id' <<<"$out")"
assert_eq "  ... and the plan" "Free Website" "$(field '.zones[0].plan' <<<"$out")"

out=$(run --fresh overview "$ZONE")
assert_eq "analytics fills a 24 hour window" "24" "$(field '.analytics.series | length' <<<"$out")"
assert_eq "  ... totals requests" "19812" "$(field '.analytics.requests' <<<"$out")"
assert_eq "  ... and reports no error" "" "$(field '.analytics_error' <<<"$out")"
assert_eq "a plan without uniques still returns traffic" "false" "$(field '.analytics.uniques_known' <<<"$out")"
assert_eq "  ... rather than claiming zero visitors" "0" "$(field '.analytics.uniques' <<<"$out")"
assert_eq "the zone's security level is read" "high" "$(field '.security_level' <<<"$out")"

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

out=$(run --fresh tunnels "$ACCOUNT")
assert_eq "tunnels are listed" "2" "$(field '.tunnels | length' <<<"$out")"
assert_eq "  ... with connection counts" "2" "$(field '.tunnels[0].connections' <<<"$out")"
assert_eq "  ... and a status" "down" "$(field '.tunnels[1].status' <<<"$out")"

out=$(run --fresh workers "$ACCOUNT")
assert_eq "workers are busiest first" "api-router" "$(field '.workers[0].name' <<<"$out")"
assert_eq "  ... with requests summed across statuses" "3040" "$(field '.workers[0].requests' <<<"$out")"
assert_eq "  ... and the p50 of the busiest status, not an average" "8644" \
  "$(field '.workers[0].cpu_p50_us' <<<"$out")"
assert_eq "  ... and subrequests" "120" "$(field '.workers[0].subrequests' <<<"$out")"
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

out=$(run purge "$ZONE")
assert_eq "the cache can be purged" "everything" "$(field .purged <<<"$out")"

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
assert_eq "  ... until --fresh" "2" "$(run --fresh zones | field '.zones | length')"

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
