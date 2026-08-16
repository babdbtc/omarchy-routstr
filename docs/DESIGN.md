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
- `defaultTopupSats` (2100 — the amount IPC `topup` uses when called without one)

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
| Pi | Explicit toggle (v2) | Additive; the v2 connect rows replaced auto-wiring for everything but OpenCode. |
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

A wired row must answer *“can I go and use it now?”*, not *“did the write succeed?”* — the two come apart whenever the wallet is empty or the model list is, and a row that only says “Connected” leaves the user hunting for the missing step in the MODELS and PROVIDERS sections below, which are the two places they never need to touch. So a connected row reads **“Ready to use · <detail>”** once sats and models are both there, and names the blocker otherwise (`Model.agentReadyLabel`). Both facts are daemon-wide, so every row derives them from one place (`Panel.agentsUsable`).

**The label carries the state, in colour.** A wired row's subtitle is green when ready, `urgent` when a blocker is named, and `dim` while the daemon has not been polled yet; the mark beside it takes the same colour and changes shape (`󰄬` / `󰀦`) so the state still lands without colour. An unwired row's subtitle stays `dim` — it is describing itself, not making a claim.

One state function decides all three (`Model.agentState` → `ready` / `unknown` / `no-models` / `no-agent-models` / `no-funds`), so the label, the glyph and the colour cannot disagree. Two rules it encodes are worth stating, because both were bugs first:

- **A positive claim needs positive evidence.** `-1` means "not polled yet", and `noModelsAlert` treats an unknown as *not a failure* before it badges the bar — but the reverse does not follow. Service resets both counts to `-1` when the daemon drops, and the AGENTS section renders as soon as `daemonUp` flips, one round-trip before the balance lands. Reading `-1` as ready flashes a green all-clear over an empty wallet on every daemon start. `Service.qml`'s wired notification already gates on `balanceSats > 0` for the same reason.
- **Readiness is per-agent, not just daemon-wide.** `opencodeState` returns `wired: true, models: 0` for a provider block with no `models` key, so gating only on the daemon's count produced "Ready to use · 0 models" — in green, with a tick. Each row passes the count from its own config, or `-1` when it does not track one (Claude takes its three models positionally). `test/labels.test.mjs` walks every combination to assert a ready claim and a zero count can never co-occur.

The trailing text has two ranks, and the distinction is load-bearing. A **detail** describes the current config — a model count — and yields to a named blocker, since one elided line is better spent on what is wrong. A **note** is a standing warning about what wiring did to the machine: Claude Code's bypassed Anthropic login, the side effect its confirm dialog exists for. A note outranks both, and specifically outranks the blocker, because a blocker is recoverable and stateless while the side effect persists until Disconnect. It is also the answer to "why is this agent behaving strangely" — a question asked precisely when something else is wrong too. So in a blocked state the note *leads* (`Anthropic login bypassed · top up to use it`), where `ElideRight` cannot eat it. Claude is the only row with one.

The green is the plugin's own (`Panel.readyColor`), not the theme's, and that is deliberate rather than lazy. `Color` exposes no green role at all — only foreground / background / accent / urgent / muted — and the palettes underneath do not agree on what green is. The 22 shipped themes use a named `green` key, genuinely green in 13 and purple (`lupine` `#4a2fd0`), amber (`matte-black` `#FFC107`, whose `yellow` is `#b91c1c`, i.e. red) or flat grey (`vantablack`, `white`, `solitude`) in the rest. The themes installed here use the ANSI `color2` slot instead and define no `green` key at all — `rose-pine-moon`'s `color2` is `#3e8fb0`, the same teal as its accent — and `aether` ships no `colors.toml` whatsoever. Reaching past `Color` to parse the file would additionally go stale on every live theme switch, since those arrive over shell IPC and `Color.colorsFile` is deliberately `watchChanges: false`.

So: one value we control, in two variants picked by `Color.popups.background.hslLightness` — the surface the panel actually paints on (`KeyboardPanel`), not the foundational `background`, which a user `shell.toml` can diverge from. `#a6e3a1` reads at 11.9:1 on rose-pine-moon's `#191724` and collapses to 1.31:1 on catppuccin-latte's `#eff1f5`, so light themes get `#2d6a30` (5.8:1). The light variant is 10px caption text, so 4.5:1 is the bar it must clear rather than 3:1; `#2e7d32` cleared it by 0.03 and the next slightly darker light background would have failed. `urgent` stays theme-supplied — `Color.loadColors` takes it from `red`/`color1`, and this panel already spends it on the low-balance warning and OpenCode drift.

Corollary: the sections a connected user does *not* need lead with “Optional”, and the MODELS caption sits **above** its dropdown rather than below — a note underneath is read after the control has already been mistaken for a required step.

## Bar and panel

**Bar**

- Glyph + sats remaining, or a down/error mark.
- `hideBalance` on: glyph + state only. Sats in the bar leak in a community that screenshots its desktop constantly.
- Alerted (the bar's active/urgent styling) under `lowBalanceSats` — and on any keep-alive break: provider drift, model list empty.
- Left click: panel. Middle click: refresh.
- Right click (later): start/stop daemon, or new invoice. Unbound until then.

**Panel**

- Install / start state if the daemon is missing.
- Top-up chips: 210 / 2100 / 21k sats, plus a custom-amount field → Lightning QR from `POST /wallet/receive/bolt11`, plus paste `cashuA…` / `cashuB…` (the private path).
- Mint list with per-mint sats, add-mint, trust caveat; with >1 mint, rows pick where invoices land.
- Integrations list (above) with explicit Claude / Pi / OpenClaw toggles.
- Copy-`routstr/<id>` model dropdown; collapsed provider enable/disable list. Both marked optional — a connected agent already has every model, and routing already picks a provider.
- Now: model, last request cost (`/usage?limit=1`).
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

### v2 (implemented 2026-08-16, against routstrd 0.3.11)

- ~~Paste Cashu~~ — panel field in TOP UP posting to `/wallet/receive/cashu`. Token goes to curl over stdin, never argv or logs; the field clears before the request fires.
- ~~Mint picker / trust UI~~ — scoped to what the daemon has: list (`/wallet/mints` ∪ `/balance` map), add (`POST /wallet/mints`), trust caveat copy. There is **no set-default or remove surface** — the active mint is cocod's first listed mint. The one real choice is the `mintUrl` on `POST /wallet/receive/bolt11`, so with >1 mint the rows select where Lightning top-ups land.
- ~~Explicit Claude / Pi / OpenClaw toggles~~ — Connect rows per installed agent; Claude and OpenClaw confirm first (login hijack / default-model overwrite). Disconnect deletes the daemon client id, then jq-strips only our keys from the config (see DECISIONS.md "Surgical disconnect").
- ~~Model / provider picker~~ — resolved as: provider enable/disable (collapsed PROVIDERS section) plus a copy-`routstr/<id>` dropdown. routstrd has **no default-model surface** (`small_model` and the Claude env models are hardcoded or positional), so a picker would fight `refreshModelsAndIntegrations` and lie.
- ~~Prepaid tab in first-party `omarchy.agents`~~ — the service writes `routstr.json` into `~/.local/state/omarchy/agents/usage/` (atomic dotted-mktemp + mv, content-keyed dedupe across per-monitor instances), shaped like `omarchy-agent-usage-fireworks`: balance in currency `SAT`, `hasPromptStats: false` because requests are not prompts.
- Tor egress toggle — **dropped**: no daemon surface exists (see DECISIONS.md).

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

Hot reload: saving under `~/.config/omarchy/plugins/` reloads the *registry*, but a bar widget already mounted keeps running its old item (observed on 4.0.0.alpha; disable/enable does not replace it either). The reliable dev loop is `omarchy-restart-shell` (~2s). `omarchy-shell shell rescanPlugins` still helps for manifest-level changes.

Implementation findings (v1, 2026-08-15):

- Bar balance = wallet total (`/balance`) + `apikey:` session balances (`/keys/balance`) — matches the `routstrd balance` grand total. The two land in separate responses; debounce low-balance judgement until both settle.
- One bar surface exists per monitor, so every Service instance sees the same edge at once; notifications dedupe through an atomic `mkdir` guard in `$XDG_RUNTIME_DIR`.
- `routstrd start`/`stop` go through `Quickshell.execDetached` — holding them in a `Process` would tie the daemon's lifetime to the widget.
- All CLI calls run under `bash -lc` so Bun's global bin dir is on PATH inside `omarchy-shell`.
- Health polling is not gated on the CLI probe: a Docker routstrd answers on loopback with no `routstrd` on PATH. The CLI gates only actions (wire, start, stop).
- IPC target `routstr`: `open/close/toggle/refresh/status/topup [sats]/wire` — `topup` without an amount uses `defaultTopupSats`.
- Testable without routstrd: point a mock HTTP server at `127.0.0.1:8008` serving `/health`, `/balance`, `/keys/balance`, `/models`, `/usage`, `POST /wallet/receive/bolt11`.

Implementation findings (v2, 2026-08-16, routstrd 0.3.11):

- Response envelope: every management route wraps in `{output: ...}` except `/health`, `/v1/models`, and the proxy catch-all; errors are non-200 + `{error}`. For endpoints whose error message matters (cashu redeem), run curl without `-f` and parse the body — `-f` discards it.
- Mints: `/wallet/mints` is list/add/info only. The active mint is derived (cocod's first listed mint) and not settable; `/balance` carries `activeMint`.
- Clients: `clients delete` (CLI and `POST /clients/delete`) removes only the daemon record. It never cleans integration files, and the daemon rewrites wired configs every 21 minutes (`refreshModelsAndIntegrations`) for every client id in its store — so disconnect must delete the id first, then clean the file. Backups: one `.bak-routstr-<ts>` beside each config before the first write, same as OpenCode.
- Providers: `/providers` enable/disable is index-based and the list renumbers on Nostr refresh; resolve URL→index at POST time, never cache indices.
- Secrets over stdin: a Cashu token (money until redeemed) rides `curl -d @-` via `Process.write()` with `stdinEnabled` flipped off after the write to close the pipe — argv is world-readable in `/proc`. Same pattern as the network panel's Wi-Fi passphrase.
- Deploy loop: copying files into a live plugin dir triggers Quickshell hot reload, which segfaults in `IpcHandler::updateRegistration` (upstream bug, crash dialog per deploy). Kill the shell first: `quickshell kill -p /usr/share/omarchy/shell --any-display`, then cp, then `omarchy-restart-shell`.
- Keyboard: panels taller than the height cap need `onMoveRequested` to scroll the Flickable; inline TextFields and open dropdown popups must set `PanelKeyCatcher.blocked`.
- Usage record: `GET /usage/summary` (60s server cache) feeds the `omarchy.agents` record; the agents panel only rescans its directory when its own updater exits, so a brand-new record shows up after the next update cycle or shell restart.
- Lightning invoice QRs retire after 30 minutes — mint quotes expire, and a stale QR is a dead end.
- Number labels: group digits with U+00A0, never U+2009. The default bar font (`CaskaydiaCove Nerd Font`, via `fc-match monospace`) has no thin-space glyph, so Qt fell back for that one character and gave the line the fallback's metrics — at 12px, `21 000` measured 7.0px taller than `210`, 5.3px of it *below* the baseline, which floated the digits ~1.8px high inside every vertically centered label (visible the moment two amounts sit side by side). U+00A0 is in the font and measures identically to bare digits (±0.0px height, baseline, descent) for 5.7px more width per separator. Check `fc-list ':charset=<cp>'` before choosing a separator. The top-up chips additionally pin to one hidden reference chip, since differing digit counts still make the labels different widths.
- Top-up amounts are bounded in `Model.normalizeTopupSats` (1 … 21 000 000 sats): `invoiceSats` and the balance properties are QML ints, and past that a number is a typo. Chips, the custom field, and IPC `topup` all go through it.
- First-run default model: after `clients add --opencode` succeeds, a missing/empty top-level `model` is set to the `small_model` routstrd just wrote (its own cheap pick from /models) — jq, atomic, and a non-empty `model` is never touched.

Correctness findings (2026-08-16, from a review pass — see `test/`):

- `jq -e` has three non-zero answers, not one: 1 for "the result was false/null", 4 for "no output", **5 for a parse error**, and 127 when jq is absent. The Claude disconnect guard was `jq -e … || exit 0`, so an unreadable config and a missing jq both reported a clean disconnect — after `clients delete` had already revoked the key, leaving Claude Code broken *and* still bypassing the Anthropic login. Read the status into a `case`, and check `command -v jq` **before** the daemon delete so a machine that cannot finish never starts.
- One bar surface per monitor means auto-wire fires N times at once. The `mkdir` notification guard covers toasts; it did not cover the config write, so N concurrent `clients add --opencode` read-modify-wrote the same file. `Model.singleFlightFragment` is the same atomic-`mkdir` trick around the whole script: losers exit 75 (EX_TEMPFAIL) and pick the result up through the config watcher.
- Poll timeouts have to be per-process. A single one-shot watchdog armed by the first launch of a batch reaps curls that started seconds later — and a `/health` killed mid-flight is indistinguishable from a dead daemon, which empties the panel and fires a *critical* notification. `launch()` stamps each process with its own deadline; `pollWatchdog` sweeps. This also brought `wireProcess`/`clientProcess` under a timeout for the first time.
- Balance is two responses (`/balance` + `/keys/balance`) and they fail independently. Settling on a failed keys call counted the api-key float as zero, which read as a balance drop — and if a top-up was started in that window it captured the sunk figure as its baseline, so the next good poll looked like the invoice had been paid and cleared the QR on an unpaid mint quote. Only overwrite `_keysRaw` on success, and let an invoice created before any balance landed anchor its baseline on the first real reading instead of staying at -1 (which switched paid-detection off entirely).
- `Quickshell.execDetached` has no exit code, so the optimistic daemon toggle needs a deadline of its own or `_desiredDaemonUp` pins true forever on a failed start — a switch that lies, plus four extra polls a tick at a daemon that never came up.
- Invoice creation runs curl without `-f`, same as the cashu redeem: when the mint rejects an amount its `{error}` body is the only thing that tells the user what to change.

Tests: `node --test "test/*.test.mjs"`. `test/model.mjs` loads `Model.js` by stripping its one non-JS line (`.pragma library`), so the suite executes the exact script bytes the shell runs, against fixture configs and a stub daemon. Every finding above is covered by a test that fails against the old code.

Official contract: `shell/README.md` and `shell/plugins/README.md` in the [Omarchy repo](https://github.com/basecamp/omarchy/tree/quattro); the manifest schema’s source of truth is `shell/services/PluginRegistry.qml`. Plus the [develop guide](https://omarchyplugins.com/develop.html) and [first-party plugins](https://github.com/basecamp/omarchy/tree/quattro/shell/plugins). There is no `manual/32-shell-plugins.md` in the shipped 4.0 tree — do not cite it.

Closest first-party references (under `shell/plugins/`): `panels/tailscale` (`omarchy.tailscale` — Service.qml wrapping the CLI in `Process` objects with a poll watchdog; the shape to copy), `panels/clock` (`omarchy.clock` — bar-widget + nested panel), `agents` (`omarchy.agents` — prepaid display only, do not try to fund from there).
