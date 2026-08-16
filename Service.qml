import QtQuick
import Quickshell
import Quickshell.Io
import qs.Commons
import "Model.js" as Model

// All routstrd state and actions, one instance per bar surface.
//
// State comes from the daemon's JSON endpoints on 127.0.0.1:8008 (curl, the
// shell's house pattern for HTTP). Actions go through the routstrd CLI under
// `bash -lc` so Bun's global bin dir is on PATH regardless of the shell
// process environment.
//
// Hard rules from docs/DESIGN.md this file enforces:
//   - `routstrd onboard` runs in a spawned terminal, output never captured
//     (it prints the wallet mnemonic).
//   - no secret-printing commands (`history --verbose`, `balance --api-keys`).
//   - agent configs are merged only by `routstrd clients add`; around that,
//     this service backs each file up once before the first write, copies
//     small_model into an empty OpenCode `model` once after a successful
//     add, and surgically strips our keys on disconnect. It never edits
//     routstrd's provider block by hand.
Item {
  id: root
  visible: false

  property var settings: ({})
  property bool panelOpen: false

  // ---- Probed environment
  property bool probed: false
  property bool installed: false
  property bool onboarded: false
  property bool bunInstalled: false
  property bool opencodeInstalled: false

  // ---- Daemon state
  property bool daemonUp: false
  property int balanceSats: -1
  property int modelCount: -1
  property var lastUsage: null
  property bool refreshing: false

  // ---- Mints. The active mint is cocod's first listed mint — routstrd has
  // no set-default or remove surface (verified against 0.3.11). The only
  // real choice is which mint a Lightning invoice mints into, so that is
  // the choice this exposes; empty means the daemon default.
  property string activeMint: ""
  property var mintRows: []
  property string topupMintUrl: ""
  property string _mintsRaw: ""

  // ---- Providers and models. Provider toggling resolves URL -> index at
  // POST time (Model.providerToggleScript) because the daemon renumbers
  // its list on every Nostr refresh.
  property var providerRows: []
  property var modelOptions: []
  property string providerBusyUrl: ""

  // Optimistic daemon toggle, tailscale-style: undefined follows reality;
  // true/false is the target state while a start/stop catches up.
  property var _desiredDaemonUp
  readonly property bool daemonActive: _desiredDaemonUp === undefined ? daemonUp : _desiredDaemonUp === true

  // ---- OpenCode integration
  property bool opencodeWired: false
  property int opencodeModels: 0
  property bool userDisconnected: false
  property bool _sawWired: false
  property bool _autoWireDone: false
  property bool _driftNotified: false

  // ---- Explicit client toggles (never auto-wired)
  property bool claudeInstalled: false
  property bool piInstalled: false
  property bool openclawInstalled: false
  property bool claudeWired: false
  property bool piWired: false
  property int piModels: 0
  property bool openclawWired: false
  property int openclawModels: 0
  property bool openclawDefaultIsRoutstr: false
  // Client id (claude-code | pi-agent | openclaw) while its add/remove runs.
  property string clientBusyId: ""

  // ---- Invoice
  property string invoiceText: ""
  property int invoiceSats: 0
  property bool invoiceQrReady: false
  property int _invoiceBaseline: -1
  property double _invoiceStartedMs: 0
  property int qrStamp: 0

  // ---- Surface strings
  property string actionStatus: ""
  property string lastError: ""

  readonly property string statusText: Model.statusLabel(probed, installed, onboarded, daemonUp, modelCount)
  readonly property bool lowBalance: daemonUp && balanceSats >= 0 && balanceSats < lowBalanceSats
  readonly property bool driftAlert: daemonUp && opencodeInstalled && _sawWired && !opencodeWired && !wireProcess.running
  // Keep-alive watch: an empty model list breaks agents just like drift
  // does. -1 means "unknown", so only a real zero badges.
  readonly property bool noModelsAlert: daemonUp && modelCount === 0
  readonly property bool alert: lowBalance || driftAlert || noModelsAlert
  readonly property bool wiring: wireProcess.running
  readonly property bool receivingCashu: cashuProcess.running
  readonly property bool creatingInvoice: invoiceProcess.running
  readonly property bool addingMint: addMintProcess.running
  readonly property bool busy: probeProcess.running || healthProcess.running || balanceProcess.running
    || keysProcess.running || modelsProcess.running || usageProcess.running || wireProcess.running
    || invoiceProcess.running || qrProcess.running || cashuProcess.running
    || mintsProcess.running || addMintProcess.running || clientProcess.running
    || providersProcess.running || providerToggleProcess.running

  readonly property int refreshIntervalSec: intSetting("refreshIntervalSec", 30, 5, 3600)
  readonly property int lowBalanceSats: intSetting("lowBalanceSats", 100, 0, 210000)
  // Off by default: the first write to someone else's config is theirs to
  // authorize, and the panel's Connect button is where they do it. Turning
  // this on trades that click for "wired the moment the daemon answers".
  readonly property bool autoWireOpencode: setting("autoWireOpencode", false) === true
  readonly property int defaultTopupSats: intSetting("defaultTopupSats", 2100, 21, 210000)
  readonly property bool hideBalance: setting("hideBalance", false) === true

  readonly property string baseUrl: "http://127.0.0.1:8008"

  // routstrd is a Bun global whose bin dir is wherever bun's global dir
  // lands: ~/.bun/bin by default, ${XDG_CACHE_HOME}/.bun/bin when the XDG
  // cache var is set (Omarchy sessions set it). Its shebang is
  // `#!/usr/bin/env bun`, so bun itself must be on PATH too (mise shims).
  // Login shells guarantee none of that; build the PATH ourselves for
  // every CLI invocation, with `bun pm bin -g` as the tie-breaker for
  // exotic configs.
  readonly property string pathPrelude:
    "export PATH=\"$HOME/.local/share/mise/shims:$HOME/.bun/bin:${XDG_CACHE_HOME:-$HOME/.cache}/.bun/bin:$PATH\"; "
    + "command -v routstrd >/dev/null 2>&1 || ! command -v bun >/dev/null 2>&1 || { _g=\"$(bun pm bin -g 2>/dev/null)\"; [ -n \"$_g\" ] && export PATH=\"$_g:$PATH\"; }; "
  readonly property string runtimeDir: Quickshell.env("XDG_RUNTIME_DIR") || "/tmp"
  readonly property string qrPath: runtimeDir + "/omarchy-routstr-invoice.png"
  readonly property string homeDir: Quickshell.env("HOME") || ""
  readonly property string opencodeConfigPath:
    (Quickshell.env("XDG_CONFIG_HOME") || (homeDir + "/.config")) + "/opencode/opencode.json"
  readonly property string claudeSettingsPath: homeDir + "/.claude/settings.json"
  readonly property string piModelsPath: homeDir + "/.pi/agent/models.json"
  readonly property string openclawConfigPath: homeDir + "/.openclaw/openclaw.json"

  property bool _wasUp: false
  property bool _wasLow: false
  property string _balanceRaw: ""
  property string _keysRaw: ""
  property string _summaryRaw: ""
  property string _recordWrittenKey: ""

  function setting(name, fallback) {
    var value = settings ? settings[name] : undefined
    return value === undefined || value === null ? fallback : value
  }

  function intSetting(name, fallback, min, max) {
    var n = parseInt(String(setting(name, fallback)), 10)
    if (!isFinite(n)) n = fallback
    if (n < min) n = min
    if (n > max) n = max
    return n
  }

  // ---- Notifications. One bar surface exists per monitor, so every
  // instance sees the same edge at the same time; an atomic mkdir in the
  // runtime dir lets exactly one of them speak.
  function notify(key, summary, body, urgency) {
    var bucket = Math.floor(Date.now() / 60000)
    var guard = runtimeDir + "/omarchy-routstr.note." + key + "." + bucket
    var cmd = "mkdir " + Util.shellQuote(guard) + " 2>/dev/null && notify-send -a Routstr "
      + (urgency ? "-u " + urgency + " " : "")
      + Util.shellQuote(summary) + " " + Util.shellQuote(body)
    Quickshell.execDetached(["bash", "-c", cmd])
  }

  function copyToClipboard(value) {
    var text = String(value || "")
    if (text === "") return
    Quickshell.execDetached(["bash", "-c", "printf %s " + Util.shellQuote(text) + " | wl-copy"])
    flashStatus("Copied")
  }

  function runInTerminal(script) {
    Quickshell.execDetached(["omarchy-launch-terminal", "bash", "-lc",
      pathPrelude + script + "; status=$?; printf '\\n[exit %s] press any key to close ' \"$status\"; read -r -n1 -s"])
  }

  function flashStatus(text) {
    actionStatus = String(text || "")
    if (actionStatus !== "") actionStatusTimer.restart()
  }

  function setError(reason, fallback) {
    var text = String(reason || fallback || "Something went wrong").replace(/\s+/g, " ").trim()
    lastError = text.length > 140 ? text.substring(0, 137) + "…" : text
    flashStatus("")
  }

  // ---- Refresh cycle -------------------------------------------------------

  function refresh(force) {
    // Probe every tick: it is one short-lived bash, and it is what notices
    // a routstrd install landing without the panel being reopened.
    if (!probeProcess.running) probe()
    // Health is not gated on the CLI probe: a daemon in Docker answers on
    // loopback with no `routstrd` on PATH.
    refreshDaemon()
    if (opencodeInstalled) opencodeConfig.reload()
    if (claudeInstalled) claudeConfig.reload()
    if (piInstalled) piConfig.reload()
    if (openclawInstalled) openclawConfig.reload()
  }

  // Every Process is started through this, so each carries its own deadline.
  //
  // The alternative — one shared one-shot timer, armed by the first launch of
  // a batch — reaped curls that had only just started: at the schema's
  // minimum 5s refresh interval the 12s timer killed the t=10s health check
  // at t=12s, and a health check killed mid-flight reads as daemonUp=false,
  // which empties the panel and fires a *critical* "daemon stopped"
  // notification about a daemon that is running fine. curl already carries
  // --max-time, so graceSec sits past it: this only reaps a process that is
  // genuinely wedged, never one that is merely slow.
  function launch(proc, command, graceSec) {
    proc.command = command
    proc.deadline = Date.now() + graceSec * 1000
    proc.running = true
    if (!pollWatchdog.running) pollWatchdog.start()
  }

  // Everything launch() may have started, for the watchdog to sweep. wire
  // and client are in here too: `routstrd clients add` fetches models over
  // Nostr and can hang on a dead relay, and without a reap the Connect
  // button spins forever and clientBusyId disables every agent row.
  function timedProcesses() {
    return [probeProcess, healthProcess, balanceProcess, keysProcess, modelsProcess,
            usageProcess, mintsProcess, summaryProcess, providersProcess,
            providerToggleProcess, wireProcess, clientProcess, invoiceProcess,
            qrProcess, addMintProcess, cashuProcess, recordProcess]
  }

  function probe() {
    launch(probeProcess, ["bash", "-lc",
      pathPrelude
      + "command -v routstrd >/dev/null 2>&1 && echo routstrd=yes || echo routstrd=no; "
      + "[ -e \"$HOME/.routstrd/config.json\" ] && echo config=yes || echo config=no; "
      + "command -v opencode >/dev/null 2>&1 && echo opencode=yes || echo opencode=no; "
      + "command -v bun >/dev/null 2>&1 && echo bun=yes || echo bun=no; "
      + "command -v claude >/dev/null 2>&1 && echo claude=yes || echo claude=no; "
      + "{ command -v pi >/dev/null 2>&1 || [ -d \"$HOME/.pi/agent\" ]; } && echo pi=yes || echo pi=no; "
      + "{ command -v openclaw >/dev/null 2>&1 || [ -e \"$HOME/.openclaw/openclaw.json\" ]; } && echo openclaw=yes || echo openclaw=no"], 30)
  }

  function refreshDaemon() {
    refreshing = true
    if (!healthProcess.running) launch(healthProcess, curlGet("/health", 5), 12)
    if (daemonUp || _desiredDaemonUp === true) {
      if (!balanceProcess.running) {
        _balanceRaw = ""
        launch(balanceProcess, curlGet("/balance", 5), 12)
      }
      // _keysRaw is deliberately NOT cleared here. A failed /keys/balance
      // would then read as zero api-key sats, dropping the displayed balance
      // by the whole session float — and a top-up started in that window
      // captures the sunk figure as its baseline, so the next successful
      // poll looks like the invoice was paid. Keep the last good value; the
      // handler only overwrites it on success.
      if (!keysProcess.running) launch(keysProcess, curlGet("/keys/balance", 5), 12)
      if (!modelsProcess.running) launch(modelsProcess, curlGet("/models", 8), 16)
      if (panelOpen && !usageProcess.running) launch(usageProcess, curlGet("/usage?limit=1", 5), 12)
      if (panelOpen && !mintsProcess.running) launch(mintsProcess, curlGet("/wallet/mints", 5), 12)
      if (panelOpen && !providersProcess.running) launch(providersProcess, curlGet("/providers", 8), 16)
      // Not panel-gated: the agents-panel usage record should stay fresh
      // in the background. The daemon caches this response for 60s.
      if (!summaryProcess.running) launch(summaryProcess, curlGet("/usage/summary", 8), 16)
    }
  }

  function curlGet(path, timeoutSec) {
    return ["curl", "-fsS", "--max-time", String(timeoutSec), baseUrl + path]
  }

  function settleBalance() {
    if (_balanceRaw === "") return
    var wallet = Model.walletTotal(_balanceRaw)
    if (wallet < 0) return
    activeMint = Model.activeMintFrom(_balanceRaw)
    mintRows = Model.mintRows(_mintsRaw, _balanceRaw)
    var total = wallet + Model.keysTotal(_keysRaw)
    var previous = balanceSats
    balanceSats = total

    if (invoiceText !== "") {
      if (_invoiceBaseline < 0) {
        // The invoice was created before any balance had landed — a fresh
        // shell, or the daemon having just come up. Anchor on the first real
        // reading instead of leaving the baseline at -1, which switched
        // paid-detection off for the invoice's whole 30-minute life: the
        // user pays, the balance visibly rises, and the QR sits there
        // claiming to be waiting.
        _invoiceBaseline = total
      } else if (total > _invoiceBaseline) {
        var gained = total - _invoiceBaseline
        notify("paid", "Top-up received", "+" + Model.formatSats(gained) + " sats — balance " + Model.formatSats(total) + " sats.")
        clearInvoice()
        flashStatus("Invoice paid")
      }
    }

    // Wallet and key balances land in separate responses; deciding "low"
    // on the first of the two would notify with a partial number. Let the
    // dust settle, then judge once.
    if (previous >= 0) lowCheckTimer.restart()
    maybeWriteUsageRecord()
  }

  // ---- omarchy.agents usage record ----------------------------------------
  //
  // One JSON record in ~/.local/state/omarchy/agents/usage/ makes Routstr a
  // prepaid row in the first-party agents panel. Written atomically (dotted
  // mktemp + mv, invisible to the panel's *.json discovery glob) and only
  // when the content actually changed, so several per-monitor instances
  // writing the same bytes stay harmless. Nothing is written until the
  // daemon has answered — a machine without routstrd never grows the file.
  function maybeWriteUsageRecord() {
    if (!daemonUp || balanceSats < 0 || _summaryRaw === "" || recordProcess.running) return
    var now = Date.now()
    var record = Model.usageRecord(balanceSats, _summaryRaw, now)
    if (record === null) return
    var key = Model.usageRecordKey(record, now)
    if (key === _recordWrittenKey) return
    recordProcess.pendingKey = key
    recordProcess.pendingBody = JSON.stringify(record)
    recordProcess.stdinEnabled = true
    launch(recordProcess, ["bash", "-c",
      "dir=\"${XDG_STATE_HOME:-$HOME/.local/state}/omarchy/agents/usage\"; mkdir -p \"$dir\"; "
      + "tmp=$(mktemp \"$dir/.routstr.json.XXXXXX\") || exit 1; "
      + "if cat > \"$tmp\"; then mv \"$tmp\" \"$dir/routstr.json\"; else rm -f \"$tmp\"; exit 1; fi"], 20)
  }

  function handleHealth(ok) {
    var was = _wasUp
    daemonUp = ok
    if (_desiredDaemonUp !== undefined && daemonUp === _desiredDaemonUp) _desiredDaemonUp = undefined
    if (ok) {
      startupRamp.running = false
      maybeAutoWire()
    } else {
      balanceSats = -1
      modelCount = -1
      lastUsage = null
      if (was) notify("down", "Routstr daemon stopped", "Agents lost their model endpoint. Open the Routstr panel to restart it.", "critical")
    }
    _wasUp = ok
  }

  // ---- Daemon actions ------------------------------------------------------

  function toggleDaemon() {
    if (!installed || !onboarded) return
    if (daemonActive) stopDaemon()
    else startDaemon()
  }

  function startDaemon() {
    // Fire-and-forget on purpose: if `routstrd start` ever ran its server in
    // the foreground, holding it in a Process object would tie the daemon's
    // life to this widget (and a watchdog reap would kill it).
    _desiredDaemonUp = true
    desiredTimeout.restart()
    flashStatus("Starting daemon…")
    Quickshell.execDetached(["bash", "-lc", pathPrelude + "routstrd start"])
    startupRamp.ticks = 0
    startupRamp.running = true
    delayedRefresh.restart()
  }

  function stopDaemon() {
    _desiredDaemonUp = false
    desiredTimeout.restart()
    flashStatus("Stopping daemon…")
    Quickshell.execDetached(["bash", "-lc", pathPrelude + "routstrd stop"])
    delayedRefresh.restart()
  }

  // Terminal-only flows. Onboard prints the wallet mnemonic; the shell
  // process must never see that output.
  function onboardInTerminal() {
    runInTerminal("routstrd onboard")
    flashStatus("Onboarding in terminal — finish there, then come back")
  }

  function persistInTerminal() {
    runInTerminal("routstrd service install && echo && echo 'To start on boot, also run: pm2 startup && pm2 save'")
  }

  // ---- OpenCode wiring -----------------------------------------------------

  // Opt-in (see autoWireOpencode). With the setting off this is a no-op and
  // opencode.json is only ever touched by a Connect/Repair click.
  function maybeAutoWire() {
    if (!autoWireOpencode || !daemonUp || !opencodeInstalled || !installed) return
    if (opencodeWired) { _sawWired = true; return }
    if (userDisconnected || _autoWireDone || wireProcess.running) return
    _autoWireDone = true
    wireOpencode()
  }

  function wireOpencode() {
    if (wireProcess.running || !installed) return
    userDisconnected = false
    flashStatus("Wiring OpenCode…")
    // Backup once before the first write, then let routstrd own the merge.
    // After a successful add, an empty top-level `model` gets routstrd's
    // own cheap pick (small_model) — the spec's first-run default.
    //
    // The whole thing runs under a cross-instance lock: auto-wire fires on
    // every monitor's Service at once, and three concurrent `clients add`
    // read-modify-writing opencode.json is a lost update at best. Losers
    // exit 75 and do nothing.
    launch(wireProcess, ["bash", "-lc",
      pathPrelude
      + Model.singleFlightFragment(runtimeDir + "/omarchy-routstr.wire.opencode")
      + "cfg=\"${XDG_CONFIG_HOME:-$HOME/.config}/opencode/opencode.json\"; "
      + "if [ -f \"$cfg\" ]; then " + Model.backupOnceFragment() + "fi; "
      + "routstrd clients add --opencode || exit $?; "
      + Model.opencodeDefaultModelFragment()], 120)
  }

  function handleWired() {
    opencodeConfig.reload()
    _sawWired = true
    _driftNotified = false
    flashStatus("OpenCode connected")
    // The config parse lands async, so a fresh wire reports the daemon's
    // model list — the same list `clients add` just wrote.
    var n = opencodeModels > 0 ? opencodeModels : modelCount
    notify("wired",
      n > 0 ? "OpenCode has " + Model.countLabel(n, "Routstr model") : "OpenCode has Routstr models",
      "Press c and pick a routstr/ model. " + (balanceSats > 0 ? "" : "Top up to start making requests."))
  }

  function handleOpencodeConfig(text) {
    var state = Model.opencodeState(text)
    var wasWired = opencodeWired
    opencodeWired = state.wired
    opencodeModels = state.models
    if (state.wired) {
      _sawWired = true
      _driftNotified = false
    } else if (wasWired && _sawWired && !wireProcess.running && !_driftNotified) {
      // Provider vanished after we saw it healthy: omarchy-refresh restored a
      // stock config, or the user deleted it on purpose. One toast, then
      // leave it off — Repair in the panel is the way back.
      _driftNotified = true
      userDisconnected = true
      notify("drift", "Routstr provider removed from OpenCode",
        "Use Repair in the Routstr panel to reconnect, or ignore this if it was deliberate.")
    }
  }

  // ---- Explicit client toggles ---------------------------------------------
  //
  // Wire: back the target file up once, then let `routstrd clients add`
  // own the merge (same contract as OpenCode). Disconnect is the part
  // routstrd does not have — see Model.disconnectScript for the shape
  // and the reasoning.

  readonly property var clientSpecs: ({
    "claude-code": { name: "Claude Code", flag: "--claude-code", path: claudeSettingsPath },
    "pi-agent": { name: "Pi", flag: "--pi-agent", path: piModelsPath },
    "openclaw": { name: "OpenClaw", flag: "--openclaw", path: openclawConfigPath }
  })

  // The FileView watching each explicit client's config, keyed by the same
  // ids as clientSpecs, for post-action reloads.
  readonly property var clientViews: ({
    "claude-code": claudeConfig,
    "pi-agent": piConfig,
    "openclaw": openclawConfig
  })

  function wireClient(id) {
    var spec = clientSpecs[id]
    if (!spec || clientProcess.running || !installed || !daemonUp) return
    clientBusyId = id
    clientProcess.clientId = id
    clientProcess.verb = "connect"
    flashStatus("Wiring " + spec.name + "…")
    launch(clientProcess, ["bash", "-lc",
      pathPrelude
      + "cfg=" + Util.shellQuote(spec.path) + "; "
      + "if [ -f \"$cfg\" ]; then " + Model.backupOnceFragment() + "fi; "
      + "exec routstrd clients add " + spec.flag], 120)
  }

  function disconnectClient(id) {
    var spec = clientSpecs[id]
    if (!spec || clientProcess.running || !daemonUp) return
    clientBusyId = id
    clientProcess.clientId = id
    clientProcess.verb = "disconnect"
    flashStatus("Disconnecting " + spec.name + "…")
    // Script text lives in Model.js so the test suite executes the exact
    // same bytes against fixture configs. Rationale for its shape is there.
    launch(clientProcess, ["bash", "-c", Model.disconnectScript(id, spec.path, baseUrl)], 120)
  }

  function handleClientExit(id, verb, exitCode, errorText) {
    var spec = clientSpecs[id] || { name: id }
    if (exitCode === 0) {
      lastError = ""
      flashStatus(spec.name + (verb === "connect" ? " connected" : " disconnected"))
    } else {
      setError(errorText, "Could not " + verb + " " + spec.name)
    }
    var view = clientViews[id]
    if (view) view.reload()
  }

  // ---- Invoice -------------------------------------------------------------

  // Takes a chip's int or a typed string; Model owns the parsing and the
  // bounds. Returns the amount an invoice was requested for, or 0 when
  // nothing was launched (unusable amount, daemon down, one already out).
  function createInvoice(sats) {
    if (invoiceProcess.running || !daemonUp) return 0
    var amount = Model.normalizeTopupSats(sats)
    if (amount === 0) {
      lastError = Model.topupError()
      return 0
    }
    lastError = ""
    clearInvoice()
    invoiceSats = amount
    _invoiceBaseline = balanceSats
    _invoiceStartedMs = Date.now()
    flashStatus("Creating invoice…")
    var body = { amount: amount }
    if (topupMintUrl !== "") body.mintUrl = topupMintUrl
    // No -f, same reason as the cashu redeem: when the mint rejects the
    // amount the daemon's {error} body is the only thing that tells the user
    // what to change, and -f throws the body away in favour of
    // "curl: (22) The requested URL returned error: 400".
    launch(invoiceProcess, ["curl", "-sS", "--max-time", "15",
      "-X", "POST", "-H", "Content-Type: application/json",
      "-d", JSON.stringify(body),
      baseUrl + "/wallet/receive/bolt11"], 30)
    return amount
  }

  // ---- Mints ---------------------------------------------------------------

  function selectTopupMint(url) {
    topupMintUrl = String(url || "")
    if (topupMintUrl !== "") flashStatus("Invoices will mint into " + Model.hostOf(topupMintUrl))
  }

  // ---- Providers / models --------------------------------------------------

  function toggleProvider(url, disable) {
    if (providerToggleProcess.running || !daemonUp) return
    providerBusyUrl = String(url)
    flashStatus((disable ? "Disabling " : "Enabling ") + Model.hostOf(url) + "…")
    launch(providerToggleProcess, ["bash", "-c", Model.providerToggleScript(url, disable, baseUrl)], 30)
  }

  function copyModelRef(id) {
    if (String(id) === "") return
    copyToClipboard("routstr/" + id)
    flashStatus("Copied routstr/" + id)
  }

  function addMint(rawUrl) {
    if (addMintProcess.running || !daemonUp) return
    var url = Model.normalizeMintUrl(rawUrl)
    if (url === "") {
      lastError = "Mint URLs look like https://mint.example.org"
      return
    }
    lastError = ""
    flashStatus("Adding mint…")
    launch(addMintProcess, ["curl", "-sS", "--max-time", "20",
      "-X", "POST", "-H", "Content-Type: application/json",
      "-d", JSON.stringify({ url: url }),
      baseUrl + "/wallet/mints"], 35)
  }

  function renderQr() {
    if (invoiceText === "") return
    invoiceQrReady = false
    launch(qrProcess, ["bash", "-c",
      "qrencode -o " + Util.shellQuote(qrPath) + " -s 5 -m 2 " + Util.shellQuote("lightning:" + invoiceText)], 20)
  }

  function clearInvoice() {
    if (invoiceText !== "") Quickshell.execDetached(["rm", "-f", qrPath])
    invoiceText = ""
    invoiceSats = 0
    invoiceQrReady = false
    _invoiceBaseline = -1
    _invoiceStartedMs = 0
  }

  function copyInvoice() {
    if (invoiceText !== "") copyToClipboard(invoiceText)
  }

  // ---- Cashu receive -------------------------------------------------------

  // The token is money until the daemon swaps it at the mint. Hard rules:
  // it goes to curl over stdin — never argv (readable in /proc), never a
  // log line — and the one property that stages it is cleared the moment
  // the process starts (the network panel's passphrase pattern). The
  // caller clears its TextField before calling.
  function receiveCashu(rawToken) {
    if (cashuProcess.running || !daemonUp) return
    var token = Model.normalizeCashuToken(rawToken)
    if (token === "") {
      lastError = "That doesn't look like a Cashu token (cashuA… / cashuB…)."
      return
    }
    lastError = ""
    flashStatus("Redeeming token…")
    cashuProcess.pendingBody = JSON.stringify({ token: token })
    token = ""
    // No -f: on an HTTP error the daemon's {error} body is the message
    // worth showing ("Invalid token", "already spent"), and -f discards it.
    cashuProcess.stdinEnabled = true  // re-arm; each run closes it after writing
    // A generous grace: curl's own --max-time 30 is what should end a slow
    // redeem. This only catches a process wedged past that, and reaping a
    // redeem that is genuinely in flight is not something to do eagerly.
    launch(cashuProcess, ["curl", "-sS", "--max-time", "30",
      "-X", "POST", "-H", "Content-Type: application/json",
      "-d", "@-", baseUrl + "/wallet/receive/cashu"], 60)
  }

  function handleCashuExit(exitCode, stdoutText, stderrText) {
    var result = Model.cashuResult(stdoutText)
    if (exitCode === 0 && result.ok) {
      lastError = ""
      flashStatus(result.amountSats > 0
        ? "Received " + Model.formatSats(result.amountSats) + " sats"
        : "Token redeemed")
      // An open Lightning invoice must not claim this deposit as its own:
      // move its baseline past the cashu amount before the balance lands.
      if (_invoiceBaseline >= 0 && result.amountSats > 0) _invoiceBaseline += result.amountSats
      refreshDaemon()
    } else {
      setError(result.error !== "" ? result.error : Model.maskCashuTokens(String(stderrText || "")),
        "Could not redeem the token")
    }
  }

  // ---- Timers --------------------------------------------------------------

  Timer {
    id: refreshTimer
    interval: root.refreshIntervalSec * 1000
    repeat: true
    running: true
    triggeredOnStart: true
    onTriggered: root.refresh(false)
  }

  Timer {
    // Fast poll while a Lightning invoice is out, so "paid" lands in seconds
    // rather than at the next scheduled refresh. Mint quotes expire; after
    // 30 minutes the QR is a lie, so retire it.
    id: invoicePoll
    interval: 5000
    repeat: true
    running: root.invoiceText !== ""
    onTriggered: {
      if (Date.now() - root._invoiceStartedMs > 1800000) {
        root.flashStatus("Invoice expired")
        root.clearInvoice()
        return
      }
      root.refreshDaemon()
    }
  }

  Timer {
    // After boot or daemon start, poll quickly until the daemon answers.
    id: startupRamp
    property int ticks: 0
    interval: 2000
    repeat: true
    running: true
    onTriggered: {
      ticks += 1
      if (root.daemonUp || ticks >= 15) startupRamp.running = false
      else root.refresh(false)
    }
  }

  Timer {
    id: delayedRefresh
    interval: 700
    repeat: false
    onTriggered: root.refresh(true)
  }

  Timer {
    // curl carries --max-time, so this is the belt for anything else wedged.
    // It sweeps rather than fires once: each process is reaped against its
    // own deadline (set by launch()), so a slow call started late in a batch
    // is never killed on another call's clock. Runs only while something is
    // actually in flight.
    id: pollWatchdog
    interval: 2000
    repeat: true
    running: false
    onTriggered: {
      var list = root.timedProcesses()
      var now = Date.now()
      var anyRunning = false
      for (var i = 0; i < list.length; i++) {
        var p = list[i]
        if (!p.running) continue
        if (p.deadline > 0 && now >= p.deadline) p.running = false  // SIGTERM
        else anyRunning = true
      }
      if (!anyRunning) pollWatchdog.stop()
    }
  }

  Timer {
    // The daemon toggle is optimistic, and start/stop go out through
    // execDetached on purpose (holding routstrd in a Process would tie its
    // life to this widget) — so there is no exit code to fail on. Without a
    // deadline, a `routstrd start` that never comes up (port taken, corrupt
    // config) left _desiredDaemonUp pinned true for the session: the hero
    // switch showed ON, the button spun "Starting…" forever, and
    // refreshDaemon kept firing four extra polls a tick at a dead daemon.
    // Reality wins after this; handleHealth clears it sooner when they agree.
    id: desiredTimeout
    interval: 32000
    repeat: false
    onTriggered: root._desiredDaemonUp = undefined
  }

  Timer {
    id: actionStatusTimer
    interval: 2600
    repeat: false
    onTriggered: root.actionStatus = ""
  }

  Timer {
    id: lowCheckTimer
    interval: 400
    repeat: false
    onTriggered: {
      var low = root.daemonUp && root.balanceSats >= 0 && root.balanceSats < root.lowBalanceSats
      if (low && !root._wasLow) {
        root.notify("low", "Routstr balance low",
          Model.formatSats(root.balanceSats) + " sats left. Top up from the bar panel.", "critical")
      }
      root._wasLow = low
    }
  }

  // ---- Watchers ------------------------------------------------------------

  FileView {
    id: opencodeConfig
    path: root.opencodeConfigPath
    watchChanges: true
    printErrors: false
    onFileChanged: reload()
    onLoaded: root.handleOpencodeConfig(text())
    onLoadFailed: {
      root.opencodeWired = false
      root.opencodeModels = 0
    }
  }

  FileView {
    id: claudeConfig
    path: root.claudeSettingsPath
    watchChanges: true
    printErrors: false
    onFileChanged: reload()
    onLoaded: root.claudeWired = Model.claudeState(text()).wired
    onLoadFailed: root.claudeWired = false
  }

  FileView {
    id: piConfig
    path: root.piModelsPath
    watchChanges: true
    printErrors: false
    onFileChanged: reload()
    onLoaded: {
      var state = Model.piState(text())
      root.piWired = state.wired
      root.piModels = state.models
    }
    onLoadFailed: {
      root.piWired = false
      root.piModels = 0
    }
  }

  FileView {
    id: openclawConfig
    path: root.openclawConfigPath
    watchChanges: true
    printErrors: false
    onFileChanged: reload()
    onLoaded: {
      var state = Model.openclawState(text())
      root.openclawWired = state.wired
      root.openclawModels = state.models
      root.openclawDefaultIsRoutstr = state.defaultIsRoutstr
    }
    onLoadFailed: {
      root.openclawWired = false
      root.openclawModels = 0
      root.openclawDefaultIsRoutstr = false
    }
  }

  // ---- Processes -----------------------------------------------------------

  // Process plus the one thing every launch needs: when it is overdue.
  // launch() stamps it; pollWatchdog reaps against it.
  component TimedProcess: Process {
    property double deadline: 0
  }

  TimedProcess {
    id: probeProcess
    running: false
    command: []
    stdout: StdioCollector { id: probeStdout; waitForEnd: true }
    onExited: function(exitCode) {
      var out = String(probeStdout.text || "")
      root.installed = out.indexOf("routstrd=yes") !== -1
      root.onboarded = out.indexOf("config=yes") !== -1
      root.opencodeInstalled = out.indexOf("opencode=yes") !== -1
      root.bunInstalled = out.indexOf("bun=yes") !== -1
      root.claudeInstalled = out.indexOf("claude=yes") !== -1
      root.piInstalled = out.indexOf("pi=yes") !== -1
      root.openclawInstalled = out.indexOf("openclaw=yes") !== -1
      root.probed = true
      root.refreshDaemon()
    }
  }

  TimedProcess {
    id: healthProcess
    running: false
    command: []
    stdout: StdioCollector { waitForEnd: true }
    stderr: StdioCollector { waitForEnd: true }
    onExited: function(exitCode) {
      root.refreshing = false
      root.handleHealth(exitCode === 0)
    }
  }

  TimedProcess {
    id: balanceProcess
    running: false
    command: []
    stdout: StdioCollector { id: balanceStdout; waitForEnd: true; onStreamFinished: root._balanceRaw = text }
    stderr: StdioCollector { waitForEnd: true }
    onExited: function(exitCode) {
      if (exitCode === 0) root.settleBalance()
    }
  }

  TimedProcess {
    id: keysProcess
    running: false
    command: []
    stdout: StdioCollector { id: keysStdout; waitForEnd: true }
    stderr: StdioCollector { waitForEnd: true }
    onExited: function(exitCode) {
      // Only a successful response replaces the api-key float. Settling on a
      // failed one counted it as zero, which showed up as the balance
      // dropping by the whole session float and, mid-invoice, as a phantom
      // "Top-up received" when the next poll put it back.
      if (exitCode !== 0) return
      root._keysRaw = keysStdout.text
      root.settleBalance()
    }
  }

  TimedProcess {
    id: modelsProcess
    running: false
    command: []
    stdout: StdioCollector { id: modelsStdout; waitForEnd: true }
    stderr: StdioCollector { waitForEnd: true }
    onExited: function(exitCode) {
      if (exitCode === 0) {
        root.modelCount = Model.modelCount(modelsStdout.text)
        root.modelOptions = Model.modelOptions(modelsStdout.text)
      }
    }
  }

  TimedProcess {
    id: providersProcess
    running: false
    command: []
    stdout: StdioCollector { id: providersStdout; waitForEnd: true }
    stderr: StdioCollector { waitForEnd: true }
    onExited: function(exitCode) {
      if (exitCode === 0) root.providerRows = Model.providerRows(providersStdout.text)
    }
  }

  TimedProcess {
    id: providerToggleProcess
    running: false
    command: []
    stdout: StdioCollector { waitForEnd: true }
    stderr: StdioCollector { id: providerToggleStderr; waitForEnd: true }
    onExited: function(exitCode) {
      root.providerBusyUrl = ""
      if (exitCode === 0) root.lastError = ""
      else root.setError(providerToggleStderr.text, "Could not change the provider")
      // Re-read the authoritative list either way.
      if (!providersProcess.running) root.launch(providersProcess, root.curlGet("/providers", 8), 16)
    }
  }

  TimedProcess {
    id: usageProcess
    running: false
    command: []
    stdout: StdioCollector { id: usageStdout; waitForEnd: true }
    stderr: StdioCollector { waitForEnd: true }
    onExited: function(exitCode) {
      if (exitCode === 0) root.lastUsage = Model.latestUsage(usageStdout.text)
    }
  }

  TimedProcess {
    id: wireProcess
    running: false
    command: []
    stdout: StdioCollector { id: wireStdout; waitForEnd: true }
    stderr: StdioCollector { id: wireStderr; waitForEnd: true }
    onExited: function(exitCode) {
      if (exitCode === 0) {
        root.lastError = ""
        root.handleWired()
      } else if (exitCode === Model.exTempfail()) {
        // A peer instance holds the wire lock and is doing the work. Not an
        // error and not ours to report — the config watcher publishes the
        // result to every instance.
      } else {
        root.setError(String(wireStderr.text || wireStdout.text || ""), "routstrd clients add failed")
      }
      delayedRefresh.restart()
    }
  }

  TimedProcess {
    id: invoiceProcess
    running: false
    command: []
    stdout: StdioCollector { id: invoiceStdout; waitForEnd: true }
    stderr: StdioCollector { id: invoiceStderr; waitForEnd: true }
    onExited: function(exitCode) {
      var invoice = exitCode === 0 ? Model.invoiceFrom(invoiceStdout.text) : ""
      if (invoice !== "") {
        root.invoiceText = invoice
        root.lastError = ""
        root.flashStatus("")
        root.renderQr()
      } else {
        root.invoiceSats = 0
        root.setError(invoiceStderr.text, "Could not create a Lightning invoice")
      }
    }
  }

  TimedProcess {
    id: qrProcess
    running: false
    command: []
    onExited: function(exitCode) {
      if (exitCode === 0) {
        root.qrStamp += 1
        root.invoiceQrReady = true
      }
    }
  }

  TimedProcess {
    id: summaryProcess
    running: false
    command: []
    stdout: StdioCollector { id: summaryStdout; waitForEnd: true }
    stderr: StdioCollector { waitForEnd: true }
    onExited: function(exitCode) {
      if (exitCode !== 0) return
      root._summaryRaw = summaryStdout.text
      root.maybeWriteUsageRecord()
    }
  }

  TimedProcess {
    id: recordProcess
    property string pendingKey: ""
    property string pendingBody: ""
    running: false
    command: []
    stdinEnabled: true
    onStarted: {
      write(pendingBody)
      pendingBody = ""
      stdinEnabled = false
    }
    onExited: function(exitCode) {
      if (exitCode === 0) root._recordWrittenKey = pendingKey
      pendingKey = ""
    }
  }

  TimedProcess {
    id: clientProcess
    property string clientId: ""
    property string verb: ""
    running: false
    command: []
    stdout: StdioCollector { id: clientStdout; waitForEnd: true }
    stderr: StdioCollector { id: clientStderr; waitForEnd: true }
    onExited: function(exitCode) {
      var id = clientId
      var v = verb
      clientId = ""
      verb = ""
      root.clientBusyId = ""
      root.handleClientExit(id, v, exitCode, String(clientStderr.text || clientStdout.text || ""))
    }
  }

  TimedProcess {
    id: mintsProcess
    running: false
    command: []
    stdout: StdioCollector { id: mintsStdout; waitForEnd: true }
    stderr: StdioCollector { waitForEnd: true }
    onExited: function(exitCode) {
      if (exitCode !== 0) return
      root._mintsRaw = mintsStdout.text
      root.mintRows = Model.mintRows(root._mintsRaw, root._balanceRaw)
    }
  }

  TimedProcess {
    id: addMintProcess
    running: false
    command: []
    stdout: StdioCollector { id: addMintStdout; waitForEnd: true }
    stderr: StdioCollector { id: addMintStderr; waitForEnd: true }
    onExited: function(exitCode) {
      var body = Model.parseJson(addMintStdout.text)
      if (exitCode === 0 && body && !body.error) {
        root.lastError = ""
        root.flashStatus("Mint added")
        root.refreshDaemon()
      } else {
        root.setError(String((body && body.error) || addMintStderr.text || ""), "Could not add the mint")
      }
    }
  }

  TimedProcess {
    id: cashuProcess
    property string pendingBody: ""
    running: false
    command: []
    stdinEnabled: true
    onStarted: {
      write(pendingBody)
      pendingBody = ""
      // curl -d @- reads to EOF; closing the write channel is what ends it.
      stdinEnabled = false
    }
    // Belt for a spawn that never reaches onStarted: the staged token must
    // not outlive the attempt in a property.
    onRunningChanged: if (!running) pendingBody = ""
    stdout: StdioCollector { id: cashuStdout; waitForEnd: true }
    stderr: StdioCollector { id: cashuStderr; waitForEnd: true }
    onExited: function(exitCode) {
      root.handleCashuExit(exitCode, cashuStdout.text, cashuStderr.text)
    }
  }

  Component.onDestruction: if (invoiceText !== "") Quickshell.execDetached(["rm", "-f", qrPath])
}
