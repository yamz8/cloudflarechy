# Changelog

## 0.8.0

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
