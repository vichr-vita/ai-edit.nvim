#!/usr/bin/env bun

import { appendFile, mkdir, readFile, rename, writeFile } from "node:fs/promises"
import { appendFileSync, readFileSync } from "node:fs"
import { resolve } from "node:path"

const args = process.argv.slice(2)
const logPath = process.env.AI_EDIT_FAKE_LOG
const scenario = process.env.AI_EDIT_FAKE_SCENARIO ?? "success"

async function log(value: Record<string, unknown>) {
  if (logPath) await appendFile(logPath, `${JSON.stringify(value)}\n`)
}

function safeTools() {
  return {
    read: true,
    glob: true,
    grep: true,
    stage_text: true,
    apply_patch: false,
    edit: false,
    write: false,
    bash: false,
    webfetch: false,
    task: false,
    question: false,
    skill: false,
  }
}

function safeAgentTools() {
  return {
    invalid: false,
    question: false,
    bash: false,
    read: true,
    glob: true,
    grep: true,
    stage_text: true,
    task: false,
    webfetch: false,
    todowrite: false,
    skill: false,
    apply_patch: false,
  }
}

function config() {
  const runtime = JSON.parse(process.env.OPENCODE_CONFIG_CONTENT ?? "{}")
  const value: Record<string, any> = {
    ...runtime,
    model: runtime.model ?? process.env.AI_EDIT_GLOBAL_MODEL ?? "openai/gpt-5.6-sol",
    provider:
      runtime.provider ??
      (process.env.AI_EDIT_GLOBAL_PROVIDER ? JSON.parse(process.env.AI_EDIT_GLOBAL_PROVIDER) : undefined),
    share: "disabled",
    snapshot: false,
    formatter: false,
    lsp: false,
    plugin: [],
    tools: safeTools(),
    tool_output: { max_bytes: 32768, max_lines: 10 },
  }
  const managedPath = process.env.AI_EDIT_MANAGED_FIXTURE
  if (managedPath) {
    const managed = JSON.parse(readFileSync(managedPath, "utf8"))
    Object.assign(value, managed)
    if (managed.tools) value.tools = { ...safeTools(), ...managed.tools }
  }
  if (scenario === "large-debug-config") {
    value.command = { oversized: { template: "x".repeat(80 * 1024) } }
  }
  if (scenario === "unsafe-plugin") {
    value.plugin = ["file:///tmp/external-user-plugin.ts"]
  }
  return value
}

function emit(value: Record<string, unknown>) {
  process.stdout.write(`${JSON.stringify(value)}\n`)
}

async function phase(name: string) {
  await log({ kind: "phase", phase: name, scenario })
  if (!process.env.AI_EDIT_FAKE_DELAY_PHASE || process.env.AI_EDIT_FAKE_DELAY_PHASE === name) {
    await Bun.sleep(Number(process.env.AI_EDIT_FAKE_PHASE_DELAY_MS ?? 0))
  }
}

function textEvent(id: string, text: string) {
  emit({
    type: "text",
    sessionID: "fake-session",
    part: { id, type: "text", text, time: { start: 1, end: 2 } },
  })
}

function reasoningEvent(text: string) {
  emit({
    type: "reasoning",
    sessionID: "fake-session",
    part: { id: "reasoning-1", type: "reasoning", text, time: { start: 1, end: 2 } },
  })
}

function toolEvent(
  id: string,
  tool: string,
  input: Record<string, unknown>,
  status: "completed" | "error" = "completed",
  output = "RAW_TOOL_OUTPUT_SECRET",
) {
  emit({
    type: "tool_use",
    sessionID: "fake-session",
    part: {
      id,
      type: "tool",
      tool,
      state: {
        status,
        input,
        ...(status === "error" ? { error: "SENSITIVE_TOOL_ERROR" } : { output }),
      },
    },
  })
}

function submitEvent(status = "completed") {
  emit({
    type: "tool_use",
    sessionID: "fake-session",
    part: {
      id: "stage-submit",
      type: "tool",
      tool: "stage_text",
      state: {
        status,
        input: { action: "submit" },
        ...(status === "error" ? { error: "fake nested tool error" } : { output: "submitted" }),
      },
    },
  })
}

if (args[0] === "--version") {
  await phase("version")
  await log({ kind: "version", args })
  process.stdout.write(scenario === "wrong-version" ? "1.18.22\n" : "1.18.21\n")
  process.exit(0)
}

if (args[0] === "debug" && args[1] === "config") {
  await phase(process.env.OPENCODE_CONFIG_DIR ? "runtime-config" : "global-config")
  await log({
    kind: "debug-config",
    args,
    configDir: process.env.OPENCODE_CONFIG_DIR,
    pure: process.env.OPENCODE_PURE,
    disableDefaultPlugins: process.env.OPENCODE_DISABLE_DEFAULT_PLUGINS,
    disableProjectConfig: process.env.OPENCODE_DISABLE_PROJECT_CONFIG,
    xdgConfigHome: process.env.XDG_CONFIG_HOME,
    opencodeTestHome: process.env.OPENCODE_TEST_HOME,
  })
  process.stdout.write(JSON.stringify(config()))
  process.exit(0)
}

if (args[0] === "debug" && args[1] === "agent") {
  const name = args[2]
  const runtime = config()
  const agent = runtime.agent?.[name] ?? {}
  const { disable: _defaultDisable, model, ...serializedAgent } = agent
  const configDir = process.env.OPENCODE_CONFIG_DIR
  if (configDir?.includes(".helper-build-")) {
    await phase("helper")
    await Bun.sleep(Number(process.env.AI_EDIT_BOOTSTRAP_DELAY_MS ?? 0))
    const dependency = `${configDir}/node_modules/@opencode-ai/plugin`
    await mkdir(`${dependency}/dist`, { recursive: true })
    await writeFile(`${dependency}/package.json`, JSON.stringify({ name: "@opencode-ai/plugin", version: "1.18.21" }))
    await writeFile(`${dependency}/dist/index.js`, "export const tool = value => value\n")
    await writeFile(`${configDir}/package-lock.json`, JSON.stringify({ lockfileVersion: 3 }))
  } else {
    await phase("agent")
  }
  await log({
    kind: "debug-agent",
    args,
    name,
    agent,
    configDir,
    xdgConfigHome: process.env.XDG_CONFIG_HOME,
    opencodeTestHome: process.env.OPENCODE_TEST_HOME,
  })
  process.stdout.write(
    JSON.stringify({
      name,
      ...serializedAgent,
      ...(model
        ? {
            model: {
              providerID: model.slice(0, model.indexOf("/")),
              modelID: model.slice(model.indexOf("/") + 1),
            },
          }
        : {}),
      mode: "primary",
      ...(scenario === "disabled-agent" ? { disable: true } : {}),
      tools: safeAgentTools(),
    }),
  )
  process.exit(0)
}

if (args[0] === "session" && args[1] === "delete") {
  const cleanupConfig = JSON.parse(process.env.OPENCODE_CONFIG_CONTENT ?? "{}")
  await log({
    kind: "session-delete",
    args,
    scenario,
    cwd: process.cwd(),
    configDir: process.env.OPENCODE_CONFIG_DIR,
    pure: process.env.OPENCODE_PURE,
    disableDefaultPlugins: process.env.OPENCODE_DISABLE_DEFAULT_PLUGINS,
    disableProjectConfig: process.env.OPENCODE_DISABLE_PROJECT_CONFIG,
    disableAutoshare: process.env.OPENCODE_DISABLE_AUTOSHARE,
    stageRoot: process.env.NVIM_AI_EDIT_STAGE_ROOT,
    cleanupConfig,
    toolsIsArray: Array.isArray(cleanupConfig.tools),
  })
  if (scenario === "cleanup-config-sensitive" && Array.isArray(cleanupConfig.tools)) {
    process.stderr.write(
      "Error: Configuration is invalid at OPENCODE_CONFIG_CONTENT\n↳ Expected object | undefined, got [] tools\n",
    )
    process.exit(1)
  }
  if (scenario === "cleanup-delay") await Bun.sleep(300)
  if (scenario === "cleanup-never") {
    process.on("SIGTERM", () => {
      if (logPath) appendFileSync(logPath, `${JSON.stringify({ kind: "session-delete-term", args, scenario })}\n`)
    })
    await Bun.sleep(60_000)
  }
  await log({ kind: "session-delete-finish", args, scenario })
  process.exit(scenario === "cleanup-error" ? 1 : 0)
}

if (args[0] !== "run") {
  await log({ kind: "unexpected", args })
  process.stderr.write(`unexpected fake OpenCode arguments: ${args.join(" ")}\n`)
  process.exit(64)
}

const instruction = await Bun.stdin.text()
await phase("model-run")
const runtimeConfig = JSON.parse(process.env.OPENCODE_CONFIG_CONTENT ?? "{}")
const target =
  process.env.NVIM_AI_EDIT_STAGE_TARGET ??
  process.env.AI_EDIT_STAGE_TARGET ??
  process.env.OPENCODE_AI_EDIT_STAGE_TARGET
const context = process.env.NVIM_AI_EDIT_CONTEXT ?? process.env.AI_EDIT_STAGE_CONTEXT
const targetInput = target ? await readFile(target, "utf8") : null
const contextInput = context ? await readFile(context, "utf8") : null
let externalSymlinkInput: string | null = null
for (const candidate of ["external-link.txt", "src/external-link.txt"]) {
  try {
    externalSymlinkInput = await readFile(candidate, "utf8")
    break
  } catch {
    // Fixture absent in ordinary runs.
  }
}
await log({
  kind: "run",
  args,
  instruction,
  target,
  targetInput,
  contextInput,
  cwd: process.cwd(),
  externalSymlinkInput,
  root: process.env.NVIM_AI_EDIT_STAGE_ROOT ?? process.env.AI_EDIT_STAGE_ROOT,
  context,
  configDir: process.env.OPENCODE_CONFIG_DIR,
  xdgConfigHome: process.env.XDG_CONFIG_HOME,
  opencodeTestHome: process.env.OPENCODE_TEST_HOME,
  pure: process.env.OPENCODE_PURE,
  disableDefaultPlugins: process.env.OPENCODE_DISABLE_DEFAULT_PLUGINS,
  disableProjectConfig: process.env.OPENCODE_DISABLE_PROJECT_CONFIG,
  config: runtimeConfig,
})

emit({ type: "step_start", sessionID: "fake-session", part: { type: "step-start" } })

if (["cancel", "timeout", "stale", "missing-buffer", "parallel"].includes(scenario)) {
  await Bun.sleep(scenario === "timeout" ? 1000 : 250)
}
if (scenario === "run-hold") await Bun.sleep(60_000)

if (scenario === "activity-events") {
  reasoningEvent("MODEL_REASONING_SECRET")
  emit({ type: "unknown", sessionID: "fake-session", payload: "UNKNOWN_PAYLOAD_SECRET" })
  textEvent(
    "text-1",
    `ASSISTANT_SAFE_TEXT\u0001\nprivate ${target}\nsession fake-session`,
  )
  toolEvent("glob-1", "glob", { pattern: "SAFE_GLOB_PATTERN", path: target }, "completed")
  toolEvent("grep-1", "grep", { pattern: "SAFE_GREP_PATTERN", replacement: "REPLACEMENT_SECRET" }, "completed")
  toolEvent(
    "stage-read",
    "stage_text",
    { action: "read", source: "target", path: target, replacement: "REPLACEMENT_SECRET" },
    "completed",
  )
  toolEvent("unknown-tool", "bash", { command: "UNKNOWN_TOOL_INPUT_SECRET" }, "completed")
  textEvent("duplicate-text", "DUPLICATE_OLD_TEXT")
  textEvent("duplicate-text", "DUPLICATE_NEW_TEXT")
  await Bun.sleep(800)
}

if (scenario === "activity-failed-tool") {
  toolEvent("failed-grep", "grep", { pattern: "SAFE_FAILED_PATTERN" }, "error")
  await Bun.sleep(800)
}

if (scenario === "activity-single-limit" || scenario === "activity-long") {
  textEvent("oversized-text", `${"é\u0002".repeat(1800)}SINGLE_ENTRY_TAIL`)
  await Bun.sleep(800)
}

if (scenario === "activity-aggregate-limit" || scenario === "activity-long") {
  for (let index = 0; index < 90; index += 1) {
    textEvent(`aggregate-${index}`, `${index.toString().padStart(3, "0")}:${"中".repeat(80)}`)
  }
  textEvent("aggregate-tail", "AGGREGATE_ACTIVITY_TAIL")
  await Bun.sleep(800)
}

if (scenario === "activity-keyed-growth") {
  for (let index = 0; index < 40; index += 1) textEvent(`growth-${index}`, `small-${index}`)
  for (let index = 0; index < 40; index += 1) {
    textEvent(`growth-${index}`, `${index.toString().padStart(3, "0")}:${"é".repeat(1500)}`)
  }
  textEvent("growth-tail", "KEYED_GROWTH_TAIL")
  await Bun.sleep(800)
}

if (scenario === "top-error") {
  emit({ type: "error", sessionID: "fake-session", error: "fake top-level error" })
  submitEvent()
  process.exit(0)
}

if (scenario === "nested-error") {
  submitEvent("error")
  process.exit(0)
}

if (scenario === "nonzero") {
  process.stderr.write("fake nonzero failure\n")
  process.exit(7)
}

if (!target && !["missing-submit", "cancel", "timeout"].includes(scenario)) {
  process.stderr.write("missing host-bound staging target environment\n")
  process.exit(65)
}

if (target && scenario === "apply-patch-move") {
  const fixturePath = process.env.AI_EDIT_APPLY_PATCH_FIXTURE
  if (!fixturePath) throw new Error("missing apply_patch move fixture")
  const fixture = JSON.parse(await readFile(fixturePath, "utf8"))
  const source = fixture.patch?.match(/^\*\*\* Update File: (.+)$/m)?.[1]
  const moveTo = fixture.patch?.match(/^\*\*\* Move to: (.+)$/m)?.[1]
  if (fixture.tool !== "apply_patch" || !source || !moveTo) throw new Error("invalid apply_patch move fixture")

  const destination = resolve(process.cwd(), moveTo)
  const projectBefore = await readFile(destination, "utf8")
  const agentName = args[args.indexOf("--agent") + 1]
  const agentPermission = runtimeConfig.agent?.[agentName]?.permission?.apply_patch
  const canApplyPatch =
    runtimeConfig.tools?.apply_patch === true &&
    runtimeConfig.permission?.apply_patch !== "deny" &&
    agentPermission !== "deny"
  if (canApplyPatch) await rename(target, destination)
  const projectAfterAttempt = await readFile(destination, "utf8")
  await writeFile(target, "hostile staged result\n")
  const stagedAfterAllowedEdit = await readFile(target, "utf8")
  await log({
    kind: "apply-patch-move-attempt",
    fixtureTool: fixture.tool,
    fixturePatch: fixture.patch,
    source,
    moveTo,
    destination,
    root: process.env.NVIM_AI_EDIT_STAGE_ROOT,
    target,
    canApplyPatch,
    projectBefore,
    projectAfterAttempt,
    stagedAfterAllowedEdit,
  })
  await Bun.sleep(250)
}

if (target && scenario !== "apply-patch-move" && !["no-op", "missing-submit", "cancel", "timeout"].includes(scenario)) {
  const current = await readFile(target, "utf8")
  let replacement = "normal result\n"
  if (instruction.includes("characterwise")) replacement = "BETA"
  if (instruction.includes("linewise")) replacement = "TWO\nTHREE"
  if (instruction.includes("delete")) replacement = ""
  if (instruction.includes("tail")) replacement = current.replace("HEAD_MARKER", "EDITED_HEAD")
  await writeFile(target, replacement)
}

if (scenario !== "missing-submit") submitEvent()
if (scenario === "duplicate-submit") submitEvent()
emit({ type: "step_finish", sessionID: "fake-session", part: { type: "step-finish", reason: "stop" } })
