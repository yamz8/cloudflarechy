# The --social cut of tests/demo.sh, sourced by it: social_prepare before the
# panel is looked for, social_cut once it has been found. The mock, the token
# swap, the silenced notifications and the cleanup that undoes all of them are
# demo.sh's and apply here unchanged.
#
# Built for a feed rather than for the README:
#
# - Short. A pass over the panel's views — the zone at a day and a week, a
#   Worker, the zone again at a month, the account, a tunnel — then the panel
#   changing theme, which is
#   the part an Omarchy audience shares. No captions, no title card, and no
#   switches flipped; the views carry it. Each is held long enough to take in
#   rather than to read every figure: about two seconds.
# - 4:5 at 1080x1350, the largest shape a phone feed shows inline, cut from the
#   full height of the screen so the desktop around the panel comes with it.
# - The shell drawn at a larger type size, so the panel fills that frame with
#   real pixels rather than upscaled ones. At the shell's default size it
#   filled two thirds of it and its figures were unreadable at feed size.
# - Two Omarchy themes, in the shell's memory only. The themes are applied
#   with the shell's own transition call rather than omarchy-theme-set, which
#   would also retint terminals, editors and the browser and write the choice
#   to disk. Nothing is written, and demo.sh's closing shell restart reloads
#   the real theme and type size.
# - It ends on the second theme rather than switching back. The switch back
#   to the machine's own theme looked like a glitch as the last thing seen,
#   and a loop that changes theme on the jump reads as one more switch.

THEMES=(rose-pine gruvbox)
FONT_SIZE=15      # the shell's base-size while recording; the default is 12
OUT_W=1080; OUT_H=1350
OMARCHY_PATH="${OMARCHY_PATH:-/usr/share/omarchy}"
STATE_THEME="$HOME/.local/state/omarchy/current"

key() { wtype -k "$1"; sleep "${2:-2}"; }
ipc() { omarchy-shell cloudflarechy "$@" >/dev/null 2>&1; }

# The shell's own shell.toml with the type size raised. Every surface scales
# off base-size, the bar included, so the icon grows along with the panel.
enlarge() { sed -E "s/^base-size[[:space:]]*=.*/base-size = $FONT_SIZE/" "$1" | base64 -w 0; }

social_prepare() {
  # --- the themes, rendered without applying them ----------------------------
  # omarchy-theme-set-templates derives each theme's shell.toml from its
  # colours. It writes under $HOME, so it gets a scratch one; the user's own
  # templates are copied in so a customised bar comes out the way it looks on
  # this machine.
  echo "preparing the themes"
  declare -gA T_COLORS T_SHELL T_BG
  T_COLORS[home]=$(base64 -w 0 "$STATE_THEME/theme/colors.toml")
  T_SHELL[home]=$(enlarge "$STATE_THEME/theme/shell.toml")
  T_BG[home]=$(readlink -f "$STATE_THEME/background")
  local t fake next
  for t in "${THEMES[@]}"; do
    fake="$WORK/theme-$t"
    next="$fake/.local/state/omarchy/current/next-theme"
    mkdir -p "$next"
    cp -r "$OMARCHY_PATH/themes/$t/"* "$next/" 2>/dev/null || die "no theme called $t"
    if [[ -d $HOME/.config/omarchy/themed ]]; then
      mkdir -p "$fake/.config/omarchy"
      cp -r "$HOME/.config/omarchy/themed" "$fake/.config/omarchy/"
    fi
    HOME="$fake" OMARCHY_PATH="$OMARCHY_PATH" omarchy-theme-set-templates >/dev/null 2>&1
    [[ -f $next/shell.toml ]] || die "could not render the $t theme"
    T_COLORS[$t]=$(base64 -w 0 "$next/colors.toml")
    T_SHELL[$t]=$(enlarge "$next/shell.toml")
    T_BG[$t]=$(find "$OMARCHY_PATH/themes/$t/backgrounds" -maxdepth 1 -type f | sort | head -1)
  done
  shown=home
  omarchy-shell -q shell applyTheme "${T_COLORS[home]}" "${T_SHELL[home]}"
  sleep 2
}

theme() {
  omarchy-shell -q background themeTransition "${T_BG[$shown]}" "${T_BG[$1]}" "${T_BG[$1]}" \
    "${T_COLORS[$1]}" "${T_SHELL[$1]}"
  shown=$1
  sleep "${2:-1.1}"
}

social_cut() {
  # A 4:5 window the full height of the screen, centred on the panel. The
  # panel hangs from its bar icon, so the icon comes with it.
  local screen_h cw cx
  screen_h=$(magick "$WORK/open.png" -format '%h' info:)
  cw=$(( screen_h * 4 / 5 / 2 * 2 ))
  cx=$(( px + pw / 2 - cw / 2 ))
  (( cx > screen_w - cw )) && cx=$(( screen_w - cw ))
  (( cx < 0 )) && cx=0
  cx=$(( cx / 2 * 2 ))
  echo "  framing ${cw}x${screen_h}+${cx}+0"

  # Every beat that fetches is fetched once beforehand, so the take shows the
  # answer rather than LOADING — the mock is instant, but the script and the
  # panel between them are not, and at these hold times half a second of a
  # half-drawn panel is a beat lost. The reads stay cached for a minute, which
  # outlasts the take.
  echo "warming the panel"
  key t 1.5; key t 1.5; key t 1.5     # the week, the month, and back
  ipc worker api-router; sleep 3
  key Escape 0.5
  key a 3
  ipc tunnel homelab; sleep 3
  key Escape 0.5
  key Escape 0.5
  # Once round the themes as well: a wallpaper the shell has not loaded yet
  # comes in as a black frame on its first transition.
  theme rose-pine 1.5; theme gruvbox 1.5; theme home 2
  ipc close; sleep 1
  ipc open;  sleep 4

  : > "$WORK/marks"
  mark() { printf '%s %s\n' "$1" "$(date +%s.%N)" >> "$WORK/marks"; }

  echo "recording"
  gpu-screen-recorder -w "$MONITOR" -f "$FPS" -fm cfr -cursor no \
    -write-first-frame-ts yes -o "$WORK/raw.mp4" >"$WORK/rec.log" 2>&1 &
  REC_PID=$!
  sleep "$SETTLE"

  # Hold times. Around two seconds a view: long enough to register what it
  # is, short enough that the next one is what holds attention. An earlier
  # cut at one second a view read as flicking through, not showing.
  mark start
  sleep 2.0                            # the zone, the last day
  key t 1.8                            # the week
  ipc worker api-router; sleep 2.6     # one Worker, in full
  # Every visit to the zone does something. Passing through it for a third
  # of a second on the way from one screen to the next read as a flicker, so
  # the return from the Worker is where the window widens to the month.
  key Escape 0.9
  key t 1.8                            # the month
  key a 2.3                            # the account: tunnels and Workers
  ipc tunnel homelab; sleep 2.0        # one tunnel: its routes and connectors
  # The themes play over the tunnel rather than back on the zone: going back
  # would pass through the account screen for a third of a second, which is
  # the flicker the order above exists to avoid. The first theme lands ~0.7s
  # after it is asked for, so the tunnel still holds for close to three.
  # A theme lands ~0.7s after it is asked for. That only shifts the first;
  # the last is cut by the end of the take, so its hold gets the 0.7s back.
  theme rose-pine 1.5
  theme gruvbox 2.8
  mark end

  kill -INT "$REC_PID" 2>/dev/null; wait "$REC_PID" 2>/dev/null || true
  REC_PID=""
  sleep 2
  [[ -s $WORK/raw.mp4 ]] || die "the recorder produced nothing — see $WORK/rec.log"
  local stamp
  stamp=$(ls "$WORK"/raw*.ts 2>/dev/null | head -1)
  [[ -s $stamp ]] || die "the recorder wrote no first-frame timestamp"
  [[ -n ${CLOUDFLARECHY_DEMO_KEEP:-} ]] && mkdir -p "$CLOUDFLARECHY_DEMO_KEEP" &&
    cp "$WORK"/raw.mp4 "$stamp" "$WORK"/marks "$CLOUDFLARECHY_DEMO_KEEP"/

  # The cut starts at the first beat, measured from the recorder's own note of
  # when its first frame landed. The README cut trims a fixed TRIM and trusts
  # the recorder to have started on time; it does not — it was over a second
  # late on one take.
  local first start end
  first=$(awk 'END { printf "%.6f", $2 / 1000000 }' "$stamp")
  start=$(awk -v f="$first" '$1 == "start" { printf "%.3f", $2 - f - 0.05 }' "$WORK/marks")
  end=$(awk '$1 == "start" { s = $2 } $1 == "end" { printf "%.3f", $2 - s + 0.05 }' "$WORK/marks")
  (( $(awk -v t="$start" 'BEGIN { print (t > 0) }') )) ||
    die "the recorder's first frame came after the first beat — raise SETTLE"

  # The shell's wallpaper wipe drops to black for ten-odd frames as it
  # finishes — it swaps the incoming layer for the base image, and the base
  # has not drawn yet. Unmissable at 60fps and nothing this plugin can fix, so
  # those frames are found by the wallpaper strip left of the panel going
  # black, dropped, and the frame before each gap held in their place. No
  # theme used here has a wallpaper dark enough to trip it.
  local drop
  drop=$(ffmpeg -ss "$start" -i "$WORK/raw.mp4" -t "$end" \
           -vf "crop=150:${screen_h}:${cx}:0,blackframe=amount=90:threshold=32" -f null - 2>&1 |
         sed -n 's/.*\] frame:\([0-9]*\).*/\1/p' | awk '{ printf "+eq(n\\,%s)", $1 }')
  (( ${#drop} )) && echo "  holding over $(grep -o eq <<<"$drop" | wc -l) black frames"

  echo "encoding"
  ffmpeg -y -loglevel error -ss "$start" -i "$WORK/raw.mp4" \
    -f lavfi -i anullsrc=r=44100:cl=stereo \
    -vf "select='not(0$drop)',fps=${FPS},crop=${cw}:${screen_h}:${cx}:0,scale=${OUT_W}:${OUT_H}:flags=lanczos" \
    -map 0:v -map 1:a -t "$end" -r "$FPS" \
    -c:v libx264 -preset slow -crf 18 -profile:v high -pix_fmt yuv420p -movflags +faststart \
    -c:a aac -b:a 64k -shortest \
    "$OUT"

  printf '\n%s\n' "$OUT"
  ffprobe -v error -show_entries stream=width,height,r_frame_rate -show_entries format=duration,size \
    -of default=nw=1 "$OUT"
  echo
  echo "the zone is example.com and the account is Acme Inc — check before posting"
}
