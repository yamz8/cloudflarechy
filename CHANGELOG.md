# Changelog

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
