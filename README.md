# Omarchy Routstr

An [Omarchy](https://omarchy.org) Quattro bar plugin that funds and wires [Routstr](https://routstr.com) so OpenCode (and other agents) can buy AI inference with Lightning or Cashu. No account, no KYC, no API-key dashboard.

**Status: design notes only.** The plugin is not implemented yet. This repo exists to hold the product spec, the plugin contract, and the decisions from the first planning pass (2026-08-15).

## What it is

A Tailscale-shaped front-end for the existing [`routstrd`](https://github.com/Routstr/routstrd) daemon.

- Bar: sats remaining, daemon up/down.
- Panel: top up with a Lightning QR, paste a `cashuA…` token, connect agents.
- Auto-integration: detect OpenCode (Omarchy’s default agent) and run `routstrd clients add --opencode` so models appear without editing `opencode.json` by hand.

The plugin does **not** hold the Cashu mnemonic, does **not** proxy inference through `omarchy-shell`, and does **not** implement a chat UI. Spend stays in `routstrd` on `127.0.0.1:8008`. Agents talk to that local OpenAI-compatible endpoint.

## Planned install (once it ships)

```sh
omarchy plugin add https://github.com/babdbtc/omarchy-routstr.git --enable
```

Requires Omarchy Quattro, [Bun](https://bun.sh), and `routstrd`. `omarchy plugin add` never runs install hooks; the panel walks through daemon install/start/fund. Wallet onboarding (`routstrd onboard`) runs in a spawned terminal because it prints the mnemonic — that output never passes through `omarchy-shell`.

## Planned plugin id

`io.github.babdbtc.routstr`

## Docs

| File | What it is |
| --- | --- |
| [docs/DESIGN.md](docs/DESIGN.md) | Product, architecture, v1/v2 scope, auto-integration |
| [docs/DECISIONS.md](docs/DECISIONS.md) | Alternatives we rejected and why |
| [manifest.json](manifest.json) | Quattro plugin contract (not loadable until QML exists) |

## License

MIT. See [LICENSE](LICENSE).
