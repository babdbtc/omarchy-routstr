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
//   - opencode.json is only ever written by `routstrd clients add`; this
//     service just watches it and backs it up once before the first write.
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

  // Optimistic daemon toggle, tailscale-style: -1 follow reality, 0/1 while
  // a start/stop is catching up.
  property int _desired: -1
  readonly property bool daemonActive: _desired === -1 ? daemonUp : (_desired === 1)

  // ---- OpenCode integration
  property bool opencodeWired: false
  property int opencodeModels: 0
  property bool userDisconnected: false
  property bool _sawWired: false
  property bool _autoWireDone: false
  property bool _driftNotified: false

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
  readonly property bool alert: lowBalance || driftAlert
  readonly property bool wiring: wireProcess.running
  readonly property bool receivingCashu: cashuProcess.running
  readonly property bool busy: probeProcess.running || healthProcess.running || balanceProcess.running
    || keysProcess.running || modelsProcess.running || usageProcess.running || wireProcess.running
    || invoiceProcess.running || qrProcess.running || cashuProcess.running

  readonly property int refreshIntervalSec: intSetting("refreshIntervalSec", 30, 5, 3600)
  readonly property int lowBalanceSats: intSetting("lowBalanceSats", 100, 0, 210000)
  readonly property bool autoWireOpencode: setting("autoWireOpencode", true) === true
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
  readonly property string opencodeConfigPath:
    (Quickshell.env("XDG_CONFIG_HOME") || (Quickshell.env("HOME") + "/.config")) + "/opencode/opencode.json"

  property bool _wasUp: false
  property bool _wasLow: false
  property string _balanceRaw: ""
  property string _keysRaw: ""

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

  function formatSats(n) { return Model.formatSats(n) }

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

  // ---- Refresh cycle -------------------------------------------------------

  function refresh(force) {
    // Probe every tick: it is one short-lived bash, and it is what notices
    // a routstrd install landing without the panel being reopened.
    if (!probeProcess.running) probe()
    // Health is not gated on the CLI probe: a daemon in Docker answers on
    // loopback with no `routstrd` on PATH.
    refreshDaemon()
    if (opencodeInstalled) opencodeConfig.reload()
  }

  function probe() {
    probeProcess.command = ["bash", "-lc",
      pathPrelude
      + "command -v routstrd >/dev/null 2>&1 && echo routstrd=yes || echo routstrd=no; "
      + "[ -e \"$HOME/.routstrd/config.json\" ] && echo config=yes || echo config=no; "
      + "command -v opencode >/dev/null 2>&1 && echo opencode=yes || echo opencode=no; "
      + "command -v bun >/dev/null 2>&1 && echo bun=yes || echo bun=no"]
    probeProcess.running = true
  }

  function refreshDaemon() {
    var launched = false
    refreshing = true
    if (!healthProcess.running) {
      healthProcess.command = curlGet("/health", 5)
      healthProcess.running = true
      launched = true
    }
    if (daemonUp || _desired === 1) {
      if (!balanceProcess.running) {
        _balanceRaw = ""
        balanceProcess.command = curlGet("/balance", 5)
        balanceProcess.running = true
        launched = true
      }
      if (!keysProcess.running) {
        _keysRaw = ""
        keysProcess.command = curlGet("/keys/balance", 5)
        keysProcess.running = true
        launched = true
      }
      if (!modelsProcess.running) {
        modelsProcess.command = curlGet("/models", 8)
        modelsProcess.running = true
        launched = true
      }
      if (panelOpen && !usageProcess.running) {
        usageProcess.command = curlGet("/usage?limit=1", 5)
        usageProcess.running = true
        launched = true
      }
    }
    if (launched && !pollWatchdog.running) pollWatchdog.start()
  }

  function curlGet(path, timeoutSec) {
    return ["curl", "-fsS", "--max-time", String(timeoutSec), baseUrl + path]
  }

  function settleBalance() {
    if (_balanceRaw === "") return
    var wallet = Model.walletTotal(_balanceRaw)
    if (wallet < 0) return
    var total = wallet + Model.keysTotal(_keysRaw)
    var previous = balanceSats
    balanceSats = total

    if (invoiceText !== "" && _invoiceBaseline >= 0 && total > _invoiceBaseline) {
      var gained = total - _invoiceBaseline
      notify("paid", "Top-up received", "+" + Model.formatSats(gained) + " sats — balance " + Model.formatSats(total) + " sats.")
      clearInvoice()
      flashStatus("Invoice paid")
    }

    // Wallet and key balances land in separate responses; deciding "low"
    // on the first of the two would notify with a partial number. Let the
    // dust settle, then judge once.
    if (previous >= 0) lowCheckTimer.restart()
  }

  function handleHealth(ok) {
    var was = _wasUp
    daemonUp = ok
    if (_desired !== -1 && daemonUp === (_desired === 1)) _desired = -1
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
    _desired = 1
    flashStatus("Starting daemon…")
    Quickshell.execDetached(["bash", "-lc", pathPrelude + "routstrd start"])
    startupRamp.ticks = 0
    startupRamp.running = true
    delayedRefresh.restart()
  }

  function stopDaemon() {
    _desired = 0
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

  function installInTerminal() {
    if (!bunInstalled) return
    runInTerminal("bun i -g routstrd")
    flashStatus("Installing routstrd in terminal")
  }

  function persistInTerminal() {
    runInTerminal("routstrd service install && echo && echo 'To start on boot, also run: pm2 startup && pm2 save'")
  }

  // ---- OpenCode wiring -----------------------------------------------------

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
    wireProcess.command = ["bash", "-lc",
      pathPrelude
      + "cfg=\"${XDG_CONFIG_HOME:-$HOME/.config}/opencode/opencode.json\"; "
      + "if [ -f \"$cfg\" ]; then set -- \"$cfg\".bak-routstr-*; [ -e \"$1\" ] || cp -p \"$cfg\" \"$cfg.bak-routstr-$(date +%Y%m%d%H%M%S)\"; fi; "
      + "exec routstrd clients add --opencode"]
    wireProcess.running = true
  }

  function handleWired() {
    opencodeConfig.reload()
    _sawWired = true
    _driftNotified = false
    flashStatus("OpenCode connected")
    notify("wired", "OpenCode has Routstr models",
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

  // ---- Invoice -------------------------------------------------------------

  function createInvoice(sats) {
    var amount = parseInt(String(sats), 10)
    if (!isFinite(amount) || amount <= 0 || invoiceProcess.running || !daemonUp) return
    clearInvoice()
    invoiceSats = amount
    _invoiceBaseline = balanceSats
    _invoiceStartedMs = Date.now()
    flashStatus("Creating invoice…")
    invoiceProcess.command = ["curl", "-fsS", "--max-time", "15",
      "-X", "POST", "-H", "Content-Type: application/json",
      "-d", JSON.stringify({ amount: amount }),
      baseUrl + "/wallet/receive/bolt11"]
    invoiceProcess.running = true
  }

  function renderQr() {
    if (invoiceText === "") return
    invoiceQrReady = false
    qrProcess.command = ["bash", "-c",
      "qrencode -o " + Util.shellQuote(qrPath) + " -s 5 -m 2 " + Util.shellQuote("lightning:" + invoiceText)]
    qrProcess.running = true
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
    cashuProcess.command = ["curl", "-sS", "--max-time", "30",
      "-X", "POST", "-H", "Content-Type: application/json",
      "-d", "@-", baseUrl + "/wallet/receive/cashu"]
    cashuProcess.stdinEnabled = true  // re-arm; each run closes it after writing
    cashuProcess.running = true
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
      var reason = result.error !== "" ? result.error
        : Model.maskCashuTokens(String(stderrText || "Could not redeem the token").replace(/\s+/g, " ").trim())
      lastError = reason.length > 140 ? reason.substring(0, 137) + "…" : reason
      flashStatus("")
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
    id: pollWatchdog
    interval: 12000
    repeat: false
    onTriggered: {
      if (healthProcess.running) healthProcess.running = false
      if (balanceProcess.running) balanceProcess.running = false
      if (keysProcess.running) keysProcess.running = false
      if (modelsProcess.running) modelsProcess.running = false
      if (usageProcess.running) usageProcess.running = false
    }
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

  // ---- Processes -----------------------------------------------------------

  Process {
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
      root.probed = true
      root.refreshDaemon()
    }
  }

  Process {
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

  Process {
    id: balanceProcess
    running: false
    command: []
    stdout: StdioCollector { id: balanceStdout; waitForEnd: true; onStreamFinished: root._balanceRaw = text }
    stderr: StdioCollector { waitForEnd: true }
    onExited: function(exitCode) {
      if (exitCode === 0) root.settleBalance()
    }
  }

  Process {
    id: keysProcess
    running: false
    command: []
    stdout: StdioCollector { id: keysStdout; waitForEnd: true; onStreamFinished: root._keysRaw = text }
    stderr: StdioCollector { waitForEnd: true }
    onExited: function(exitCode) {
      // Keys are additive detail; settle with whatever the wallet call said.
      root.settleBalance()
    }
  }

  Process {
    id: modelsProcess
    running: false
    command: []
    stdout: StdioCollector { id: modelsStdout; waitForEnd: true }
    stderr: StdioCollector { waitForEnd: true }
    onExited: function(exitCode) {
      if (exitCode === 0) root.modelCount = Model.modelCount(modelsStdout.text)
    }
  }

  Process {
    id: usageProcess
    running: false
    command: []
    stdout: StdioCollector { id: usageStdout; waitForEnd: true }
    stderr: StdioCollector { waitForEnd: true }
    onExited: function(exitCode) {
      if (exitCode === 0) root.lastUsage = Model.latestUsage(usageStdout.text)
    }
  }

  Process {
    id: wireProcess
    running: false
    command: []
    stdout: StdioCollector { id: wireStdout; waitForEnd: true }
    stderr: StdioCollector { id: wireStderr; waitForEnd: true }
    onExited: function(exitCode) {
      if (exitCode === 0) {
        root.lastError = ""
        root.handleWired()
      } else {
        var reason = String(wireStderr.text || wireStdout.text || "routstrd clients add failed")
          .replace(/\s+/g, " ").trim()
        root.lastError = reason.length > 140 ? reason.substring(0, 137) + "…" : reason
        root.flashStatus("")
      }
      delayedRefresh.restart()
    }
  }

  Process {
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
        var reason = String(invoiceStderr.text || "Could not create a Lightning invoice").replace(/\s+/g, " ").trim()
        root.lastError = reason.length > 140 ? reason.substring(0, 137) + "…" : reason
      }
    }
  }

  Process {
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

  Process {
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
    stdout: StdioCollector { id: cashuStdout; waitForEnd: true }
    stderr: StdioCollector { id: cashuStderr; waitForEnd: true }
    onExited: function(exitCode) {
      root.handleCashuExit(exitCode, cashuStdout.text, cashuStderr.text)
    }
  }

  Component.onDestruction: if (invoiceText !== "") Quickshell.execDetached(["rm", "-f", qrPath])
}
