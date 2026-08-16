# Omarchy Routstr

An [Omarchy](https://omarchy.org) Quattro bar plugin that funds and wires [Routstr](https://routstr.com) so OpenCode (and other agents) can buy AI inference with Lightning or Cashu. No account, no KYC, no API-key dashboard.

**Status: v2 implemented (2026-08-16, tested against routstrd 0.3.11).** v1 shipped the bar widget, panel, Lightning top-up QR, OpenCode wiring, and low-balance/daemon-down notifications. v2 adds paste-Cashu top-up, the mint list (+ add, + invoice targeting), explicit Claude Code / Pi / OpenClaw toggles with a correct disconnect, provider enable/disable, a copy-model-id dropdown, and a prepaid row in the first-party `omarchy.agents` panel. Not yet listed on omarchyplugins.com. The spec lives in [docs/DESIGN.md](docs/DESIGN.md); scope decisions in [docs/DECISIONS.md](docs/DECISIONS.md).

![The Routstr panel open under the bar widget: 205 sats, daemon running, 20 models. Top-up chips and a Cashu redeem field, the active mint, then agent rows — OpenCode ready to use with 20 models, Claude Code and Pi offering Connect.](preview.png)

## What it is

A Tailscale-shaped front-end for the existing [`routstrd`](https://github.com/Routstr/routstrd) daemon.

- Bar: sats remaining, daemon up/down.
- Panel: top up with a Lightning QR (preset chips or a custom amount) or paste a `cashuA…` token, see and add mints, connect agents, toggle providers, copy model ids.
- Integration: one click runs `routstrd clients add --opencode`, so models appear without editing `opencode.json` by hand. Claude Code, Pi, and OpenClaw are explicit toggles too — Claude's is a takeover of its Anthropic login and says so before doing anything. Nothing under `~/.config` is written until you press Connect; the `autoWireOpencode` setting opts into doing it unattended.
- A prepaid Routstr row in the first-party `omarchy.agents` panel (balance, spend, request history).

The plugin does **not** hold the Cashu mnemonic, does **not** proxy inference through `omarchy-shell`, and does **not** implement a chat UI. Spend stays in `routstrd` on `127.0.0.1:8008`. Agents talk to that local OpenAI-compatible endpoint.

## Install

```sh
omarchy plugin add https://github.com/babdbtc/omarchy-routstr.git --enable
```

Requires Omarchy Quattro, [Bun](https://bun.sh), and `routstrd`. It also shells out to `curl`, `jq`, `qrencode`, `wl-copy`, `notify-send`, and `omarchy-launch-terminal` — all Omarchy base, so this only bites on a stripped system. Where the plugin reads a result (`curl`, `jq`, `qrencode`) the panel names the missing tool instead of failing sideways; the fire-and-forget ones (copy, toast, spawn a terminal) just do nothing. `omarchy plugin add` never runs install hooks and never asks for sudo; the panel walks through daemon install/start/fund. Wallet onboarding (`routstrd onboard`) runs in a spawned terminal because it prints the mnemonic — that output never passes through `omarchy-shell`.

## What it writes

| Path | When | What |
| --- | --- | --- |
| `~/.config/opencode/opencode.json` | Connect OpenCode | `routstrd` merges `provider.routstr`. Additive; a non-empty `model` / `small_model` is never clobbered. |
| `~/.claude/settings.json` | Connect Claude Code | `routstrd` sets `ANTHROPIC_BASE_URL` / `ANTHROPIC_AUTH_TOKEN`. This replaces your Anthropic login until you disconnect — the panel confirms first. |
| `~/.pi/agent/models.json`, `~/.openclaw/openclaw.json` | Connect Pi / OpenClaw | Additive `providers.routstr`. |
| `<file>.bak-routstr-<timestamp>` | Once, before the first write to each config above | Untouched copy of your original. |
| `~/.local/state/omarchy/agents/usage/routstr.json` | Daemon up and answering | Balance and spend, so Routstr shows as a prepaid row in the first-party `omarchy.agents` panel. State, not config. |
| `$XDG_RUNTIME_DIR/omarchy-routstr*` | Top-up, wiring, notifications | Invoice QR (`-invoice.png`), a single-flight lock dir, and per-minute toast-dedupe guards (one bar surface exists per monitor). Cleared on close or reboot. |

The wallet lives in `routstrd`. This plugin never reads, stores, or prints the mnemonic.

## Remove

Disconnect first, then remove — the plugin is the only UI that can clean up the configs it wrote.

```sh
# 1. In the panel, press Disconnect on every connected agent. That deletes
#    the daemon-side key and strips only Routstr's keys from each config —
#    Claude Code stops routing here and goes back to its own login.
# 2. Then:
omarchy plugin remove io.github.babdbtc.routstr
rm -f "${XDG_STATE_HOME:-$HOME/.local/state}/omarchy/agents/usage/routstr.json"  # drops the prepaid row
```

Disconnect deletes our keys rather than restoring yours — if you had hand-written `ANTHROPIC_*` env values before connecting, they are in the `.bak-routstr-*` copy, not in the live file.

Removing the plugin first is recoverable but manual: `routstrd clients list` / `routstrd clients delete <id>`, then drop `provider.routstr` from `opencode.json` (and the `ANTHROPIC_*` keys from `~/.claude/settings.json`) by hand. Left in place, those configs point at `127.0.0.1:8008` and start failing the moment the daemon stops.

The daemon and wallet outlive the plugin — uninstalling them is `routstrd`'s business, not this widget's. Sweep or record your balance before touching either: the wallet holds real money, and this plugin never had the mnemonic to back up for you.

## Plugin id and IPC

`io.github.babdbtc.routstr`, IPC target `routstr`:

```sh
omarchy-shell routstr toggle      # open/close the panel
omarchy-shell routstr status      # one-line state
omarchy-shell routstr topup 2100  # Lightning invoice + QR in the panel
omarchy-shell routstr wire        # routstrd clients add --opencode
```

## Tests

```sh
node --test "test/*.test.mjs"
```

`Model.js` is a QML `.pragma library` of pure functions, including the text of
every shell script the plugin runs. The suite strips that one non-JS line and
executes those exact bytes against fixture agent configs and a stub daemon —
so a disconnect that silently fails to clean `~/.claude/settings.json` is a
test failure, not a support ticket.

## Docs

| File | What it is |
| --- | --- |
| [docs/DESIGN.md](docs/DESIGN.md) | Product, architecture, v1/v2 scope, auto-integration |
| [docs/DECISIONS.md](docs/DECISIONS.md) | Alternatives we rejected and why |
| [manifest.json](manifest.json) | Quattro plugin contract |
| [test/](test/) | The shell scripts, executed against fixtures, plus the pure label logic |

## License

MIT. See [LICENSE](LICENSE).
