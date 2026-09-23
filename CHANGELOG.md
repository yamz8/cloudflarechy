# Changelog

## Unreleased

- Tunnels say what they serve and how long they have been the way they are:
  `healthy for 3d · 4 conn`, and under the name the public hostnames from
  the tunnel's ingress rules — `grafana, nas, ssh · example.com`. A locally
  managed tunnel keeps its routes in `cloudflared`'s config file, out of the
  API's sight, and says so; routes that exist but cannot be read say that
  rather than passing for none. One more request per remote tunnel, made side
  by side and cached with the list.
- The connection count is live connections. Cloudflare keeps a dropped one
  listed for several minutes, flagged as reconnecting, and counting it showed
  a tunnel that had lost a connection as whole. The README had also claimed
  the count separated healthy from "healthy, on one leg"; a whole
  `cloudflared` holds four, and one short of that is already `degraded`.
- `tests/capture.sh` keeps its pictures aside until all four are taken. The
  shell reloads a plugin when a file in its directory changes, so writing the
  first picture into the repository reloaded the widget under the second, and
  every run failed there.
- Switching the range, the zone or into a Worker no longer empties the panel
  first. It used to drop the view it was leaving the moment you asked, and
  the panel shrank to its header for as long as the answer took, then grew
  back — a jump on every switch, even from cache, since the answer still
  comes from a separate process. The old view now stays until the new one has
  arrived and is swapped in one frame. The selector keeps naming the window on
  screen rather than the one asked for, so figures never sit under another
  range's label; the one asked for is lit instead, as is a Worker row that
  has been clicked. A switch slow enough to notice dims the view it is
  leaving. While a zone switch is in flight the switches do nothing, because
  the ones on screen belong to the zone being left.
- Only the latest question answers. Two quick presses of `t` sent two
  requests, and the first could land last and paint a week's figures under
  the month the selector had moved on to.
- `tests/demo.sh --social` records a twenty-second cut for a feed rather than
  the README: 4:5 at 60fps, about two seconds on each of the panel's views,
  then three Omarchy themes and back to the first. Themes and a larger type
  size are applied to the running shell only, and the closing restart takes
  them away again.
- The mock serves traffic with a shape in it when asked
  (`CLOUDFLARECHY_MOCK_SHOWCASE=1`) — quiet nights, a working day, one hour
  that took off. The fixture's ramp is built for exact deltas and filmed as a
  zone nobody visits. Its Workers get the same day, and the account list is
  summed from the same rows as each Worker's detail so the two agree. The
  test suite does not set it.

## 0.9.4

- Under Attack Mode says it cannot tell, instead of saying it is off. It is a
  value of the security level rather than a switch of its own, and a
  credential without Zone Settings cannot read that level — which includes
  every wrangler login, the route the Connect screen leads with. The script
  derived `under_attack` from the empty string it got back and reported
  `false`; it now reports `null` alongside the refusal. The button reads
  `Under attack  ?` and its tooltip says what would let it see. The label is
  keyed on the refusal rather than on an empty level, because the overview is
  cleared on every range change and an empty level mid-reload would otherwise
  flash a question mark on a zone that can read its level perfectly well.

## 0.9.3

- A write no longer leaves the other windows stale. Development Mode, Under
  Attack and a purge each dropped `overview.<zone>.json`, which stopped being
  a real key when the range went into it — so the three cached windows
  survived the write they had just been invalidated by. The panel hid it by
  reloading with `--fresh`; anyone driving `bin/cloudflarechy` directly got up
  to a minute of stale state, and the three lines read as though they were
  doing something. Dropped by prefix now, and the tests pin the behaviour
  rather than the key name, because a name assertion would have drifted along
  with the bug.
- `tests/demo.sh` silences notifications while it records. Restarting the
  shell makes the crash capture announce it, and the banner landed in the
  top-right of the frame — over the bar icon, which is the one thing the last
  beat exists to show. It also counted as a window and could abort the run on
  the empty-workspace check. Put back afterwards, after the shell is up again
  rather than before, because the setting is persisted lazily and restarting
  the shell on top of the write lost it.
- The demo is about twenty seconds instead of fifty, and twice the size it
  was. The encoder's settling time is trimmed off the head rather than shipped
  as a still frame, and the frame is doubled before encoding so the small type
  survives a re-encode.

## 0.9.2

- `tests/demo.sh` records a demo of the panel against the mock: the zone, the
  three windows, a Worker in full, the account screen, the purge prompt asking
  first, and Development Mode going on and off. Every beat is a keystroke, so
  none of it depends on where the mouse is — which is just as well, because a
  warped cursor dismisses the panel.
- The mock can be asked for a calm account. The fixture keeps a tunnel down on
  purpose, which means the bar icon alerts from the first frame and the one
  thing a bar widget most needs to demonstrate — the icon lighting up when a
  switch goes on — cannot be filmed. `CLOUDFLARECHY_MOCK_CALM=1` makes the
  account healthy; nothing in the test suite sets it.

## 0.9.1

- Routes became **Workers on this zone**, and carry the Worker's figures. The
  account-wide list moving to its own screen took Workers off the first thing
  you see, which was a loss — but the fix was not to put an account-scoped list
  back under a zone picker. The scripts answering for *this domain* are the one
  Workers question that is genuinely zone-scoped, and they were already on the
  panel; they just never said how they were doing. Each row is now the script
  and its health on one line with the pattern beneath, because three columns on
  one row elided the name and the path and left the figures nowhere to go.
- The zone strip carries no heading unless it has news. `ZONE` over three
  buttons was a scope word labelling content that is not a zone — the same
  thing that made the account header read as a section with nothing in it — and
  once the plan stopped showing on free zones it was a bare word carrying no
  information at all. It returns for `PAUSED`, `READ-ONLY` and a paid plan. The
  buttons name themselves.

## 0.9.0

- The account line says it goes somewhere. Every other row that opens something
  sits under a heading implying its rows are things — a Worker under WORKERS, a
  route under ROUTES — but this one stands alone under a rule and read as a
  line of figures, with the pointing hand only arriving once you were already
  over it. It carries a chevron now.

- The account has its own screen. Tunnels and Workers never belonged to the
  zone in the picker — switching zones changes none of those rows — but they
  sat underneath it and read as though they did. `a` opens them, `Esc` comes
  back, and the zone panel keeps one line: the account's name, how many
  tunnels are down, how many Workers there are. That line exists because a
  tunnel going down is one of the four things that lights the bar icon, and a
  panel you open to ask why should not need a second keystroke to answer.
- With those two lists gone the zone panel is about a third shorter, and the
  account screen shows every tunnel and every Worker instead of the top three
  and a tail — the cap was only there because they were sharing a panel.
- The zone strip no longer announces `FREE WEBSITE`. The plan is worth the
  space when it is not the one nearly everybody is on; on a free zone it was
  filling the slot where `PAUSED` and `READ-ONLY` need to be noticed.

## 0.8.2

- A Worker that fails a little no longer looks like one that fails entirely.
  Any error at all painted the whole row urgent red, so ten exceptions in two
  and a half thousand invocations shouted exactly as loudly as twelve failures
  out of twelve. The row now crosses into red at the same 5% the bar icon uses
  for a zone's 5xx rate and sits in the brand amber below it, and only the
  error count is coloured — the request count and the CPU time beside it were
  never the bad news.
- `ACCOUNT · <name>` is set as a kicker rather than a section header. At header
  weight with nothing beneath it before the next header, it read as a section
  whose contents had failed to load; it names the scope of everything below the
  rule, so it is set like a label on that rule. The footer no longer repeats
  the account name two sections later, unless those sections are absent.
- A Worker's detail view shows three figures rather than five. The zone view
  was cut to three for legibility and this one went on cramming five across the
  same width; p99 and subrequests keep their numbers on the line below, which
  is the weight they were always worth.
- A healthy Worker's graph reads as a graph. Its bars are filled by errors, so
  a script at 99.5% success has almost no fill and the track was carrying the
  chart alone at an opacity chosen for a track that gets covered up.
- The bar's attention dot is separated from the mark it sits on. It is the
  shape cue for anyone who cannot see the colour change, and drawn in the alert
  colour on a mark already in the alert colour it merged into the cloud's own
  silhouette — doing nothing for precisely the people it exists for.
- A capped list offers **Dashboard**, not **dashboard**.

## 0.8.1

- The README screenshots are regenerated by `tests/capture.sh` instead of by
  hand. They had gone five commits stale — the panel on the front page predated
  the traffic deltas, the range selector, the routes section and the account
  break — because refreshing them was an hour of fiddling nobody volunteers
  for. It is now a minute, and it puts your token and the request path back
  whether or not it succeeds.
- The graph stops reporting an hour the pointer left. Hover was tracked by one
  MouseArea per bar setting an index on `entered` and clearing it on `exited`,
  and `exited` is not reliably delivered to a layer-shell surface: the readout
  froze on whichever bucket it had last seen and stayed there, with the cursor
  a hundred pixels outside the panel, until the panel was closed. One area over
  the whole row now derives the bucket from the pointer's own position, so
  there is no state left to go stale. The bar being read is also lit, which it
  never was.
- An hour in which nothing happened is drawn as an empty hour. Cloudflare
  returns no row at all for an empty bucket, so a quiet night arrived as a
  short array and the chart divided its width by however many rows it got —
  twenty fat bars for a day, reading as steady traffic through hours that had
  none. Both graphs now rebuild the window from the clock. A Worker that runs
  on a cron was the worst of it: three invocations became three slabs filling
  the panel.
- Routes say when they cannot be read. A token without Workers Routes → Read
  got the same empty section as a zone that genuinely has no routes, which are
  opposite problems — one is nothing to do, the other is a scope to add. The
  refusal was in the data all along and the panel was dropping it; tunnels and
  Workers have always reported theirs.
- A route row names its Worker. With a long script and a long pattern both
  columns elided at once, so two routes on one host rendered as
  `edge-personalisati… …y-long-path-segment/deeper-1/*` and differed by a
  character near the right edge. The script name now takes the room it needs
  and the pattern is cut from the middle, keeping the host and the tail.
- Opening a Worker no longer changes the window behind your back. Invocation
  analytics do not reach back far enough to offer the week and the month the
  traffic graph offers, so the Worker view stays on its own 24 hours — and now
  says so when the zone is showing something else.
- The wrangler command is printed under its button rather than hung off it as
  a tooltip, which drew upward through the paragraph above it and past the
  panel's left edge.

## 0.8.0

- The panel fits again. It was capped at the same fixed height as the agents
  panel, whose content is a known size; this one carries three lists that grow
  with the account, and rows were being pushed below a fold with nothing to
  say they were there. It now sizes to its content the way the network panel
  does, and the screen is the only limit.
- Each list shows three rows, ranked so the rows worth opening the panel for
  survive the cut — a tunnel that is down, a Worker that is throwing — then
  says how many it is standing in for and opens the page that has them all.
  Workers used to truncate at five silently while the heading claimed the full
  count.
- The footer names the credential instead of printing its path, which was
  wrapping one line of provenance onto two. The credential screen still shows
  the path in full, which is where you go to change it.
- A Worker nobody called reads as idle rather than broken. Its success rate
  was rendering as `0%` in red, which says every invocation failed when the
  truth is that none happened; it now shows `—` and the screen says so.
- Hovering a bar names its bucket under the graph: the hour or day, the
  requests, the cache share. On the zone chart it takes the 5xx/threats line's
  place rather than adding one, so nothing moves; a Worker's chart has no line
  to share, so it inserts one below the bars where it cannot push them out
  from under the pointer.
- A `ROUTES` section: which Workers answer for this domain, and on what
  pattern. Cloudflare puts this on the zone page, and it is the only Workers
  view that genuinely belongs under a zone picker — the script list is
  account-wide. Click one to open that Worker; a route with no Worker behind
  it says so and stays inert. Needs Zone → Workers Routes → Read, and without
  it the section is hidden and nothing else changes.
- Tunnels and Workers now sit under an `ACCOUNT` header. They are
  account-scoped — Cloudflare files them under Compute and Networking, not
  under a domain — so listing them beneath the zone picker implied they
  changed with the zone, and they never did.
- `24H` / `7D` / `30D` in the traffic heading, and `t` to cycle them. Hours
  come from `httpRequests1hGroups`, days from `httpRequests1dGroups` — a
  different dataset keyed on a `date` of GraphQL type Date rather than a
  `datetime` of type Time, so the range carries the dataset, the dimension,
  its scalar type and the bucket count together.
- The baseline rebases with the range: the 7-day view compares against the 7
  days before it, not against yesterday. Each range caches under its own key.
- The range resets to 24 hours when the panel closes. The bar dot reads its
  error rate from whichever window is loaded and the background poll keeps
  loading it, so leaving the panel on 30 days would quietly redefine what
  lights the icon.
- Requests, cached and served carry a period-over-period delta. The window is
  fetched 48 hours wide and split on its midpoint, so the comparison costs no
  extra request, and it is split by timestamp rather than by counting rows
  because an hour with no traffic is simply absent from the response.
- Deltas are relative, not point differences, matching what the dashboard
  reports: its own cache-hit-rate card reads 0.97% with a 56.3% fall, which is
  only possible as a relative change.
- A zone with no earlier window shows no delta at all rather than `0%`.
  Nothing to compare is not the same answer as unchanged.
- The stat row drops from five slots to three. Five left 76px each, which
  cannot hold a number and its delta; `5xx` and threats moved to a line under
  the graph and take colour only when non-zero.

## 0.7.0

- Click a Worker to give it the whole panel: requests, success rate, p50 and
  p99 CPU, subrequests, its own 24h graph with errors filled in, and the
  invocation-status breakdown. `scriptThrewException` and `clientDisconnected`
  mean different things and the dashboard buries both; each status keeps its
  own quantiles rather than inheriting the headline pair.
- The success rate never rounds up to 100%. A Worker at 99.62% is not a Worker
  with no failures, and that screen exists to show the difference.
- The graph's filled portion is now a named field, so the zone chart fills by
  cache hits and a Worker's fills by errors without either pretending to be
  the other.
- Each screen sizes the panel to itself instead of to the tallest one, so
  drilling into a Worker no longer leaves a lake of empty panel below it.
- `worker <account> <script>` on the CLI, and
  `omarchy-shell cloudflarechy worker <script>` over IPC.

## 0.6.0

- The bar icon also lights when the zone is answering 5xx above a threshold,
  not only when a switch was left on or a tunnel is down. A zone can be failing
  with nothing switched on, and that is worth opening the panel for. Default 5%
  of requests, with a floor of 20 errors so a quiet hour cannot trip it on a
  handful of requests; `errorPercent` tunes it.
- Hovering the bar icon now says which of those reasons applies, so the colour
  is never a riddle.

## 0.5.0

- The bar icon now turns the theme's urgent colour when Development Mode or
  Under Attack Mode is on, or a tunnel is down — the whole mark, not a five
  pixel dot on the corner of it. The widget's entire argument is that the bar
  tells you a temporary switch is still on, and it was whispering. The colour
  comes from `bar.urgent`, the same one the network widget uses when pings
  drop, so it follows the theme rather than inventing an orange.
- The dot stays as a shape cue, because a theme may set `bar.urgent` close to
  its foreground and not everyone can tell two colours apart.
- `attentionDot` now governs the whole signal rather than just the dot.

## 0.4.0

- Show 5xx in the stats row, in place of unique visitors. A zone serving
  nothing but errors reports the same request count as a healthy one, so the
  panel was rendering a failing zone as a quiet one. 4xx is counted separately
  and deliberately not shown — a 403 is often the zone working.
- Ask for status codes in the analytics query, and give up optional fields one
  at a time (uniques, then status codes) rather than failing the whole query on
  a plan that will not serve one.
- Workers rows now show 24h invocations, errors and p50 CPU instead of a deploy
  date, and link to that Worker's metrics tab rather than the account list.
  Requests are summed across invocation statuses; CPU is taken from the busiest
  status, because averaging quantiles describes nothing. A Worker with no
  invocations keeps its deploy date rather than claiming zero requests.
- Fix a latent layout bug: the stat values had no width and no elide, so a
  value wider than its fifth of the row drew over its neighbour instead of
  truncating.

## 0.3.0

- Add a Connect screen. A fresh install no longer answers "no token" with a
  paragraph telling you to go elsewhere: the panel offers `wrangler login` in
  one click, or a field to paste an API token into.
- Reach it again any time with the key icon in the header or `c`, so a
  read-only wrangler session can be upgraded to a token later, and a saved
  token can be forgotten to fall back to wrangler.
- Tokens are validated against Cloudflare before they are saved — a token that
  does not work would otherwise outrank, and hide, a wrangler fallback that was
  working. They travel over stdin rather than argv, and land `600` in a `700`
  directory.
- Name an environment token that is silently outranking the saved file, which
  is otherwise debugged by guesswork.
- New `setup`, `save-token` and `forget-token` subcommands behind all of it.

## 0.2.0

- Fall back to wrangler's OAuth credential when no API token is configured, so
  the panel works out of the box for anyone who has run `wrangler login`. It
  covers every read — zones, 24h analytics, tunnels, Workers.
- Mark such a session `READ-ONLY` and disable the three switches, because
  wrangler's entire requestable scope catalogue holds one zone scope,
  `zone:read`. Writes are refused in the script with a sentence naming the
  credential, rather than passed through as a `9109` from the API.
- Show the credential and its deadline in the footer
  (`token: wrangler until 01:47`). An expired wrangler session is reported, not
  repaired: this plugin does not own that config file and will not race
  wrangler for it.
- Probe token health per credential kind — `/user/tokens/verify` only validates
  API tokens and answers `Invalid API Token` for an OAuth one.
- Scale the traffic graph by square root. On real traffic a single crawl
  flattened the other 23 hours onto the 1px floor under linear scaling, while a
  logarithm draws an ordinary day as a wall of identical bars. The graph is for
  shape, and the exact figures above it are unaffected.

## 0.1.0

First release.

- Bar widget with a themed cloud mark, and a dot when Development Mode or Under
  Attack Mode is on or a tunnel is down or degraded.
- Panel: 24h requests, cache ratio, bytes served, unique visitors and threats,
  with one bar per hour showing the cached share.
- Zone controls: Development Mode with its countdown, Under Attack Mode that
  restores the previous security level when switched off, and Purge cache
  behind a confirmation.
- Cloudflare Tunnels with status and connection count; five most recent Workers.
- Zone picker for accounts with more than one zone; the `zone` setting pins one.
- `bin/cloudflarechy`: the whole data layer as a JSON-per-command CLI, with a
  short-lived read cache and a `--fresh` bypass.
- Degrades one section at a time when a token lacks a scope, and names the
  scope that is missing.
