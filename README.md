# Omarchy Routstr

An [Omarchy](https://omarchy.org) Quattro bar plugin that funds and wires [Routstr](https://routstr.com) so OpenCode (and other agents) can buy AI inference with Lightning or Cashu. No account, no KYC, no API-key dashboard.

**Status: v2 implemented (2026-08-16, tested against routstrd 0.3.11).** v1 shipped the bar widget, panel, Lightning top-up QR, OpenCode auto-wiring, and low-balance/daemon-down notifications. v2 adds paste-Cashu top-up, the mint list (+ add, + invoice targeting), explicit Claude Code / Pi / OpenClaw toggles with a correct disconnect, provider enable/disable, a copy-model-id dropdown, and a prepaid row in the first-party `omarchy.agents` panel. Not yet listed on omarchyplugins.com. The spec lives in [docs/DESIGN.md](docs/DESIGN.md); scope decisions in [docs/DECISIONS.md](docs/DECISIONS.md).

## What it is

A Tailscale-shaped front-end for the existing [`routstrd`](https://github.com/Routstr/routstrd) daemon.

- Bar: sats remaining, daemon up/down.
- Panel: top up with a Lightning QR (preset chips or a custom amount) or paste a `cashuA…` token, see and add mints, connect agents, toggle providers, copy model ids.
- Auto-integration: detect OpenCode (Omarchy’s default agent) and run `routstrd clients add --opencode` so models appear without editing `opencode.json` by hand. Claude Code, Pi, and OpenClaw are explicit toggles — Claude's is a takeover of its Anthropic login and says so before doing anything.
- A prepaid Routstr row in the first-party `omarchy.agents` panel (balance, spend, request history).

The plugin does **not** hold the Cashu mnemonic, does **not** proxy inference through `omarchy-shell`, and does **not** implement a chat UI. Spend stays in `routstrd` on `127.0.0.1:8008`. Agents talk to that local OpenAI-compatible endpoint.

## Install

```sh
omarchy plugin add https://github.com/babdbtc/omarchy-routstr.git --enable
```

Requires Omarchy Quattro, [Bun](https://bun.sh), and `routstrd`. `omarchy plugin add` never runs install hooks; the panel walks through daemon install/start/fund. Wallet onboarding (`routstrd onboard`) runs in a spawned terminal because it prints the mnemonic — that output never passes through `omarchy-shell`.

## Plugin id and IPC

`io.github.babdbtc.routstr`, IPC target `routstr`:

```sh
omarchy-shell routstr toggle      # open/close the panel
omarchy-shell routstr status      # one-line state
omarchy-shell routstr topup 2100  # Lightning invoice + QR in the panel
omarchy-shell routstr wire        # routstrd clients add --opencode
```

## Docs

| File | What it is |
| --- | --- |
| [docs/DESIGN.md](docs/DESIGN.md) | Product, architecture, v1/v2 scope, auto-integration |
| [docs/DECISIONS.md](docs/DECISIONS.md) | Alternatives we rejected and why |
| [manifest.json](manifest.json) | Quattro plugin contract |

## License

MIT. See [LICENSE](LICENSE).
