// The shell scripts Model.js builds, executed for real against fixture
// configs. These are the tests that matter most: the scripts edit the user's
// agent configs and are the one place the plugin writes files it did not
// create, and every failure mode here is invisible from QML.

import { test, before, after, describe } from "node:test"
import assert from "node:assert/strict"
import { execFile, execFileSync } from "node:child_process"
import { mkdtempSync, rmSync, writeFileSync, readFileSync, readdirSync, existsSync, chmodSync, statSync } from "node:fs"
import { tmpdir } from "node:os"
import { join } from "node:path"
import http from "node:http"

import { Model } from "./model.mjs"

// ---- A stand-in for routstrd's POST /clients/delete. The disconnect script
// must delete the daemon-side client record before it touches the config, so
// every disconnect test needs an endpoint to talk to.

let server
let baseUrl
let deleteCalls = []
let deleteStatus = 200

before(async () => {
  server = http.createServer((req, res) => {
    let body = ""
    req.on("data", (chunk) => { body += chunk })
    req.on("end", () => {
      deleteCalls.push({ url: req.url, method: req.method, body })
      res.writeHead(deleteStatus, { "Content-Type": "application/json" })
      res.end(JSON.stringify(deleteStatus === 200 ? { output: { ok: true } } : { error: "nope" }))
    })
  })
  await new Promise((resolve) => server.listen(0, "127.0.0.1", resolve))
  baseUrl = `http://127.0.0.1:${server.address().port}`
})

after(() => server.close())

// ---- Fixtures

let dir
function fixture(name, contents) {
  if (!dir) dir = mkdtempSync(join(tmpdir(), "routstr-test-"))
  const path = join(dir, name)
  writeFileSync(path, typeof contents === "string" ? contents : JSON.stringify(contents, null, 2))
  return path
}

function read(path) {
  return JSON.parse(readFileSync(path, "utf8"))
}

function backupsFor(path) {
  const base = path.split("/").pop()
  return readdirSync(dir).filter((f) => f.startsWith(base + ".bak-routstr-"))
}

// Runs a generated script the way Service.qml does: `bash -c <script>`.
// `pathOverride` simulates a machine where a dependency is missing.
//
// Async on purpose. The stub daemon above lives in this process, so a
// synchronous child would block the event loop and the script's curl could
// never be answered — every disconnect test would sit through curl's full
// --max-time before failing.
function run(script, pathOverride) {
  const env = { ...process.env }
  if (pathOverride !== undefined) env.PATH = pathOverride
  return new Promise((resolve) => {
    execFile("bash", ["-c", script], { env, encoding: "utf8" }, (error, stdout, stderr) => {
      resolve({ code: error ? error.code : 0, stdout: String(stdout || ""), stderr: String(stderr || "") })
    })
  })
}

// A PATH with coreutils and curl but deliberately no jq.
function pathWithoutJq() {
  const stripped = mkdtempSync(join(tmpdir(), "routstr-nojq-"))
  for (const tool of ["bash", "curl", "cp", "mv", "rm", "mktemp", "date", "chmod", "head", "mkdir", "rmdir", "sleep"]) {
    try {
      const real = execFileSync("/bin/bash", ["-c", `command -v ${tool}`], { encoding: "utf8" }).trim()
      if (real.startsWith("/")) execFileSync("ln", ["-sf", real, join(stripped, tool)])
    } catch { /* not present; the script will fail on it honestly */ }
  }
  return stripped
}

const CLAUDE_OURS = {
  env: {
    ANTHROPIC_AUTH_TOKEN: "sk-routstr-test",
    ANTHROPIC_BASE_URL: "http://127.0.0.1:8008",
    ANTHROPIC_DEFAULT_OPUS_MODEL: "some/opus",
    ANTHROPIC_DEFAULT_SONNET_MODEL: "some/sonnet",
    ANTHROPIC_DEFAULT_HAIKU_MODEL: "some/haiku",
    SOMETHING_ELSE: "keep me"
  },
  permissions: { allow: ["Bash"] }
}

const CLAUDE_FOREIGN = {
  env: {
    ANTHROPIC_AUTH_TOKEN: "sk-ant-the-users-real-key",
    ANTHROPIC_BASE_URL: "https://api.anthropic.com"
  }
}

describe("disconnectScript / claude-code", () => {
  test("strips only our keys and backs the file up first", async () => {
    const cfg = fixture("claude-ours.json", CLAUDE_OURS)
    const result = await run(Model.disconnectScript("claude-code", cfg, baseUrl))

    assert.equal(result.code, 0, result.stderr)
    const after = read(cfg)
    assert.deepEqual(after.env, { SOMETHING_ELSE: "keep me" }, "our env keys go, the user's stay")
    assert.deepEqual(after.permissions, { allow: ["Bash"] }, "unrelated settings survive")
    assert.equal(backupsFor(cfg).length, 1, "exactly one .bak-routstr-* is left behind")
  })

  test("deletes the daemon client record before editing", async () => {
    deleteCalls = []
    const cfg = fixture("claude-delete.json", CLAUDE_OURS)
    await run(Model.disconnectScript("claude-code", cfg, baseUrl))

    assert.equal(deleteCalls.length, 1)
    assert.equal(deleteCalls[0].url, "/clients/delete")
    assert.deepEqual(JSON.parse(deleteCalls[0].body), { id: "claude-code" })
  })

  test("leaves a foreign Anthropic config completely alone", async () => {
    const cfg = fixture("claude-foreign.json", CLAUDE_FOREIGN)
    const before = readFileSync(cfg, "utf8")
    const result = await run(Model.disconnectScript("claude-code", cfg, baseUrl))

    assert.equal(result.code, 0, "not ours is not an error")
    assert.equal(readFileSync(cfg, "utf8"), before, "a real Anthropic login is never touched")
  })

  // The regression this suite was written for. `jq -e` answers non-zero for
  // "not ours", for "could not parse", AND for "jq is not installed"; the
  // guard used to be `|| exit 0`, so all three reported a clean disconnect.
  // Since the daemon-side key is revoked by then, that left Claude Code
  // broken AND still bypassing the user's Anthropic login, while the panel
  // showed "Using its own Anthropic login".
  test("reports failure when the config cannot be parsed, and changes nothing", async () => {
    const cfg = fixture("claude-broken.json", '{"env": {"ANTHROPIC_BASE_URL": "http://127.0.0.1:8008",,,}')
    const before = readFileSync(cfg, "utf8")
    const result = await run(Model.disconnectScript("claude-code", cfg, baseUrl))

    assert.notEqual(result.code, 0, "a config we cannot read must not report success")
    assert.equal(readFileSync(cfg, "utf8"), before)
    assert.match(result.stderr, /could not read the Claude settings file/)
  })

  test("reports failure when jq is missing, before deleting the daemon client", async () => {
    deleteCalls = []
    const cfg = fixture("claude-nojq.json", CLAUDE_OURS)
    const before = readFileSync(cfg, "utf8")
    const result = await run(Model.disconnectScript("claude-code", cfg, baseUrl), pathWithoutJq())

    assert.notEqual(result.code, 0)
    assert.match(result.stderr, /jq is required/)
    assert.equal(readFileSync(cfg, "utf8"), before, "the hijack is left intact rather than half-removed")
    assert.equal(deleteCalls.length, 0, "the daemon key is not revoked when we know we cannot finish")
  })

  test("does not edit the config when the daemon refuses the delete", async () => {
    deleteStatus = 500
    const cfg = fixture("claude-daemon-500.json", CLAUDE_OURS)
    const before = readFileSync(cfg, "utf8")
    const result = await run(Model.disconnectScript("claude-code", cfg, baseUrl))
    deleteStatus = 200

    assert.notEqual(result.code, 0)
    assert.equal(readFileSync(cfg, "utf8"), before)
    assert.match(result.stderr, /daemon refused the delete \(HTTP 500\)/)
  })

  test("treats a 404 from the daemon as already gone", async () => {
    deleteStatus = 404
    const cfg = fixture("claude-404.json", CLAUDE_OURS)
    const result = await run(Model.disconnectScript("claude-code", cfg, baseUrl))
    deleteStatus = 200

    assert.equal(result.code, 0, result.stderr)
    assert.deepEqual(read(cfg).env, { SOMETHING_ELSE: "keep me" })
  })

  test("succeeds with nothing to do when the config does not exist", async () => {
    const result = await run(Model.disconnectScript("claude-code", join(dir || tmpdir(), "no-such-file.json"), baseUrl))
    assert.equal(result.code, 0, result.stderr)
  })

  test("preserves the config's file mode", async () => {
    const cfg = fixture("claude-mode.json", CLAUDE_OURS)
    chmodSync(cfg, 0o644)
    await run(Model.disconnectScript("claude-code", cfg, baseUrl))

    assert.equal(statSync(cfg).mode & 0o777, 0o644, "editing one key must not re-permission the file")
  })

  test("survives a path containing a single quote", async () => {
    const cfg = fixture("clau'de.json", CLAUDE_OURS)
    const result = await run(Model.disconnectScript("claude-code", cfg, baseUrl))

    assert.equal(result.code, 0, result.stderr)
    assert.deepEqual(read(cfg).env, { SOMETHING_ELSE: "keep me" })
  })
})

describe("disconnectScript / other clients", () => {
  test("pi-agent removes only providers.routstr", async () => {
    const cfg = fixture("pi.json", { providers: { routstr: { models: [1, 2] }, ollama: { models: [] } } })
    const result = await run(Model.disconnectScript("pi-agent", cfg, baseUrl))

    assert.equal(result.code, 0, result.stderr)
    assert.deepEqual(read(cfg), { providers: { ollama: { models: [] } } })
  })

  test("openclaw clears the default model only while it is still ours", async () => {
    const ours = fixture("openclaw-ours.json", {
      models: { providers: { routstr: {}, other: {} } },
      agents: { defaults: { model: { primary: "routstr/some-model" } } }
    })
    assert.equal((await run(Model.disconnectScript("openclaw", ours, baseUrl))).code, 0)
    assert.deepEqual(read(ours), { models: { providers: { other: {} } }, agents: { defaults: {} } })

    const theirs = fixture("openclaw-theirs.json", {
      models: { providers: { routstr: {} } },
      agents: { defaults: { model: { primary: "anthropic/claude" } } }
    })
    assert.equal((await run(Model.disconnectScript("openclaw", theirs, baseUrl))).code, 0)
    assert.deepEqual(read(theirs).agents.defaults.model, { primary: "anthropic/claude" })
  })

  test("a malformed config fails rather than silently doing nothing", async () => {
    const cfg = fixture("pi-broken.json", "{not json")
    const result = await run(Model.disconnectScript("pi-agent", cfg, baseUrl))
    assert.notEqual(result.code, 0)
  })
})

describe("providerToggleScript", () => {
  test("names jq when jq is what is missing", async () => {
    const result = await run(Model.providerToggleScript("https://provider.example", true, baseUrl), pathWithoutJq())
    assert.notEqual(result.code, 0)
    assert.match(result.stderr, /jq is required/)
    assert.doesNotMatch(result.stderr, /no longer in the daemon list/, "a missing jq must not read as a discovery change")
  })

  test("does not blame discovery for a daemon error", async () => {
    // Nothing is listening on this port, so the list fetch fails outright.
    const result = await run(Model.providerToggleScript("https://provider.example", true, "http://127.0.0.1:1"))
    assert.notEqual(result.code, 0)
    assert.match(result.stderr, /could not read the provider list/)
  })

  test("quotes a provider URL containing a single quote", async () => {
    // Provider URLs come from Nostr, so they are attacker-influenced input.
    const canary = join(dir || tmpdir(), "canary-provider")
    const script = Model.providerToggleScript(`https://x'; touch ${canary}; echo '`, true, "http://127.0.0.1:1")
    await run(script)
    assert.equal(existsSync(canary), false, "the URL must not be able to run a command")
  })
})

describe("singleFlightFragment", () => {
  test("exactly one of several concurrent runs proceeds", async () => {
    const lock = join(dir || mkdtempSync(join(tmpdir(), "routstr-test-")), "wire.lock")
    const marker = lock + ".ran"
    const script = Model.singleFlightFragment(lock) + `sleep 0.4; echo x >> ${JSON.stringify(marker)}`

    const results = (await Promise.all([1, 2, 3, 4].map(() => run(script)))).map((r) => r.code)

    const winners = results.filter((c) => c === 0)
    const losers = results.filter((c) => c === Model.exTempfail())
    assert.equal(winners.length, 1, `expected one winner, got ${JSON.stringify(results)}`)
    assert.equal(losers.length, 3, "the rest must back off with EX_TEMPFAIL, not fail")
    assert.equal(readFileSync(marker, "utf8").trim().split("\n").length, 1, "the guarded body ran once")
  })

  test("releases the lock so the next run can take it", async () => {
    const lock = join(dir || tmpdir(), "wire-sequential.lock")
    const script = Model.singleFlightFragment(lock) + "true"
    assert.equal((await run(script)).code, 0)
    assert.equal((await run(script)).code, 0, "a released lock must not wedge the next attempt")
    assert.equal(existsSync(lock), false)
  })
})

after(() => {
  if (dir) rmSync(dir, { recursive: true, force: true })
})
