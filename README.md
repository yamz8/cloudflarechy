# Cloudflarechy

One Cloudflare zone in the Omarchy bar: what traffic did in the last 24 hours,
what the cache did with it, whether your tunnels are up — and whether
Development Mode or Under Attack Mode is still on from the last time you
needed it.

![The panel](preview.png)

That last part is the reason the bar icon carries a dot. Both of those switches
are meant to be temporary, neither is visible from the desktop, and both get
left on for days. The dot also lights when a Cloudflare Tunnel is `down` or
`degraded`.

Everything shown comes from the Cloudflare API. Nothing is computed locally
except the cache ratio, which is cached ÷ total over the same 24 hours.

## Install

The plugin lives in `~/.config/omarchy/plugins/cloudflarechy/`. Put it on the
bar with:

```bash
omarchy plugin enable cloudflarechy --section right
```

`omarchy bar put cloudflarechy --section right` does the same thing for a
widget that is already enabled, and `omarchy bar move cloudflarechy --after
omarchy.tray` puts it somewhere else in the row.

Then give it a token (below). Without one the panel says `not connected` and
explains what to do.

## The API token

Create a token at
[dash.cloudflare.com/profile/api-tokens](https://dash.cloudflare.com/profile/api-tokens)
and save it where the plugin can find it:

```bash
mkdir -p ~/.config/cloudflarechy
printf '%s\n' 'YOUR_TOKEN' > ~/.config/cloudflarechy/token
chmod 600 ~/.config/cloudflarechy/token
```

It is read from the first of these that has one, so an exported variable or a
keyring entry works just as well:

1. `$CLOUDFLARE_API_TOKEN`
2. `$CF_API_TOKEN`
3. `~/.config/cloudflarechy/token` (or `$CLOUDFLARECHY_TOKEN_FILE`)
4. `secret-tool lookup service cloudflarechy`

An API token, not the legacy global key — this needs a handful of scopes and a
token can be minted with exactly those:

| Scope | What it buys | Without it |
|---|---|---|
| Zone → Zone → Read | the zone list, plan, status | nothing works |
| Zone → Analytics → Read | the 24h numbers and the graph | traffic section says so |
| Zone → Zone Settings → Read | Development Mode, security level | the two switches grey out |
| Zone → Zone Settings → Edit | flipping those two switches | they stay read-only |
| Zone → Cache Purge → Purge | Purge cache | the button errors |
| Account → Cloudflare Tunnel → Read | the tunnels list | section hidden, reason shown |
| Account → Workers Scripts → Read | recent Workers | section hidden |

Read-only is a perfectly good way to run this: grant the Read scopes and the
panel becomes a dashboard whose buttons simply say why they cannot act.

## What it shows

**Last 24 hours** — requests, share served from cache, bytes served, unique
visitors, threats blocked, then one bar per hour. Each bar is that hour's
requests; the filled part at its foot is the share that came from cache. Bars
are scaled against the busiest hour in the window, not an absolute ceiling.

`visitors` shows `—` rather than `0` when the plan does not expose uniques —
those are different facts.

**Zone** — Development Mode (with the countdown Cloudflare is running; it
expires by itself after three hours), Under Attack Mode, and Purge cache, which
asks first because every subsequent miss goes to your origin.

Turning Under Attack *off* restores the security level that was in force before
it was turned on — that level is recorded in `~/.local/state/cloudflarechy/` at
the moment it is raised. If the plugin has no record, it falls back to `medium`.

**Tunnels** — every `cfd_tunnel` on the account, its status and its connection
count, which is what separates "healthy" from "healthy, on one leg".

**Workers** — the five most recently deployed scripts.

Deliberately absent: DNS records, firewall rules, R2, Pages. Those are editing
surfaces, and editing them from a popup you opened by accident is a bad idea.
The Dashboard button is one click from all of them.

## Keys and clicks

| | |
|---|---|
| click the icon | open/close the panel |
| right-click the icon | refresh now |
| `r` | refresh now |
| `d` | toggle Development Mode |
| `u` | toggle Under Attack Mode |
| `p` | purge cache (asks first) |
| `←` / `→` | previous/next zone |
| `Enter` | open this zone in the dashboard |
| `Esc` | close, or cancel the purge prompt |
| `Tab` | next bar panel |

## Settings

In `~/.config/omarchy/shell.json`, on the widget's entry — or through the bar's
own settings UI:

| Key | Default | Meaning |
|---|---|---|
| `zone` | `""` | Domain to show, e.g. `example.com`. Empty uses the first zone the token can read. |
| `refreshSeconds` | `300` | Background poll interval. The bar dot is only as fresh as this. |
| `showTunnels` | `true` | Show the tunnels section. |
| `showWorkers` | `true` | Show the Workers section. |
| `attentionDot` | `true` | Dot on the bar icon when something needs attention. |

## From the command line

`bin/cloudflarechy` is the whole data layer and is useful on its own — every
subcommand prints one JSON object, errors included:

```bash
./bin/cloudflarechy status
./bin/cloudflarechy zones
./bin/cloudflarechy overview <zone-id>
./bin/cloudflarechy tunnels <account-id>
./bin/cloudflarechy workers <account-id>
./bin/cloudflarechy devmode <zone-id> on|off
./bin/cloudflarechy attack  <zone-id> on|off
./bin/cloudflarechy purge   <zone-id>
```

Reads are cached briefly under `~/.cache/cloudflarechy` (zones and Workers 5
minutes, overview and tunnels 1 minute) so a background poll and an open panel
do not each cost an API call. A leading `--fresh` skips the cache; writes drop
the entry for the zone they touched.

The running widget answers over IPC too:

```bash
omarchy-shell cloudflarechy status     # one line: zone, dev mode, attack, tunnels
omarchy-shell cloudflarechy refresh
omarchy-shell cloudflarechy toggle
```

## Notes

- Traffic comes from the GraphQL Analytics API (`httpRequests1hGroups`), which
  every plan can read. The REST dashboard endpoint it replaced is gone for new
  zones. If the plan rejects the `uniques` field, the query is retried without
  it rather than failing the whole graph.
- Editing this plugin's QML hot-reloads for most changes, but a bar widget that
  is already mounted can keep the old component; `omarchy restart shell` is the
  reliable way to see an edit.
- The cloud mark is drawn in QML, not Cloudflare's logo file. It follows your
  theme on the bar and goes orange in the panel header.
- The screenshot above was taken against a local stand-in API, so the zone,
  tunnels and Workers in it are invented.

## Uninstall

```bash
omarchy plugin disable cloudflarechy
rm -rf ~/.config/omarchy/plugins/cloudflarechy ~/.cache/cloudflarechy ~/.local/state/cloudflarechy
```

MIT licensed. Not affiliated with Cloudflare.
