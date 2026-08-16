// The state machine behind what a wired agent row says and what colour it
// says it in. Pure, cheap to test, and the thing it gets wrong is expensive:
// a row that claims "Ready to use" in green over an empty wallet sends the
// user hunting for a bug instead of the top-up field a few rows up.

import { test, describe } from "node:test"
import assert from "node:assert/strict"

import { Model } from "./model.mjs"

// (balanceSats, daemonModels, agentModels)
const READY = [2100, 42, 20]

describe("agentState", () => {
  test("funded, daemon has models, agent config has models", () => {
    assert.equal(Model.agentState(...READY), "ready")
  })

  test("an agent that tracks no model count is still ready at -1", () => {
    // Claude Code takes its three models positionally, so -1 means "not
    // tracked" and must not be mistaken for "none".
    assert.equal(Model.agentState(2100, 42, -1), "ready")
  })

  test("empty wallet blocks", () => {
    assert.equal(Model.agentState(0, 42, 20), "no-funds")
  })

  test("empty daemon model list blocks", () => {
    assert.equal(Model.agentState(2100, 0, 20), "no-models")
  })

  test("empty model map in the agent's own config blocks", () => {
    // opencodeState returns wired:true, models:0 for a provider block with no
    // `models` key. Without this branch the row reads "Ready to use · 0
    // models" — in green, with a tick.
    assert.equal(Model.agentState(2100, 42, 0), "no-agent-models")
  })

  test("unpolled counts are unknown, never ready", () => {
    // Service resets both to -1 when the daemon drops, and the AGENTS section
    // renders one round-trip before the balance lands. Reading -1 as ready
    // would flash a green all-clear over an empty wallet on every start.
    assert.equal(Model.agentState(-1, -1, 20), "unknown")
    assert.equal(Model.agentState(-1, 42, 20), "unknown")
    assert.equal(Model.agentState(2100, -1, 20), "unknown")
  })

  test("a daemon blocker outranks an agent blocker", () => {
    // Nothing routes at all with an empty daemon list, so naming the agent's
    // own empty map first would send the user to fix the wrong thing.
    assert.equal(Model.agentState(0, 0, 0), "no-models")
  })

  test("a low but non-zero balance is still ready", () => {
    // lowBalanceSats has its own urgent warning in the top-up section and its
    // own bar badge. The row must not re-litigate it by claiming unusable.
    assert.equal(Model.agentState(1, 42, 20), "ready")
  })
})

describe("agentUsable", () => {
  test("only ready is usable", () => {
    assert.equal(Model.agentUsable("ready"), true)
    for (const s of ["unknown", "no-models", "no-agent-models", "no-funds"])
      assert.equal(Model.agentUsable(s), false, s)
  })
})

describe("agentReadyLabel", () => {
  test("says ready and keeps the row's own detail", () => {
    assert.equal(Model.agentReadyLabel("42 models", "", "ready"), "Ready to use · 42 models")
  })

  test("says ready with no detail to add", () => {
    assert.equal(Model.agentReadyLabel("", "", "ready"), "Ready to use")
  })

  test("a named blocker displaces the detail", () => {
    assert.equal(Model.agentReadyLabel("42 models", "", "no-funds"), "Connected · top up to use it")
    assert.equal(Model.agentReadyLabel("42 models", "", "no-models"), "Connected · no models available")
    assert.equal(Model.agentReadyLabel("0 models", "", "no-agent-models"), "Connected · no models in its config")
  })

  test("unknown keeps the detail and claims nothing", () => {
    assert.equal(Model.agentReadyLabel("42 models", "", "unknown"), "Connected · 42 models")
    assert.equal(Model.agentReadyLabel("", "", "unknown"), "Connected")
  })

  test("never claims ready outside the ready state", () => {
    for (const s of ["unknown", "no-models", "no-agent-models", "no-funds"])
      assert.ok(!Model.agentReadyLabel("42 models", "", s).startsWith("Ready"), s)
  })

  test("never pairs a ready claim with a zero count", () => {
    // The regression this whole state machine exists for. Walk every
    // combination and assert the two can never co-occur.
    for (const balance of [-1, 0, 1, 2100])
      for (const daemon of [-1, 0, 42])
        for (const agent of [-1, 0, 20]) {
          const state = Model.agentState(balance, daemon, agent)
          const label = Model.agentReadyLabel(Model.countLabel(agent, "model"), "", state)
          // \b so "20 models" does not read as a zero count.
          if (label.startsWith("Ready"))
            assert.ok(!/\b0 models/.test(label),
              `ready claim with zero models at (${balance}, ${daemon}, ${agent}): ${label}`)
        }
  })

  test("carries a composed detail through unchanged", () => {
    assert.equal(
      Model.agentReadyLabel("42 models · default model set", "", "ready"),
      "Ready to use · 42 models · default model set",
    )
  })
})

describe("agentReadyLabel / the standing note", () => {
  const NOTE = "Anthropic login bypassed"

  test("rides along in the good state", () => {
    assert.equal(Model.agentReadyLabel("", NOTE, "ready"), "Ready to use · " + NOTE)
  })

  test("survives every blocker, and leads so elision cannot eat it", () => {
    // The whole point: Claude Code stops working, the user asks why, and the
    // answer is that its Anthropic login is bypassed. That fact must not be
    // the thing that got dropped.
    for (const s of ["no-funds", "no-models", "no-agent-models"]) {
      const label = Model.agentReadyLabel("", NOTE, s)
      assert.ok(label.startsWith(NOTE), `${s}: ${label}`)
    }
    assert.equal(Model.agentReadyLabel("", NOTE, "no-funds"), NOTE + " · top up to use it")
  })

  test("survives the unknown state", () => {
    assert.equal(Model.agentReadyLabel("", NOTE, "unknown"), "Connected · " + NOTE)
  })

  test("is never dropped, in any state, ever", () => {
    for (const balance of [-1, 0, 1, 2100])
      for (const daemon of [-1, 0, 42])
        for (const agent of [-1, 0, 20]) {
          const state = Model.agentState(balance, daemon, agent)
          const label = Model.agentReadyLabel("42 models", NOTE, state)
          assert.ok(label.includes(NOTE),
            `note dropped at (${balance}, ${daemon}, ${agent}) → ${state}: ${label}`)
        }
  })

  test("a blocker still displaces the droppable detail, note or not", () => {
    assert.equal(
      Model.agentReadyLabel("42 models", NOTE, "no-funds"),
      NOTE + " · top up to use it",
    )
  })
})
