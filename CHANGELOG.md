# Changelog

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
