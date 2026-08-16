// Loads Model.js — the plugin's pure layer — into a plain JS context so the
// tests can call its functions and execute the exact shell scripts it builds.
//
// Model.js is a QML `.pragma library`: that first line is the only thing in
// it that is not plain JavaScript, so stripping it is the whole adapter. No
// stubbing, no re-implementation — a test that passes here is testing the
// same bytes the shell runs.

import { readFileSync } from "node:fs"
import vm from "node:vm"

const source = readFileSync(new URL("../Model.js", import.meta.url), "utf8")

if (!/^\.pragma library\s*$/m.test(source.split("\n")[0])) {
  throw new Error("Model.js no longer starts with `.pragma library` — check this adapter still holds")
}

const context = vm.createContext({})
vm.runInContext(source.replace(/^\.pragma library/, ""), context, { filename: "Model.js" })

export const Model = context
