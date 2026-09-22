#!/usr/bin/env bash
# Records a demo of the plugin against the mock API.
#
# Against the mock, never a real account: the zone is example.com and the
# account is Acme Inc, so nothing anyone's Cloudflare holds ends up in a video
# on the internet. It also means the write beats — Development Mode, the purge
# prompt — can be shown without doing anything to a live site.
#
# The panel is keyboard-driven, so the demo is too: every beat is a keystroke
# or an IPC call, held long enough to read. Nothing depends on where the mouse
# is, which is just as well, because a warped cursor dismisses the panel.
set -euo pipefail

HERE=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
ROOT=$(dirname "$HERE")
PORT="${CLOUDFLARECHY_DEMO_PORT:-18799}"
WORKSPACE="${CLOUDFLARECHY_DEMO_WORKSPACE:-9}"
MONITOR="${CLOUDFLARECHY_DEMO_MONITOR:-}"
OUT="${1:-$ROOT/demo.mp4}"
CONFIG_DIR="${XDG_CONFIG_HOME:-$HOME/.config}/cloudflarechy"
TOKEN="$CONFIG_DIR/token"
STASH="$CONFIG_DIR/token.demo-stash"
WORK=$(mktemp -d)
MOCK_PID=""
REC_PID=""
ORIGINAL_WORKSPACE=""
API_PATCHED=0

die() { printf 'demo: %s\n' "$*" >&2; exit 1; }

for tool in grim magick ffmpeg wtype hyprctl jq curl python3 omarchy omarchy-shell gpu-screen-recorder; do
  command -v "$tool" >/dev/null || die "needs $tool"
done
[[ -e $STASH ]] && die "a stashed token is sitting at $STASH — a previous run did
  not finish. Move it back to $TOKEN before running again."

cleanup() {
  local status=$?
  set +e
  [[ -n $REC_PID ]] && kill -INT "$REC_PID" 2>/dev/null && sleep 2
  [[ -n $MOCK_PID ]] && kill "$MOCK_PID" 2>/dev/null
  if [[ $API_PATCHED == 1 ]]; then
    sed -i "s|:-http://127.0.0.1:$PORT}|:-https://api.cloudflare.com/client/v4}|" \
      "$ROOT/bin/cloudflarechy"
  fi
  rm -f "$TOKEN"
  [[ -e $STASH ]] && mv "$STASH" "$TOKEN"
  rm -rf "${XDG_CACHE_HOME:-$HOME/.cache}/cloudflarechy" "$WORK"
  [[ -n $ORIGINAL_WORKSPACE ]] &&
    hyprctl dispatch "hl.dsp.focus({ workspace = $ORIGINAL_WORKSPACE })" >/dev/null 2>&1
  rm -rf "${XDG_CACHE_HOME:-$HOME/.cache}/quickshell/qmlcache"
  omarchy restart shell >/dev/null 2>&1
  [[ $status == 0 ]] || printf 'demo: failed, everything put back\n' >&2
  return $status
}
trap cleanup EXIT

[[ -n $MONITOR ]] || MONITOR=$(hyprctl monitors -j | jq -r '.[0].name')

# --- a Cloudflare that is not Cloudflare ----------------------------------
echo "starting the mock"
CLOUDFLARECHY_MOCK_CALM=1 python3 "$HERE/mock-api.py" "$PORT" >/dev/null 2>&1 &
MOCK_PID=$!
for _ in $(seq 20); do
  curl -sf -o /dev/null "http://127.0.0.1:$PORT/zones" -H "Authorization: Bearer x" && break
  sleep 0.2
done
curl -sf -o /dev/null "http://127.0.0.1:$PORT/zones" -H "Authorization: Bearer x" ||
  die "the mock never answered on $PORT"

[[ -e $TOKEN ]] && mv "$TOKEN" "$STASH"
mkdir -p "$CONFIG_DIR"
(umask 077; printf 'demo-token\n' > "$TOKEN")

sed -i "s|:-https://api.cloudflare.com/client/v4}|:-http://127.0.0.1:$PORT}|" \
  "$ROOT/bin/cloudflarechy"
API_PATCHED=1
rm -rf "${XDG_CACHE_HOME:-$HOME/.cache}/cloudflarechy"
rm -rf "${XDG_CACHE_HOME:-$HOME/.cache}/quickshell/qmlcache"
echo "restarting the shell onto the mock"
omarchy restart shell >/dev/null 2>&1
sleep 12

ORIGINAL_WORKSPACE=$(hyprctl activeworkspace -j | jq -r '.id')
hyprctl dispatch "hl.dsp.focus({ workspace = $WORKSPACE })" >/dev/null
sleep 1
[[ $(hyprctl activeworkspace -j | jq -r '.windows') == 0 ]] ||
  die "workspace $WORKSPACE has windows on it; set CLOUDFLARECHY_DEMO_WORKSPACE
  to an empty one — the demo should be the panel over a wallpaper, nothing else"

# --- work out where to point the camera ------------------------------------
# Same trick the screenshots use: the panel is whatever changes between a frame
# with it closed and a frame with it open. The crop reaches up to the top of
# the screen, because the bar icon changing colour is one of the beats.
# Retried, because anything else that moves between the two frames lands in the
# diff and swallows the panel — a notification sliding in is enough, and one of
# those is quite likely just after a shell restart.
echo "finding the panel"
pw=0; ph=0; px=0; py=0; screen_w=0
for attempt in 1 2 3 4 5; do
  omarchy-shell cloudflarechy close >/dev/null 2>&1; sleep 2
  grim "$WORK/closed.png"
  omarchy-shell cloudflarechy open >/dev/null 2>&1; sleep 5
  grim "$WORK/open.png"
  bbox=$(magick "$WORK/open.png" "$WORK/closed.png" -compose difference -composite \
           -colorspace Gray -threshold 8% -chop 0x40 -format '%@' info:)
  screen_w=$(magick "$WORK/open.png" -format '%w' info:)
  if [[ $bbox =~ ^([0-9]+)x([0-9]+)\+([0-9]+)\+([0-9]+)$ ]]; then
    pw=${BASH_REMATCH[1]}; ph=${BASH_REMATCH[2]}
    px=${BASH_REMATCH[3]}; py=$((BASH_REMATCH[4] + 40))
    (( pw > 200 && pw < screen_w / 2 && ph > 200 )) && break
  fi
  echo "  attempt $attempt saw '$bbox', not a panel — something else moved; retrying"
  pw=0
  sleep 3
done
(( pw > 0 )) || die "could not find the panel in five attempts. Something on
  screen keeps changing between frames — a notification, or an animated
  wallpaper — and the demo needs a still backdrop."

# Margin on the left, the bar at the top, a little air at the bottom. Even
# numbers because h264 will not encode odd dimensions.
margin=48
cx=$(( (px - margin) / 2 * 2 ))
cw=$(( (screen_w - cx) / 2 * 2 ))
ch=$(( (py + ph + 28) / 2 * 2 ))
echo "  panel ${pw}x${ph} at ${px},${py} — recording ${cw}x${ch}+${cx}+0"
omarchy-shell cloudflarechy close >/dev/null 2>&1; sleep 1

# --- the beats -------------------------------------------------------------
key()  { wtype -k "$1"; sleep "${2:-2}"; }
ipc()  { omarchy-shell cloudflarechy "$@" >/dev/null 2>&1; }

echo "recording"
gpu-screen-recorder -w "$MONITOR" -f 30 -o "$WORK/raw.mp4" >"$WORK/rec.log" 2>&1 &
REC_PID=$!
sleep 4                       # let the encoder settle before anything happens

sleep 2                       # the bar, at rest
ipc open;              sleep 5    # the zone panel
key t 3                           # 7 days
key t 3                           # 30 days
key t 2                           # back to 24 hours
ipc worker api-router; sleep 5    # one Worker, in full
key Escape 1
key a 5                           # the account: tunnels and Workers
key Escape 1
key p 3                           # purge asks first
key Escape 1                      # ... and takes no for an answer
key d 6                           # Development Mode on — the bar icon lights
key d 4                           # and off again, and it goes out
key Escape 2                      # done

sleep 1
kill -INT "$REC_PID" 2>/dev/null; wait "$REC_PID" 2>/dev/null || true
REC_PID=""
sleep 2
[[ -s $WORK/raw.mp4 ]] || die "the recorder produced nothing — see $WORK/rec.log"

# --- crop, trim the settling time, and write it out ------------------------
# The silent audio track is not an accident: some places that take video
# refuse a file with no audio stream at all, and a demo of a bar widget has
# nothing to say out loud.
#
# Doubled after the crop. The crop is native screen pixels — around 550 wide,
# which is the panel's real size — and a frame that small is re-encoded by
# whatever site it is posted to at a bitrate budgeted for its dimensions, then
# upscaled again by each viewer's player. Doubling first buys a bigger budget
# for the thing that matters here, which is 16px type staying legible.
#
# Lanczos, not nearest-neighbour. Nearest-neighbour is the right choice for a
# hard pixel grid, and this is not one: Qt anti-aliases its glyphs and the bar
# caps are rounded, so there are no hard edges to preserve — doubling by
# sample-and-hold only turns the anti-aliasing into visible 2x2 blocks. Checked
# both at 8x on the "50.0%" delta before choosing.
echo "encoding"
ffmpeg -y -loglevel error -i "$WORK/raw.mp4" -f lavfi -i anullsrc=r=44100:cl=stereo \
  -vf "crop=${cw}:${ch}:${cx}:0,scale=iw*2:ih*2:flags=lanczos" \
  -c:v libx264 -preset slow -crf 20 -pix_fmt yuv420p -movflags +faststart \
  -c:a aac -b:a 64k -shortest \
  "$OUT"

printf '\n%s\n' "$OUT"
ffprobe -v error -show_entries format=duration,size -of default=nw=1 "$OUT"
echo
echo "the zone is example.com and the account is Acme Inc — check before posting"
