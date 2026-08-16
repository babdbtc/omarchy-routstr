# Omarchy Routstr

An [Omarchy](https://omarchy.org) Quattro bar plugin that funds [Routstr](https://routstr.com) and wires it into OpenCode, so your agents can buy AI inference with Lightning or Cashu. No account, no KYC, no API-key dashboard.

Not affiliated with Routstr. It drives their [`routstrd`](https://github.com/Routstr/routstrd) daemon, nothing more. v2, built and used against routstrd 0.3.11.

![The Routstr panel open under the bar widget, showing 205 sats, top-up amounts, the active mint, and agent rows for OpenCode, Claude Code and Pi.](preview.png)

## What it is

A Tailscale-shaped front end for a daemon that already exists.

The bar shows sats remaining and whether `routstrd` is up. The panel does the rest: top up with a Lightning QR or paste a `cashuA…` token, see which mint holds your balance, connect agents, toggle providers, copy model ids.

Connecting is one click. It runs `routstrd clients add --opencode`, and the models show up in OpenCode. Claude Code, Pi and OpenClaw get their own buttons. Claude's is a takeover of your Anthropic login, so it asks first.

Nothing in `~/.config` is touched until you press Connect.

Spend stays in `routstrd` on `127.0.0.1:8008`, where agents talk to a local OpenAI-compatible endpoint. The plugin never holds the Cashu mnemonic, never proxies inference through `omarchy-shell`, and has no chat UI. Routstr also shows up as a prepaid row in the first-party `omarchy.agents` panel.

## Install

```sh
omarchy plugin add https://github.com/babdbtc/omarchy-routstr.git --enable
```

You need Omarchy Quattro, [Bun](https://bun.sh) and `routstrd`. The panel walks you through installing and starting the daemon. It prints the commands and you run them, because `omarchy plugin add` cannot run install hooks and this plugin never asks for sudo. Onboarding (`routstrd onboard`) opens a terminal, since it prints your wallet mnemonic and that must never pass through `omarchy-shell`.

It also calls `curl`, `jq`, `qrencode`, `wl-copy`, `notify-send` and `omarchy-launch-terminal`. Those are all Omarchy base packages, so this only bites on a stripped system. Where the plugin reads a result, the panel tells you which tool is missing. Copy, toast and terminal-spawn are fire-and-forget, so they just do nothing.

## What it writes

| Path | When, and what lands there |
| --- | --- |
| `~/.config/opencode/opencode.json` | Connect OpenCode. `routstrd` merges in `provider.routstr`. A `model` or `small_model` you already picked is left alone. |
| `~/.claude/settings.json` | Connect Claude Code. `ANTHROPIC_BASE_URL` and `ANTHROPIC_AUTH_TOKEN`, which replace your Anthropic login until you disconnect. |
| `~/.pi/agent/models.json`, `~/.openclaw/openclaw.json` | Connect Pi or OpenClaw. Adds `providers.routstr`. |
| `<file>.bak-routstr-<timestamp>` | Once, before the first write to any config above. |
| `~/.local/state/omarchy/agents/usage/routstr.json` | Whenever the daemon answers. Balance and spend, for the `omarchy.agents` panel. |
| `$XDG_RUNTIME_DIR/omarchy-routstr*` | Invoice QR and lock files. Gone on reboot. |

The wallet lives in `routstrd`. This plugin never reads, stores or prints the mnemonic.

## Remove

Disconnect your agents in the panel first. Once the plugin is gone, so is the only UI that can clean up after it.

```sh
omarchy plugin remove io.github.babdbtc.routstr
rm -f "${XDG_STATE_HOME:-$HOME/.local/state}/omarchy/agents/usage/routstr.json"
```

Disconnect deletes the daemon-side key, then strips Routstr's keys back out of each config, and Claude Code returns to its own login. It removes our keys rather than restoring yours, so if you hand-wrote `ANTHROPIC_*` values before connecting, look in the `.bak-routstr-*` copy beside the file.

Do it in the other order and the cleanup is manual: `routstrd clients delete <id>`, then take `provider.routstr` out of `opencode.json` yourself. Skip that and those configs keep pointing at a daemon that has stopped answering.

The daemon and the wallet outlive the plugin, and removing them is `routstrd`'s business. Sweep your balance first. It is real money, and this plugin never had the mnemonic to back up for you.

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

`Model.js` is a QML `.pragma library` of pure functions, and it holds the text of every shell script the plugin runs. The suite strips that one non-JS line and executes those exact bytes against fixture agent configs and a stub daemon. A disconnect that silently fails to clean `~/.claude/settings.json` is a test failure, not a support ticket.

## Docs

[docs/DESIGN.md](docs/DESIGN.md) is the spec: product, architecture, scope, how integration works. [docs/DECISIONS.md](docs/DECISIONS.md) covers what we rejected and why. [manifest.json](manifest.json) is the Quattro contract, and [test/](test/) holds the fixtures.

## License

MIT. See [LICENSE](LICENSE).
