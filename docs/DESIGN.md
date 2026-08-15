# Design

Captured 2026-08-15 after Omarchy 4.0 (Quattro) shipped. Source conversation: first plugin idea (Bitcoin / Monero / Cashu / Lightning / Tor) → Routstr as the intersection of those rails with Omarchy’s AI-first desktop → auto-wiring OpenCode so the user never edits agent config by hand.

Verified 2026-08-15 against the shipped Quattro tree (`$OMARCHY_PATH`, 4.0.0.alpha — manifest schema, tooling, agents usage dir) and routstrd `main` (`src/cli.ts` — command surface, onboard output, service subcommands).

This file is the spec. Implement against it. Change it when the product changes.

## Problem

Omarchy already is an AI desktop: OpenCode (`c`), Claude Code (`cx`), `omarchy.agents`, and a marketplace full of *usage* widgets for people who already have a subscription.

Getting inference still means creating an account, a credit card or prepaid dashboard, and pasting an API key. Routstr already solves that protocol-side (Cashu / Lightning, OpenAI-compatible). The remaining hole on Omarchy is **fuel + wiring**:

1. Is `routstrd` installed and running?
2. Is there a balance?
3. Are OpenCode / Pi / others pointed at `localhost:8008` with a fresh model list?

Without a widget, that is a Bun install, an onboard command, a Lightning invoice in a TUI, and a `clients add` the user has to remember. That is the bounce.

## Product sentence

Enable the widget, pay a Lightning invoice, press `c`. Models are just there.

True from the second session on. The first session includes a one-time terminal detour (install Bun + `routstrd`, run `onboard`) that the panel walks through but must not perform itself.

## Why Routstr, not a wallet or Tor

The marketplace (~208 community plugins listed on [omarchyplugins.com](https://omarchyplugins.com) as of 2026-08-15, plus first-party) already has:

| Nearby | Why it is not this |
| --- | --- |
| `omarchy.tailscale` | The *shape* to copy (bar + panel + local CLI). Not the job. |
| WireGuard + ~7 VPN widgets | Commercial / corporate VPNs. No Tor. |
| [Omastonk](https://github.com/brianblakely/omastonk) | Market quotes. BTC-USD will land there. |
| [Portfolio Tracker](https://github.com/paul-paliychuk/omarchy-portfolio-tracker) | Local ledger + Yahoo quotes. |
| `omarchy.agents` + many usage widgets | Display-only. Assume you already paid OpenAI / Anthropic / Fireworks. |

Empty as of 2026-08-15: Bitcoin, Lightning, Cashu, Monero, Tor, mempool, Routstr.

A generic wallet in the bar is the wrong runtime. Quattro plugins are unsandboxed QML inside the long-lived `omarchy-shell` process and update by `git pull`. Spend keys do not belong there.

Routstr is the job the desktop already has: keep the coding agent funded and pointed at a working model. Cashu and Lightning are the rail, not the product. Tor can be a later egress toggle on the daemon.

## Architecture

```
┌─────────────────────────────┐
│  OpenCode / Claude / Pi     │  talks OpenAI API to localhost
└──────────────┬──────────────┘
               │  http://127.0.0.1:8008
┌──────────────▼──────────────┐
│  routstrd                   │  discovers providers on Nostr,
│  ~/.routstrd/wallet/        │  pays per request, holds mnemonic
└──────────────┬──────────────┘
               │  Cashu / Lightning
               ▼
         Routstr nodes

┌─────────────────────────────┐
│  this plugin (QML)          │  bar + panel + service
│  talks only to routstrd     │  never opens the wallet dir
└─────────────────────────────┘
```

Reuse [`routstrd`](https://github.com/Routstr/routstrd). Do not reimplement the protocol, the wallet, or the per-client config writers.

Useful daemon commands:

```sh
routstrd onboard                   # prints the wallet mnemonic — terminal only, never from the shell
routstrd start | stop | status | balance | usage | models
routstrd service install           # persistence via PM2; `pm2 startup` + `pm2 save` are the user’s (sudo)
routstrd receive 2100              # Lightning invoice
routstrd receive '<cashuA...>'     # paste token
routstrd clients add --opencode    # also: --claude-code --pi-agent --openclaw --hermes
```

For state, prefer the daemon’s JSON endpoints on `127.0.0.1:8008` — `/health`, `/balance`, `/models`, `/usage` — over parsing CLI text. CLI for actions, API for polling. `routstrd` is v0.x and its CLI drifts ahead of its own README: record the version this plugin was tested against and feature-detect anything newer.

Daemon default: `127.0.0.1:8008`. Config: `~/.routstrd/config.json`. Wallet: `~/.routstrd/wallet/` (migrated from `~/.cocod/` if present). Default mint today: `https://mint.cubabitcoin.org`.

`routstrd` already writes agent configs and refreshes models on a timer (`refreshModelsAndIntegrations`). The plugin registers the client once and then watches health.

## Plugin contract

| Field | Value |
| --- | --- |
| id | `io.github.babdbtc.routstr` |
| kinds | `bar-widget` (add `service` if polling should outlive the widget) |
| entry | `BarWidget.qml` loads `Panel.qml` |
| default section | `right` |
| allowMultiple | `false` |
| clone-from shape | `omarchy.tailscale` / `omarchy.clock` |

Settings (planned):

- `refreshIntervalSec` (default 30)
- `lowBalanceSats` (bar goes red / notify)
- `hideBalance` (default false — bar shows glyph and state only)
- `autoWireOpencode` (default true)
- `defaultTopupSats` (2100)

Distribution: one public git repo, `manifest.json` + README + LICENSE at root, list on [omarchyplugins.com](https://omarchyplugins.com). `omarchy plugin add` clones files only. It never runs an install hook and never asks for sudo.

## Auto-integration

This is the product. Do not hand-edit `opencode.json` from QML. Call `routstrd`. Their format (`@ai-sdk/openai-compatible`, `includeUsage`, model ids, `small_model`) will drift.

### What `routstrd` already writes

OpenCode (`~/.config/opencode/opencode.json`) — **additive**:

```json
{
  "provider": {
    "routstr": {
      "npm": "@ai-sdk/openai-compatible",
      "name": "routstr",
      "options": {
        "baseURL": "http://127.0.0.1:8008/",
        "apiKey": "sk-…",
        "includeUsage": true
      },
      "models": { "<id>": { "name": "<name>" } }
    }
  },
  "small_model": "routstr/minimax-m2.5"
}
```

Pi (`~/.pi/agent/models.json`) — **additive** `providers.routstr`.

Claude Code (`~/.claude/settings.json`) — **hijack**:

```json
{
  "env": {
    "ANTHROPIC_AUTH_TOKEN": "sk-…",
    "ANTHROPIC_BASE_URL": "http://127.0.0.1:8008",
    "ANTHROPIC_DEFAULT_OPUS_MODEL": "…",
    "ANTHROPIC_DEFAULT_SONNET_MODEL": "…",
    "ANTHROPIC_DEFAULT_HAIKU_MODEL": "…"
  }
}
```

That replaces the user’s Anthropic login. Never auto-enable.

### Agent policy

Omarchy can install: `pi`, `omp`, `opencode`, `claude`, `codex`, `grok`, `gemini`, `copilot`, `crush` (`omarchy-default-agent`).

`routstrd` only knows: OpenCode, Claude Code, Pi, OpenClaw, Hermes.

| Agent | Auto-wire? | Why |
| --- | --- | --- |
| OpenCode | Yes, if installed | Omarchy default. Additive provider. |
| Pi | Yes, if `~/.pi/agent` exists | Additive. |
| Claude Code | Offer only, explicit toggle | Overwrites Anthropic env. Copy must say so. |
| OpenClaw / Hermes | Offer if present | Do not assume. |
| Grok, Codex, Gemini, Copilot, Crush | Skip | No `routstrd` integration. Faking it breaks them. |

Never flip `omarchy-default-agent`. If they picked Claude, they picked Claude.

Never overwrite a non-empty `"model"` or `"small_model"` in OpenCode. This machine already has Ollama and an OpenAI OAuth block; add `provider.routstr` beside them.

Backup the target file once before the first write: `opencode.json.bak-routstr-<timestamp>`. `omarchy-refresh-*` can restore stock OpenCode config; Repair must survive that.

### First-run

```
plugin enabled
  → routstrd missing?   show install (Bun + `bun i -g routstrd`). do not curl|sh, do not sudo
  → never onboarded?    spawn a terminal running `routstrd onboard`. onboard prints the
                        wallet mnemonic to stdout; that output must never pass through
                        omarchy-shell (see hard rules)
  → daemon down?        `routstrd start`. offer “start on boot” in a terminal:
                        `routstrd service install`, then `pm2 startup` + `pm2 save`
                        (startup emits a sudo command — the user runs it, never the plugin)
  → balance 0?          Lightning QR (`routstrd receive N`). still wire the provider
  → OpenCode present?   `routstrd clients add --opencode`
  → no default model?   set `model` to a cheap coding id from /models
  → notify              “OpenCode has N Routstr models.”
```

Wire before fund. An unfunded but wired agent fails as “top up,” not “no provider configured.”

### Keep-alive

Do not rewrite JSON from the plugin every 30 seconds. Register once. `routstrd` already refreshes models.

The plugin only watches (via the JSON endpoints, not CLI scraping):

- daemon up
- `provider.routstr` still in the config
- model count not zero
- balance above `lowBalanceSats`

If any of those break: badge the bar, show Repair. If the user deleted the provider on purpose: one toast, then leave it off.

Disconnect removes only the `routstr` provider key (or the Claude env overrides). Leave every other provider alone.

### Integrations UI

One section, not a wizard. Each row: name, installed / missing, connected / stale / off, last model count.

Primary action for v1: **Connect OpenCode**. Claude is a toggle: “Routes Claude Code through Routstr instead of Anthropic.”

## Bar and panel

**Bar**

- Glyph + sats remaining, or a down/error mark.
- `hideBalance` on: glyph + state only. Sats in the bar leak in a community that screenshots its desktop constantly.
- Red under `lowBalanceSats`.
- Left click: panel.
- Right click (later): start/stop daemon, or new invoice.

**Panel**

- Install / start state if the daemon is missing.
- Top-up chips: 210 / 2100 / 21k sats → Lightning QR from `routstrd receive N`.
- Optional paste `cashuA…` / `cashuB…`.
- Integrations list (above).
- Now: provider, model, last request cost (`routstrd usage`).
- Low-balance copy that points at the QR, not at a docs page.

**Service** (if needed)

- Poll `GET /health` / `/balance` on `127.0.0.1:8008`.
- Notify when the daemon dies or the next request will not clear.

## Security and honesty

Plugins run unsandboxed as the user, inside `omarchy-shell`, for the whole session (`omarchy-plugin-add` warns exactly this). Assume marketplace review is not an audit.

Hard rules:

- Never open `~/.routstrd/wallet/` or display a mnemonic.
- Never run `routstrd onboard` from the shell process. `onboard` prints the mnemonic to stdout; a QML `Process` capturing it holds the seed in a property. Spawn a terminal and never read its output.
- Never invoke secret-printing commands: `routstrd history --verbose` (encoded Cashu tokens), `routstrd balance --api-keys` (raw keys).
- Never keep `cashuA…` tokens in QML properties or logs.
- Never put the wallet seed in agent configs. The per-client `sk-` key is what `routstrd` already writes.
- Bind assumptions: daemon on loopback only.
- Do not `curl | bash`, do not `cargo install --git` unpinned, do not passwordless sudo. `omarchy plugin add` cannot run install hooks anyway, and any review process will flag those patterns.
- Surface mint trust. Default mint is `mint.cubabitcoin.org`. Cashu is mint-trusted, not trustless Bitcoin.

“No signup” is true. “Anonymous” is not, unless qualified:

- Cashu trusts the mint.
- `apikeys` mode (current default) parks a session balance on the node and refunds later. `xcashu` (bearer per request) is still “coming soon” in routstrd.
- Lightning invoices leak metadata. Token paste is the private path.
- The provider still sees the prompt. Payment privacy ≠ inference privacy.
- The user still installs software. The plugin cannot conjure a funded wallet from QML.

## Scope

### v1

1. Detect `routstrd` / talk to `:8008`.
2. Bar: balance + daemon state.
3. Lightning top-up QR.
4. Auto-wire OpenCode (`clients add --opencode`) + Repair if the provider block disappears.
5. Low-balance notification.

Ship that. Use it for a week.

### v2

- Model / provider picker that does not fight `routstrd`’s refresh.
- Paste Cashu.
- Explicit Claude / Pi / OpenClaw toggles.
- Tor egress toggle on the daemon (not transparent proxy of the whole desktop).
- Prepaid tab in first-party `omarchy.agents`: the plugin service writes usage records straight into `~/.local/state/omarchy/agents/usage/` — the panel accepts records from any writer. A collector binary does not work: `omarchy-agent-usage-update` only discovers `omarchy-agent-usage-*` in root-owned `$OMARCHY_PATH/bin`. Copy the record shape from `omarchy-agent-usage-fireworks`, the prepaid precedent.
- Mint picker / trust UI.

### Out of scope

- Chat overlay. Omarchy users live in the terminal agent.
- In-process spend wallet.
- Price ticker (Omastonk).
- Reimplementing `routstrd`.
- Auto-wiring Grok / Codex / Gemini / Copilot / Crush.
- Changing the user’s default Omarchy agent.
- Transproxy / system-wide Tor in v1.

## Implementation notes

Start local development by cloning a built-in, then replace the id:

```sh
omarchy plugin clone omarchy.tailscale --edit
```

The clone auto-enables and replaces the built-in Tailscale widget while you work; disable or remove it when done.

Or drop this repo into `~/.config/omarchy/plugins/io.github.babdbtc.routstr/` (or `omarchy plugin add` against the git remote) once QML exists.

Validate:

```sh
omarchy plugin validate .
qmllint -I "$OMARCHY_PATH/shell" BarWidget.qml Panel.qml
```

`omarchy plugin validate` is the real gate (schema, entry-point files exist, no symlinks). `qmllint` cannot resolve Quickshell imports from that include path — treat its unresolved-import warnings as noise, not failures.

Hot reload: saving under `~/.config/omarchy/plugins/` reloads the plugin. Force: `omarchy-shell shell rescanPlugins`.

Official contract: `shell/README.md` and `shell/plugins/README.md` in the [Omarchy repo](https://github.com/basecamp/omarchy/tree/quattro); the manifest schema’s source of truth is `shell/services/PluginRegistry.qml`. Plus the [develop guide](https://omarchyplugins.com/develop.html) and [first-party plugins](https://github.com/basecamp/omarchy/tree/quattro/shell/plugins). There is no `manual/32-shell-plugins.md` in the shipped 4.0 tree — do not cite it.

Closest first-party references (under `shell/plugins/`): `panels/tailscale` (`omarchy.tailscale` — Service.qml wrapping the CLI in `Process` objects with a poll watchdog; the shape to copy), `panels/clock` (`omarchy.clock` — bar-widget + nested panel), `agents` (`omarchy.agents` — prepaid display only, do not try to fund from there).
