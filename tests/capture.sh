#!/usr/bin/env bash
# Regenerates the screenshots the README points at, against the mock API.
#
# The images had gone five commits stale, which on a repo that is the landing
# page for the plugin means the first thing a reader sees is a version that no
# longer exists. Doing it by hand takes an hour and is easy to put off; this
# takes a minute, so there is no excuse for the README showing last month's
# panel.
#
# It runs against tests/mock-api.py, never a real account: the panel in these
# images belongs to example.com and Acme Inc, and no screenshot of this repo
# should ever contain somebody's zones.
#
# Wayland has no way to ask a window where it is, so each shot is taken twice —
# once with the panel closed and once open — and the card's bounds are whatever
# changed between them. That only works against a still backdrop, so the
# capture happens on an empty workspace.
set -euo pipefail

HERE=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
ROOT=$(dirname "$HERE")
PORT="${CLOUDFLARECHY_CAPTURE_PORT:-18799}"
WORKSPACE="${CLOUDFLARECHY_CAPTURE_WORKSPACE:-9}"
CONFIG_DIR="${XDG_CONFIG_HOME:-$HOME/.config}/cloudflarechy"
TOKEN="$CONFIG_DIR/token"
STASH="$CONFIG_DIR/token.capture-stash"
SHOT_DIR=$(mktemp -d)
MOCK_PID=""
ORIGINAL_WORKSPACE=""
API_PATCHED=0

die() { printf 'capture: %s\n' "$*" >&2; exit 1; }
note() { printf '  %s\n' "$*"; }

for tool in grim magick wtype hyprctl jq curl python3 omarchy omarchy-shell; do
  command -v "$tool" >/dev/null || die "needs $tool"
done

# A stash left behind means a previous run was killed between moving the real
# token aside and putting it back. Say so rather than overwrite it.
[[ -e $STASH ]] && die "a stashed token is sitting at $STASH — a previous run
  did not finish. Move it back to $TOKEN before running again."

cleanup() {
  local status=$?
  set +e
  [[ -n $MOCK_PID ]] && kill "$MOCK_PID" 2>/dev/null
  # Restore the request path before anything else: a plugin left pointing at a
  # dead port is worse than no screenshots.
  if [[ $API_PATCHED == 1 ]]; then
    sed -i "s|:-http://127.0.0.1:$PORT}|:-https://api.cloudflare.com/client/v4}|" \
      "$ROOT/bin/cloudflarechy"
  fi
  rm -f "$TOKEN"
  [[ -e $STASH ]] && mv "$STASH" "$TOKEN"
  rm -rf "${XDG_CACHE_HOME:-$HOME/.cache}/cloudflarechy" "$SHOT_DIR"
  [[ -n $ORIGINAL_WORKSPACE ]] &&
    hyprctl dispatch "hl.dsp.focus({ workspace = $ORIGINAL_WORKSPACE })" >/dev/null 2>&1
  # Back onto the real API, with no stale QML cached.
  rm -rf "${XDG_CACHE_HOME:-$HOME/.cache}/quickshell/qmlcache"
  omarchy restart shell >/dev/null 2>&1
  [[ $status == 0 ]] || printf 'capture: failed, everything put back\n' >&2
  return $status
}
trap cleanup EXIT

# --- stand up a fake Cloudflare -------------------------------------------
echo "starting the mock"
python3 "$HERE/mock-api.py" "$PORT" >/dev/null 2>&1 &
MOCK_PID=$!
for _ in $(seq 20); do
  curl -sf -o /dev/null "http://127.0.0.1:$PORT/zones" -H "Authorization: Bearer x" && break
  sleep 0.2
done
curl -sf -o /dev/null "http://127.0.0.1:$PORT/zones" -H "Authorization: Bearer x" ||
  die "the mock never answered on $PORT"

[[ -e $TOKEN ]] && mv "$TOKEN" "$STASH"
mkdir -p "$CONFIG_DIR"
(umask 077; printf 'mock-capture-token\n' > "$TOKEN")

sed -i "s|:-https://api.cloudflare.com/client/v4}|:-http://127.0.0.1:$PORT}|" \
  "$ROOT/bin/cloudflarechy"
API_PATCHED=1
grep -q "127.0.0.1:$PORT" "$ROOT/bin/cloudflarechy" || die "could not redirect the API base"

rm -rf "${XDG_CACHE_HOME:-$HOME/.cache}/cloudflarechy"
rm -rf "${XDG_CACHE_HOME:-$HOME/.cache}/quickshell/qmlcache"
echo "restarting the shell onto the mock"
# Its exit status is not the answer. `omarchy restart shell` gives a new
# shell about two seconds to answer and calls it failed after that — and one
# starting with an empty QML cache on a machine short of memory took nine,
# which under errexit ended the run with nothing said. What matters is that
# the widget answers, so that is what is waited for, for up to a minute.
omarchy restart shell >/dev/null 2>&1 || true
for _ in $(seq 60); do
  omarchy-shell cloudflarechy status >/dev/null 2>&1 && break
  sleep 1
done
omarchy-shell cloudflarechy status >/dev/null 2>&1 ||
  die "the shell did not come back within a minute of restarting"
# Answering is not the same as having loaded; the widget's first reads are
# still in flight.
sleep 4

ORIGINAL_WORKSPACE=$(hyprctl activeworkspace -j | jq -r '.id')
hyprctl dispatch "hl.dsp.focus({ workspace = $WORKSPACE })" >/dev/null
sleep 1
[[ $(hyprctl activeworkspace -j | jq -r '.windows') == 0 ]] ||
  die "workspace $WORKSPACE has windows on it; set CLOUDFLARECHY_CAPTURE_WORKSPACE
  to an empty one, or the backdrop will move between the two frames"

# --- take one picture ------------------------------------------------------
# $1 output file, the rest a command that leaves the wanted view on screen.
capture() {
  local out="$1"; shift
  omarchy-shell cloudflarechy close >/dev/null 2>&1
  sleep 2
  grim "$SHOT_DIR/closed.png"

  "$@"
  sleep 4
  grim "$SHOT_DIR/open.png"

  # Whatever changed between the two frames is the card. The bar is excluded:
  # its icon gains an underline when the panel opens, which would drag the top
  # of the crop up to the top of the screen.
  local bar=40 bbox w h x y
  bbox=$(magick "$SHOT_DIR/open.png" "$SHOT_DIR/closed.png" \
           -compose difference -composite -colorspace Gray \
           -threshold 8% -chop "0x${bar}" -format '%@' info:)
  [[ $bbox =~ ^([0-9]+)x([0-9]+)\+([0-9]+)\+([0-9]+)$ ]] ||
    die "could not find the panel (got '$bbox')"
  w=${BASH_REMATCH[1]}; h=${BASH_REMATCH[2]}
  x=${BASH_REMATCH[3]}; y=$((BASH_REMATCH[4] + bar))

  # A card is a tall, narrow thing on one side of the screen. Anything else
  # means the backdrop moved and the crop would be nonsense.
  local screen_w
  screen_w=$(magick "$SHOT_DIR/open.png" -format '%w' info:)
  (( w > 200 && w < screen_w / 2 && h > 200 )) ||
    die "that does not look like the panel: ${w}x${h} — did something move behind it?"

  # Kept aside until every picture is taken. The shell watches the plugin's
  # directory and reloads the plugin whenever a file in it changes, so a
  # picture written there mid-run reloads the widget under the next one —
  # every run then failed on its second picture.
  mkdir -p "$SHOT_DIR/out"
  magick "$SHOT_DIR/open.png" -crop "${w}x${h}+${x}+${y}" +repage "$SHOT_DIR/out/$out"
  note "$out  ${w}x${h}"
}

open_panel() { omarchy-shell cloudflarechy open >/dev/null 2>&1; }
open_credentials() { open_panel; sleep 3; wtype -k c; }
open_account() { open_panel; sleep 3; wtype -k a; }
open_worker() { omarchy-shell cloudflarechy worker api-router >/dev/null 2>&1; }
open_tunnel() { omarchy-shell cloudflarechy tunnel homelab >/dev/null 2>&1; }

echo "capturing"
capture preview.png open_panel
capture account.png open_account
capture connect.png open_credentials
capture worker.png  open_worker
capture tunnel.png  open_tunnel
cp "$SHOT_DIR"/out/*.png "$ROOT"/

echo
echo "done — check them before committing; the panel is example.com, never yours"
