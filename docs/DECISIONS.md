# Decisions

Why this plugin is this plugin, and not the other things we considered.

## Rejected products

### Bitcoin / Monero / Lightning / Cashu wallet in the bar

Empty niche, bad shape. The shell process is unsandboxed and updates by git pull. A later commit, or a bug that logs QML properties, drains funds. Cashu is the worst case: the token *is* the money.

If money ever appears in the bar it is a dashboard for a daemon that already exists (readonly macaroon, view-only RPC, Nutshell/CDK sidecar). Spend stays out of QML.

### Price ticker

[Omastonk](https://github.com/brianblakely/omastonk) already does multi-instance quotes and charts. [Portfolio Tracker](https://github.com/paul-paliychuk/omarchy-portfolio-tracker) already does a local ledger. BTC-USD is not a new plugin.

### Mempool / fee widget / node status

Honest, no keys, distinct from Omastonk. Smaller audience than “make OpenCode work,” and it does not use Omarchy’s AI identity. Fine as a later row inside this panel if `bitcoind` / LND is on localhost. Not v1.

### Tor status widget

Best *generic* first plugin: Tailscale-shaped, empty niche, seven VPN widgets already exist and Tor does not. Broader audience than node runners.

Dropped as the *first* ship because it is a status light. Routstr is a job users already have (buy inference). Tor becomes a v2 egress toggle on `routstrd`, not a separate product.

### Sovereign-stack mega plugin (Tor + node + LN + Cashu + chat)

Unshippable. v1 is only Routstr + OpenCode wiring.

### Chat overlay / Routstr Chat clone

[`routstr-chat`](https://github.com/Routstr/routstr-chat) and the terminal agents already exist. Omarchy users live in `c` / `cx`. The missing piece is fuel, not another composer.

### Fold everything into `omarchy.agents`

That widget is display-only. It reads usage JSON from `~/.local/state/omarchy/agents/usage/`. A collector is a good v2 extra (Fireworks is the prepaid precedent). It cannot onboard, invoice, or wire OpenCode.

### Reimplement integration by writing `opencode.json` from QML

`routstrd clients add --opencode` already merges the provider, sets `includeUsage`, fills models from `/models`, and refreshes on a schedule. Hand-rolling that in QML will drift. The plugin calls the CLI and repairs if the block disappears.

## Rejected implementation choices

### Run `routstrd onboard` from the panel

`onboard` prints the wallet mnemonic to stdout (`initializeWallet` in routstrd’s `cli.ts`). A QML `Process` capturing that output holds the seed in shell memory — exactly what the hard rules forbid. The panel spawns a terminal for onboarding and never reads its output. Same rule for anything secret-printing: `history --verbose` (encoded Cashu tokens), `balance --api-keys` (raw keys).

### Poll by scraping CLI text

The daemon serves JSON on loopback: `/health`, `/balance`, `/models`, `/usage`. The CLI’s human output is v0.x and already drifts ahead of its own README. CLI for actions (`start`, `receive`, `clients add`), API for state — and record the routstrd version the plugin was tested against.

### Run `pm2 startup` from the plugin

`routstrd service install` wraps the daemon in PM2 (installing PM2 via Bun if missing — user-level, acceptable). Boot persistence additionally needs `pm2 startup`, which emits a sudo command. That belongs to the user in the spawned terminal, never to the plugin.

### Ship an `omarchy-agent-usage-routstr` collector binary (v2)

`omarchy-agent-usage-update` discovers collectors only by globbing `$OMARCHY_PATH/bin/omarchy-agent-usage-*` — root-owned, closed to third parties. The agents panel accepts any record dropped in `~/.local/state/omarchy/agents/usage/`, so the plugin service writes the record itself, shaped like `omarchy-agent-usage-fireworks` output.

## Rejected auto-integration behaviors

### Auto-wire Claude Code

`routstrd`’s Claude integration overwrites `ANTHROPIC_BASE_URL` and `ANTHROPIC_AUTH_TOKEN`. That is a hijack of a paid Anthropic login. Explicit toggle only, with copy that says so.

### Auto-set OpenCode `"model"` / `"small_model"` when already set

`routstrd` currently sets `small_model` to `routstr/minimax-m2.5`. This plugin must not clobber an existing choice. This machine already has Ollama and OpenAI OAuth. Add `provider.routstr`. Leave the default model alone unless it is empty.

### Auto-change `omarchy-default-agent`

The user picked an agent. Wiring Routstr as a *provider* is enough.

### Fake Grok / Codex / Gemini / Copilot / Crush providers

Omarchy can install those. `routstrd` cannot configure them. Skip rather than write a broken `baseURL`.

### Silent rewrite of agent config every poll

Register the client once. Let `routstrd` refresh models. The plugin only detects drift and offers Repair.

### Curl-pipe or sudo installer for Bun / routstrd

Assume any marketplace review flags `curl-pipe-shell`, unpinned git installs, and passwordless sudo — and `omarchy plugin add` cannot run install hooks anyway. Show the commands. Do not execute a privileged installer from the plugin.

## Honest language

Do not market this as “anonymous” without the mint / session / prompt caveats in [DESIGN.md](DESIGN.md). “No account, pay-per-request” is the accurate claim.
