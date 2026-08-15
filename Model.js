.pragma library

// Pure parsing and formatting for the Routstr plugin. Everything that can be
// a function of its inputs lives here, out of the QML object tree.

function parseJson(text) {
  try {
    var parsed = JSON.parse(String(text || ""))
    return parsed && typeof parsed === "object" ? parsed : null
  } catch (e) {
    return null
  }
}

// The live daemon wraps responses as { output: ... }; tolerate both that
// and the bare shape.
function unwrap(obj) {
  if (obj && typeof obj === "object" && obj.output && typeof obj.output === "object") return obj.output
  return obj
}

// "21000" -> "21 000" (thin spaces). Negative/unknown -> em dash.
function formatSats(n) {
  if (n === undefined || n === null || !isFinite(n) || n < 0) return "—"
  var s = String(Math.floor(n))
  var out = ""
  for (var i = 0; i < s.length; i++) {
    if (i > 0 && (s.length - i) % 3 === 0) out += "\u2009"
    out += s.charAt(i)
  }
  return out
}

// GET /balance -> { balances: { "<mintUrl>": sats } }. Returns total sats or
// -1 when the shape is not recognized.
function walletTotal(json) {
  var obj = unwrap(parseJson(json))
  if (!obj || !obj.balances || typeof obj.balances !== "object") return -1
  var total = 0
  for (var mint in obj.balances) {
    var v = Number(obj.balances[mint])
    if (isFinite(v)) total += v
  }
  return total
}

// GET /balance -> { balances: { "<mintUrl>": sats }, activeMint }. The active
// mint is derived state (cocod's first listed mint), not settable.
function activeMintFrom(json) {
  var obj = unwrap(parseJson(json))
  if (!obj || typeof obj.activeMint !== "string") return ""
  return obj.activeMint
}

function hostOf(url) {
  var s = String(url || "").replace(/^[a-z+]+:\/\//i, "")
  var slash = s.indexOf("/")
  if (slash !== -1) s = s.substring(0, slash)
  return s
}

// GET /wallet/mints + GET /balance -> display rows. The mints list is the
// authoritative membership; the balance map contributes per-mint sats (a
// mint can hold funds while missing from the list if cocod's listMints
// hiccups, so union both).
function mintRows(mintsJson, balanceJson) {
  var mintsObj = unwrap(parseJson(mintsJson))
  var balanceObj = unwrap(parseJson(balanceJson))
  var urls = []
  if (mintsObj && mintsObj.mints instanceof Array) {
    for (var i = 0; i < mintsObj.mints.length; i++) {
      var u = String(mintsObj.mints[i] || "")
      if (u !== "" && urls.indexOf(u) === -1) urls.push(u)
    }
  }
  var balances = balanceObj && balanceObj.balances && typeof balanceObj.balances === "object"
    ? balanceObj.balances : {}
  for (var mint in balances) {
    if (urls.indexOf(mint) === -1) urls.push(mint)
  }
  var active = (mintsObj && typeof mintsObj.activeMint === "string" && mintsObj.activeMint !== "")
    ? mintsObj.activeMint
    : (balanceObj && typeof balanceObj.activeMint === "string" ? balanceObj.activeMint : "")
  var rows = []
  for (var j = 0; j < urls.length; j++) {
    var sats = Number(balances[urls[j]])
    rows.push({
      url: urls[j],
      host: hostOf(urls[j]),
      sats: isFinite(sats) ? sats : 0,
      active: urls[j] === active
    })
  }
  return rows
}

// A pasted mint URL. Mints are https endpoints; anything else is a typo.
function normalizeMintUrl(raw) {
  var s = String(raw || "").trim().replace(/\/+$/, "")
  if (s === "") return ""
  if (!/^https?:\/\/[^\s\/]+\.[^\s\/]{2,}/.test(s)) return ""
  return s
}

// GET /keys/balance -> { keys: [{ id: "apikey:...", balance }] }. Session
// balances parked on provider nodes still spend, so they count. Returns 0
// when the endpoint is missing or empty — wallet total alone is then right.
function keysTotal(json) {
  var obj = unwrap(parseJson(json))
  if (!obj || !(obj.keys instanceof Array)) return 0
  var total = 0
  for (var i = 0; i < obj.keys.length; i++) {
    var key = obj.keys[i]
    if (!key || String(key.id || "").indexOf("apikey:") !== 0) continue
    var v = Number(key.balance)
    if (isFinite(v)) total += v
  }
  return total
}

// GET /models -> { models: [...] }. Returns count or -1 when unknown.
function modelCount(json) {
  var obj = unwrap(parseJson(json))
  if (!obj || !(obj.models instanceof Array)) return -1
  return obj.models.length
}

// GET /usage?limit=1 -> the routstrd CLI treats the payload as UsageEntry[]
// but tolerates wrapping; mirror that here.
function latestUsage(json) {
  var obj = null
  try {
    obj = JSON.parse(String(json || ""))
  } catch (e) {
    return null
  }
  var list = obj instanceof Array ? obj
    : (obj && obj.output instanceof Array) ? obj.output
    : (obj && obj.entries instanceof Array) ? obj.entries
    : null
  if (!list || list.length === 0) return null
  var entry = list[0]
  if (!entry || typeof entry !== "object") return null
  return {
    modelId: String(entry.modelId || ""),
    satsCost: isFinite(Number(entry.satsCost)) ? Number(entry.satsCost) : 0,
    client: String(entry.client || ""),
    timestamp: isFinite(Number(entry.timestamp)) ? Number(entry.timestamp) : 0
  }
}

// Disconnect script for one explicit client. `routstrd clients delete` only
// removes the daemon-side record; the integration file keeps pointing at a
// revoked key, which for Claude Code means a broken agent that still
// bypasses the user's Anthropic login. So: delete the client id first (that
// also stops the daemon's 21-minute integration rewriter), then remove only
// our keys from the file with jq, atomically, and only when they still point
// at this daemon. The delete goes over HTTP because 404 — id already gone —
// must count as success, and the CLI collapses it into a generic failure.
// Pure function of its inputs so tests can execute the exact same script.
function disconnectScript(id, configPath, baseUrl) {
  var quotedPath = "'" + String(configPath).replace(/'/g, "'\\''") + "'"
  var script =
    "code=$(curl -sS -o /dev/null -w '%{http_code}' --max-time 10 -X POST"
    + " -H 'Content-Type: application/json' -d '{\"id\":\"" + id + "\"}' "
    + baseUrl + "/clients/delete); "
    + "case \"$code\" in 200|404) ;; *) echo \"daemon refused the delete (HTTP $code)\" >&2; exit 1;; esac; "
    + "cfg=" + quotedPath + "; [ -f \"$cfg\" ] || exit 0; "
  var jqProgram
  if (id === "claude-code") {
    script +=
      "jq -e '(.env.ANTHROPIC_BASE_URL // \"\") | test(\"^https?://(127\\\\.0\\\\.0\\\\.1|localhost):8008/?$\")' \"$cfg\" >/dev/null || exit 0; "
    jqProgram =
      "del(.env.ANTHROPIC_AUTH_TOKEN, .env.ANTHROPIC_BASE_URL, .env.ANTHROPIC_DEFAULT_OPUS_MODEL,"
      + " .env.ANTHROPIC_DEFAULT_SONNET_MODEL, .env.ANTHROPIC_DEFAULT_HAIKU_MODEL)"
      + " | if .env == {} then del(.env) else . end"
  } else if (id === "pi-agent") {
    jqProgram = "del(.providers.routstr)"
  } else {
    jqProgram =
      "del(.models.providers.routstr)"
      + " | if ((.agents.defaults.model.primary // \"\") | startswith(\"routstr/\")) then del(.agents.defaults.model) else . end"
  }
  script +=
    "tmp=$(mktemp \"$cfg.XXXXXX\") || exit 1; "
    + "if jq '" + jqProgram + "' \"$cfg\" > \"$tmp\"; then mv \"$tmp\" \"$cfg\"; else rm -f \"$tmp\"; exit 1; fi"
  return script
}

// ~/.claude/settings.json -> is the Anthropic env hijacked toward the local
// daemon. Only a BASE_URL that points at loopback:8008 counts as ours —
// a corporate proxy or a real Anthropic setup must never be "wired".
function claudeState(text) {
  var obj = parseJson(text)
  var env = obj && obj.env && typeof obj.env === "object" ? obj.env : null
  var base = env ? String(env.ANTHROPIC_BASE_URL || "") : ""
  var wired = /^https?:\/\/(127\.0\.0\.1|localhost):8008\/?$/.test(base)
  return { wired: wired }
}

// ~/.pi/agent/models.json -> providers.routstr, additive.
function piState(text) {
  var obj = parseJson(text)
  var provider = obj && obj.providers && typeof obj.providers === "object" ? obj.providers.routstr : null
  if (!provider || typeof provider !== "object") return { wired: false, models: 0 }
  var models = provider.models instanceof Array ? provider.models.length : 0
  return { wired: true, models: models }
}

// ~/.openclaw/openclaw.json -> models.providers.routstr, plus whether the
// default model block currently points at Routstr (clients add overwrites
// agents.defaults.model; disconnect only clears it when it is still ours).
function openclawState(text) {
  var obj = parseJson(text)
  var providers = obj && obj.models && typeof obj.models === "object"
    && obj.models.providers && typeof obj.models.providers === "object" ? obj.models.providers : null
  var provider = providers ? providers.routstr : null
  var defaults = obj && obj.agents && typeof obj.agents === "object"
    && obj.agents.defaults && typeof obj.agents.defaults === "object" ? obj.agents.defaults : null
  var primary = defaults && defaults.model && typeof defaults.model === "object"
    ? String(defaults.model.primary || "") : ""
  if (!provider || typeof provider !== "object")
    return { wired: false, models: 0, defaultIsRoutstr: primary.indexOf("routstr/") === 0 }
  var models = provider.models instanceof Array ? provider.models.length : 0
  return { wired: true, models: models, defaultIsRoutstr: primary.indexOf("routstr/") === 0 }
}

// ~/.config/opencode/opencode.json -> is provider.routstr present, and with
// how many models. `exists` is false only when the text does not parse.
function opencodeState(text) {
  var obj = parseJson(text)
  if (!obj) return { exists: false, wired: false, models: 0 }
  var provider = obj.provider && typeof obj.provider === "object" ? obj.provider.routstr : null
  if (!provider || typeof provider !== "object") return { exists: true, wired: false, models: 0 }
  var models = provider.models && typeof provider.models === "object" ? Object.keys(provider.models).length : 0
  return { exists: true, wired: true, models: models }
}

// A pasted Cashu token, with optional URI scheme prefixes stripped. Returns
// the bare token, or "" when the paste is clearly not one (a Lightning
// invoice, a URL, whitespace garbage). The daemon does the real validation.
function normalizeCashuToken(raw) {
  var s = String(raw || "").trim()
  s = s.replace(/^web\+cashu:\/\//i, "").replace(/^cashu:\/\//i, "").replace(/^cashu:/i, "").trim()
  if (!/^cashu[A-Za-z0-9]/.test(s)) return ""
  if (/\s/.test(s)) return ""
  return s
}

// Defense in depth for surfaced error text: a daemon/cocod message that
// echoes the pasted token must not reach a label or a log line.
function maskCashuTokens(text) {
  return String(text || "").replace(/cashu[A-Za-z0-9+\/=_-]{8,}/g, "cashu…")
}

// POST /wallet/receive/cashu -> { output: { message, amount, unit } } on
// success, { error } on failure (non-200; curl runs without -f so the body
// still arrives). amount is decoded from the token; unit is sat or msat.
function cashuResult(json) {
  var raw = parseJson(json)
  if (!raw) return { ok: false, amountSats: 0, error: "" }
  if (raw.error) return { ok: false, amountSats: 0, error: maskCashuTokens(raw.error) }
  var obj = unwrap(raw)
  if (!obj || (obj.message === undefined && obj.amount === undefined))
    return { ok: false, amountSats: 0, error: "" }
  var amount = Number(obj.amount)
  var sats = obj.unit === "msat" ? Math.floor(amount / 1000) : amount
  return { ok: true, amountSats: isFinite(sats) && sats > 0 ? sats : 0, error: "" }
}

// POST /wallet/receive/bolt11 -> { invoice, amount, mintUrl }
function invoiceFrom(json) {
  var obj = unwrap(parseJson(json))
  if (!obj) return ""
  if (typeof obj.invoice === "string" && obj.invoice !== "") return obj.invoice
  return ""
}

// Usage record for the first-party omarchy.agents panel, shaped like
// omarchy-agent-usage-fireworks output (the prepaid precedent). The panel
// accepts records from any writer in the usage dir; a collector binary is
// impossible (they are discovered only in root-owned $OMARCHY_PATH/bin).
// Sats are reported as currency "SAT" — the panel prefixes unknown codes
// verbatim. hasPromptStats is false because Routstr counts requests, and an
// agent loop makes many requests per prompt; requests feed the day strip as
// messageCount instead. `estimated` is true because funded is inferred as
// remaining + spent, not a real ledger.
function usageRecord(balanceSats, summaryJson, nowMs) {
  var summary = unwrap(parseJson(summaryJson))
  if (!summary || typeof summary !== "object") return null
  var totals = summary.totals && typeof summary.totals === "object" ? summary.totals : null
  var days = summary.days instanceof Array ? summary.days : []
  var models = summary.models instanceof Array ? summary.models : []

  function localDate(ms) {
    var d = new Date(ms)
    var m = d.getMonth() + 1
    var day = d.getDate()
    return d.getFullYear() + "-" + (m < 10 ? "0" + m : m) + "-" + (day < 10 ? "0" + day : day)
  }

  var byDate = {}
  var activeDates = []
  for (var i = 0; i < days.length; i++) {
    var row = days[i]
    if (!row || typeof row.date !== "string") continue
    byDate[row.date] = row
    if (Number(row.requests) > 0) activeDates.push(row.date)
  }
  activeDates.sort()

  var recentDays = []
  for (var back = 6; back >= 0; back--) {
    var date = localDate(nowMs - back * 86400000)
    var r = byDate[date]
    recentDays.push({ date: date, messageCount: r ? (Number(r.requests) || 0) : 0 })
  }

  var today = byDate[localDate(nowMs)]
  var modelUsage = {}
  for (var j = 0; j < models.length; j++) {
    var m = models[j]
    if (!m || typeof m.modelId !== "string" || m.modelId === "") continue
    modelUsage[m.modelId] = {
      inputTokens: Number(m.promptTokens) || 0,
      outputTokens: Number(m.completionTokens) || 0,
      cacheReadInputTokens: 0,
      cacheCreationInputTokens: 0
    }
  }

  var spent = totals ? (Number(totals.satsCost) || 0) : 0
  var remaining = Number(balanceSats)
  if (!isFinite(remaining) || remaining < 0) remaining = 0

  var record = {
    schemaVersion: 1,
    id: "routstr",
    name: "Routstr",
    updatedAt: new Date(nowMs).toISOString(),
    ready: true,
    hasLocalStats: true,
    scope: "device",
    hasPromptStats: false,
    tierLabel: "Prepaid",
    usageStatusText: "",
    authHelpText: "",
    limits: [],
    todayPrompts: today ? (Number(today.requests) || 0) : 0,
    todaySessions: 0,
    todayTotalTokens: today ? (Number(today.totalTokens) || 0) : 0,
    todayTokensByModel: {},
    recentDays: recentDays,
    totalPrompts: totals ? (Number(totals.requests) || 0) : 0,
    totalSessions: 0,
    activeDays: activeDates.length,
    activeDates: activeDates,
    modelUsage: modelUsage,
    balance: {
      remaining: remaining,
      spent: spent,
      currency: "SAT",
      estimated: true
    }
  }
  if (remaining + spent > 0) record.balance.funded = remaining + spent
  return record
}

// Change key for the usage record: everything except updatedAt, plus a
// half-hour bucket so a fresh timestamp still lands twice an hour.
function usageRecordKey(record, nowMs) {
  if (!record) return ""
  var clone = JSON.parse(JSON.stringify(record))
  delete clone.updatedAt
  return JSON.stringify(clone) + "|" + Math.floor(nowMs / 1800000)
}

// Middle-elide long invoice strings for display.
function elideMiddle(text, max) {
  var s = String(text || "")
  if (s.length <= max) return s
  var keep = Math.max(4, Math.floor((max - 1) / 2))
  return s.substring(0, keep) + "…" + s.substring(s.length - keep)
}

function statusLabel(probed, installed, onboarded, daemonUp, models) {
  // The daemon answering on loopback beats whatever the CLI probe thinks —
  // a Docker routstrd is up without `routstrd` ever being on PATH.
  if (daemonUp) {
    if (models >= 0) return "Daemon running · " + models + " model" + (models === 1 ? "" : "s")
    return "Daemon running"
  }
  if (!probed) return "Checking…"
  if (!installed) return "routstrd is not installed"
  if (!onboarded) return "Wallet not onboarded"
  return "Daemon stopped"
}
