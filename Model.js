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
  var obj = parseJson(json)
  if (!obj || !obj.balances || typeof obj.balances !== "object") return -1
  var total = 0
  for (var mint in obj.balances) {
    var v = Number(obj.balances[mint])
    if (isFinite(v)) total += v
  }
  return total
}

// GET /keys/balance -> { keys: [{ id: "apikey:...", balance }] }. Session
// balances parked on provider nodes still spend, so they count. Returns 0
// when the endpoint is missing or empty — wallet total alone is then right.
function keysTotal(json) {
  var obj = parseJson(json)
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
  var obj = parseJson(json)
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

// POST /wallet/receive/bolt11 -> { invoice, amount, mintUrl }
function invoiceFrom(json) {
  var obj = parseJson(json)
  if (!obj) return ""
  if (typeof obj.invoice === "string" && obj.invoice !== "") return obj.invoice
  if (obj.output && typeof obj.output === "object" && typeof obj.output.invoice === "string") return obj.output.invoice
  return ""
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
