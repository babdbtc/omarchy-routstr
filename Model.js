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

// "21000" -> "21 000". Negative/unknown -> em dash.
//
// The group separator is U+00A0 (no-break space), not the typographically
// nicer U+2009 (thin space). The bar's default monospace (CaskaydiaCove
// Nerd Font, via `fc-match monospace`) carries no U+2009 glyph, so Qt fell
// back to another font for that one character and handed the whole line
// that font's metrics: measured at 12px, "21 000" came out 7.0px taller
// than "210" with 5.3px of the growth below the baseline, which floated the
// digits ~1.8px high inside any vertically centered label. U+00A0 is in the
// font and measures identically to bare digits. Any replacement separator
// must be inside the font's coverage — check `fc-list ':charset=<cp>'`.
function formatSats(n) {
  if (n === undefined || n === null || !isFinite(n) || n < 0) return "—"
  var s = String(Math.floor(n))
  var out = ""
  for (var i = 0; i < s.length; i++) {
    if (i > 0 && (s.length - i) % 3 === 0) out += "\u00a0"
    out += s.charAt(i)
  }
  return out
}

// "3 models", "1 model" — count + pluralized noun, shared by every label
// that counts something.
function countLabel(n, noun) {
  return n + " " + noun + (n === 1 ? "" : "s")
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

// GET /models -> options for a searchable dropdown. value/label are the raw
// id (what agent configs reference as routstr/<id>), description the
// human name.
function modelOptions(json) {
  var obj = unwrap(parseJson(json))
  if (!obj || !(obj.models instanceof Array)) return []
  var options = []
  for (var i = 0; i < obj.models.length; i++) {
    var m = obj.models[i]
    if (!m || typeof m.id !== "string" || m.id === "") continue
    options.push({ value: m.id, label: m.id, description: String(m.name || "") })
  }
  return options
}

// GET /providers -> { providers: [{index, baseUrl, disabled}], ... }.
function providerRows(json) {
  var obj = unwrap(parseJson(json))
  if (!obj || !(obj.providers instanceof Array)) return []
  var rows = []
  for (var i = 0; i < obj.providers.length; i++) {
    var p = obj.providers[i]
    if (!p || typeof p.baseUrl !== "string" || p.baseUrl === "") continue
    rows.push({
      url: p.baseUrl,
      host: hostOf(p.baseUrl),
      disabled: p.disabled === true
    })
  }
  return rows
}

// PROVIDERS header line: "3 providers · 1 disabled".
function providerSummary(rows) {
  var list = rows instanceof Array ? rows : []
  var off = 0
  for (var i = 0; i < list.length; i++) {
    if (list[i] && list[i].disabled) off++
  }
  var s = countLabel(list.length, "provider")
  if (off > 0) s += " · " + off + " disabled"
  return s
}

// POSIX single-quote escaping, the same rule as Commons/Util.shellQuote.
// Duplicated deliberately: this file is a `.pragma library`, so it cannot
// import the QML singleton, and every script below has to quote its inputs
// (mint URLs and Nostr-supplied provider URLs are attacker-influenced).
// One copy here rather than one per call site.
function shellQuote(value) {
  return "'" + String(value === undefined || value === null ? "" : value).replace(/'/g, "'\\''") + "'"
}

// Every config-editing and provider script below is jq-driven. Check for it
// up front so a missing jq reports itself, instead of surfacing as whatever
// the next command happens to say when its input is empty.
function requireJqFragment() {
  return "command -v jq >/dev/null 2>&1 "
    + "|| { echo 'jq is required for this action but is not installed' >&2; exit 1; }; "
}

// Enable/disable one provider. The daemon's toggle endpoints take indices
// into its *current* provider list, and a Nostr refresh replaces that list
// wholesale — a remembered index can silently hit the wrong provider. So
// the script re-reads /providers and resolves the URL to an index in the
// same breath as the POST. Pure function of its inputs, tested as-is.
function providerToggleScript(url, disable, baseUrl) {
  var quotedUrl = shellQuote(url)
  var verb = disable ? "disable" : "enable"
  // -f on the list fetch: without it an HTTP 500 body reaches jq, yields no
  // index, and the failure reads as "provider no longer in the daemon list"
  // — blaming discovery for a daemon error.
  return requireJqFragment()
    + "list=$(curl -fsS --max-time 8 " + baseUrl + "/providers) "
    + "|| { echo 'could not read the provider list from routstrd' >&2; exit 1; }; "
    + "idx=$(printf %s \"$list\" | jq -r --arg u " + quotedUrl + " "
    + "'(.output // .) | .providers[] | select(.baseUrl == $u) | .index' | head -n1); "
    + "[ -n \"$idx\" ] || { echo 'provider no longer in the daemon list' >&2; exit 1; }; "
    + "out=$(curl -sS --max-time 8 -X POST -H 'Content-Type: application/json' "
    + "-d \"{\\\"indices\\\":[$idx]}\" " + baseUrl + "/providers/" + verb + ") || exit 1; "
    + "printf %s \"$out\" | jq -e '(.output // .) | has(\"message\")' >/dev/null 2>&1 "
    + "|| { printf %s \"$out\" | jq -r '.error // \"" + verb + " failed\"' 2>/dev/null >&2; exit 1; }"
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

// Shared shell fragments for the config-editing scripts. Both expect $cfg
// to hold the config path.

// One .bak-routstr-<ts> beside $cfg before the plugin's first write to it;
// a no-op when any backup already exists (connect and disconnect both call
// this, whichever runs first wins).
function backupOnceFragment() {
  return "set -- \"$cfg\".bak-routstr-*; [ -e \"$1\" ] || cp -p \"$cfg\" \"$cfg.bak-routstr-$(date +%Y%m%d%H%M%S)\"; "
}

// jq-edit $cfg in place, atomically: a sibling mktemp keeps the mv on the
// same filesystem, and a failed jq leaves the config untouched. mktemp makes
// 0600, and the mv carries that mode onto the config, so the original mode
// is copied across first — the plugin should not silently re-permission a
// file it only edited one key in.
function atomicJqEditFragment(jqProgram) {
  return "tmp=$(mktemp \"$cfg.XXXXXX\") || exit 1; "
    + "chmod --reference=\"$cfg\" \"$tmp\" 2>/dev/null; "
    + "if jq '" + jqProgram + "' \"$cfg\" > \"$tmp\"; then mv \"$tmp\" \"$cfg\"; else rm -f \"$tmp\"; exit 1; fi"
}

// Cross-instance mutex around a script that writes a shared file.
//
// One bar surface exists per monitor, so every Service instance reaches the
// same conclusion at the same moment — and auto-wire then runs N concurrent
// `routstrd clients add --opencode`, each a read-modify-write of the same
// opencode.json. mkdir is atomic on every POSIX filesystem: exactly one
// caller creates the directory, the rest exit 75 (EX_TEMPFAIL) having
// touched nothing, and pick the result up through the config watcher.
//
// The trap releases the lock on normal exit and on SIGTERM/SIGINT (a
// watchdog reap included). A SIGKILL would strand it, which is why it lives
// in $XDG_RUNTIME_DIR: worst case it clears at logout.
function singleFlightFragment(lockDir) {
  return "lock=" + shellQuote(lockDir) + "; mkdir \"$lock\" 2>/dev/null || exit 75; "
    + "trap 'rmdir \"$lock\" 2>/dev/null' EXIT INT TERM; "
}

// Exit code singleFlightFragment uses for "another instance holds the lock".
// A function rather than a bare top-level var: every other symbol QML reads
// out of this file is one, and a name that resolved to undefined would fail
// silently — the losing instances would report "clients add failed" instead
// of backing off quietly.
function exTempfail() { return 75 }

// First-run default model (DESIGN.md: "no default model? → set `model` to a
// cheap coding id from /models"). routstrd has no default-model surface,
// but `clients add --opencode` writes `small_model` — its own cheap pick
// from /models. Copy that into a missing/empty top-level `model` right
// after a successful add. `model`/`small_model` are OpenCode schema keys,
// not routstrd's drifting provider format, and a non-empty `model` is never
// overwritten (hard rule). Expects $cfg; runs only after clients add
// succeeded, so exit 0 is "nothing to do".
function opencodeDefaultModelFragment() {
  return "[ -f \"$cfg\" ] || exit 0; "
    + "jq -e '((.model // \"\") == \"\") and ((.small_model // \"\") | startswith(\"routstr/\"))' \"$cfg\" >/dev/null || exit 0; "
    + atomicJqEditFragment(".model = .small_model")
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
  var quotedPath = shellQuote(configPath)
  var script =
    // jq is checked before the daemon delete, not after. Deleting the client
    // record and then failing to clean the file leaves the config pointing at
    // a revoked key — for Claude Code, an agent that is broken *and* still
    // bypassing the Anthropic login, which DECISIONS.md calls strictly worse
    // than either connected or disconnected. Fail before touching anything.
    requireJqFragment()
    + "code=$(curl -sS -o /dev/null -w '%{http_code}' --max-time 10 -X POST"
    + " -H 'Content-Type: application/json' -d " + shellQuote(JSON.stringify({ id: String(id) })) + " "
    + baseUrl + "/clients/delete); "
    + "case \"$code\" in 200|404) ;; *) echo \"daemon refused the delete (HTTP $code)\" >&2; exit 1;; esac; "
    + "cfg=" + quotedPath + "; [ -f \"$cfg\" ] || exit 0; "
  var jqProgram
  if (id === "claude-code") {
    // Loopback:8008 is deliberately hardcoded here and in claudeState():
    // deriving a guard regex from baseUrl would drop the localhost
    // spelling and turn a safety check into string plumbing. If the
    // daemon address ever becomes configurable, change both together.
    //
    // The exit status has to be read precisely. `jq -e` answers 1 for "the
    // result was false or null" (a foreign Anthropic config — leave it
    // alone, exit 0) and 4 for "no output at all" (an empty file — nothing
    // to strip). Everything else is jq failing to read the file, which must
    // NOT be mistaken for "not ours": a bare `|| exit 0` reports a clean
    // disconnect while the hijack is still in place.
    script +=
      "jq -e '(.env.ANTHROPIC_BASE_URL // \"\") | test(\"^https?://(127\\\\.0\\\\.0\\\\.1|localhost):8008/?$\")' \"$cfg\" >/dev/null; "
      + "ours=$?; case $ours in 0) ;; 1|4) exit 0;; "
      + "*) echo 'could not read the Claude settings file — left it untouched' >&2; exit 1;; esac; "
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
  // Backup before the edit if none exists yet: connect makes one, but a
  // user who wired via the CLI arrives here with no .bak, and this must
  // not be the plugin's first un-backed-up write to their config.
  script += backupOnceFragment() + atomicJqEditFragment(jqProgram)
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

// The most one invoice may ask for. `invoiceSats` and the balance
// properties are QML ints (32-bit), and 21M sats is already far past what
// an inference wallet burns — beyond this a number is a typo, not an
// intent. The mint still has the final say on what it will actually issue.
var MAX_TOPUP_SATS = 21000000

// A typed top-up amount -> whole sats, or 0 when the input is not usable.
// Accepts the grouping this UI renders itself (and the thin space it used
// to render, so older copied values still work) plus the
// separators people paste (space, comma, underscore), so an amount copied
// off the panel round-trips.
function normalizeTopupSats(raw) {
  var s = String(raw === undefined || raw === null ? "" : raw).trim()
  s = s.replace(/[\u2009\u00a0\s,_]/g, "")
  if (!/^\+?\d+$/.test(s)) return 0
  var n = parseInt(s, 10)
  if (!isFinite(n) || n <= 0 || n > MAX_TOPUP_SATS) return 0
  return n
}

// Why normalizeTopupSats returned 0, for the panel's error line.
function topupError() {
  return "Top-ups are whole sats, from 1 to " + formatSats(MAX_TOPUP_SATS) + "."
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
    // Prompt counts stay zero, matching the fireworks precedent for
    // hasPromptStats: false — requests land in recentDays.messageCount.
    todayPrompts: 0,
    todaySessions: 0,
    todayTotalTokens: today ? (Number(today.totalTokens) || 0) : 0,
    todayTokensByModel: {},
    recentDays: recentDays,
    totalPrompts: 0,
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

// What state is a *wired* agent row actually in? Wiring is not the finish
// line: a perfectly connected agent still fails with an empty wallet, an
// empty daemon model list, or an empty model map in its own config.
//
// Returns one of "ready" | "unknown" | "no-models" | "no-agent-models" |
// "no-funds".
//
// `agentModels` is the count in this agent's *own* config, or -1 when the row
// does not track one (Claude Code takes its three models positionally, so
// there is no per-agent map to count). Without it, a config whose provider
// block carries no `models` key — opencodeState returns wired:true,models:0
// for exactly that — produces the self-contradicting "Ready to use · 0
// models", which is the failure this whole label exists to prevent.
//
// "unknown" is deliberately not folded into either side. -1 means "not polled
// yet", and while noModelsAlert may treat an unknown as *not a failure*
// before it badges the bar, the reverse does not follow: "ready" is a
// positive claim painted green, and a positive claim needs positive evidence.
// Service resets both counts to -1 whenever the daemon drops, and the AGENTS
// section renders as soon as daemonUp flips — one round-trip before the
// balance lands — so treating -1 as ready would flash a green all-clear over
// an empty wallet on every daemon start. Service.qml's own wired notification
// already gates on `balanceSats > 0` for the same reason.
function agentState(balanceSats, daemonModels, agentModels) {
  if (balanceSats < 0 || daemonModels < 0) return "unknown"
  if (daemonModels === 0) return "no-models"
  if (agentModels === 0) return "no-agent-models"
  if (balanceSats === 0) return "no-funds"
  return "ready"
}

function agentUsable(state) {
  return state === "ready"
}

// The subtitle for a wired agent row. "Connected" answers the question the
// plugin cares about; the user is asking a different one — "can I go and use
// it now, or is there another step?" — and the MODELS and PROVIDERS sections
// below look enough like setup to make that ambiguity expensive.
//
// Two kinds of trailing text, and they rank differently:
//
// `detail` describes the current config — a model count. It is descriptive,
// re-derivable by looking, and yields to a named blocker, because when
// something is wrong the blocker is the better use of one elided line.
//
// `note` is a standing warning about what wiring *did to the user's machine*:
// Claude Code's bypassed Anthropic login, the side effect its confirm dialog
// exists for. That outranks both, and it outranks the blocker specifically
// because a blocker is recoverable and stateless while the side effect
// persists until Disconnect. It is also the answer to "why is this agent
// behaving strangely", a question asked precisely when something else is
// wrong too — so it must survive the blocked state, and it leads there so
// ElideRight cannot eat it.
function agentReadyLabel(detail, note, state) {
  var blocker = state === "no-models" ? "no models available"
    : state === "no-agent-models" ? "no models in its config"
    : state === "no-funds" ? "top up to use it"
    : ""

  var parts = []
  if (blocker) {
    parts.push(note ? note : "Connected")
    parts.push(blocker)
  } else {
    parts.push(state === "ready" ? "Ready to use" : "Connected")
    if (detail) parts.push(detail)
    if (note) parts.push(note)
  }
  return parts.join(" · ")
}

function statusLabel(probed, installed, onboarded, daemonUp, models) {
  // The daemon answering on loopback beats whatever the CLI probe thinks —
  // a Docker routstrd is up without `routstrd` ever being on PATH.
  if (daemonUp) {
    if (models >= 0) return "Daemon running · " + countLabel(models, "model")
    return "Daemon running"
  }
  if (!probed) return "Checking…"
  if (!installed) return "routstrd is not installed"
  if (!onboarded) return "Wallet not onboarded"
  return "Daemon stopped"
}
