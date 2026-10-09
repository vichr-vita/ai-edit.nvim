#!/usr/bin/env bun

import { appendFile, readFile, stat } from "node:fs/promises"

const args = process.argv.slice(2)
const scenario = process.env.AI_EDIT_FAKE_SCENARIO ?? "success"
const request = await Bun.stdin.text()
const instruction = request.slice(request.indexOf("\nRequest:\n") + "\nRequest:\n".length)
const target = args.find((arg) => arg.startsWith("@"))?.slice(1)
const configDir = process.env.PI_CODING_AGENT_DIR
if (!target || !configDir || !args.includes("--print")) {
  throw new Error(`unexpected fake Pi invocation: ${args.join(" ")}`)
}
const targetInput = await readFile(target, "utf8")
const settings = JSON.parse(await readFile(`${configDir}/settings.json`, "utf8"))
const log = process.env.AI_EDIT_FAKE_LOG
if (log) {
  await appendFile(log, `${JSON.stringify({
    kind: "run", scenario, args, instruction, request, target, targetInput, configDir,
    cwd: process.cwd(), settings, nvim: process.env.NVIM,
    offline: process.env.PI_OFFLINE, telemetry: process.env.PI_TELEMETRY,
    targetMode: (await stat(target)).mode & 0o777,
    rootMode: (await stat(process.cwd())).mode & 0o777,
  })}\n`)
}

function emit(event: Record<string, unknown>) {
  process.stdout.write(`${JSON.stringify(event)}\n`)
}

function delta(text: string) {
  emit({ type: "message_update", assistantMessageEvent: { type: "text_delta", delta: text, contentIndex: 0 } })
}

function response(text: string, stopReason = "stop") {
  emit({ type: "message_end", message: { role: "assistant", stopReason, content: [{ type: "text", text }] } })
}

emit({ type: "session", id: "fake-session", cwd: process.cwd() })
emit({ type: "message_end", message: { role: "user", content: request } })
if (["run-hold", "timeout"].includes(scenario)) await Bun.sleep(60_000)
if (scenario === "run-gated") {
  const release = process.env.AI_EDIT_FAKE_RELEASE
  if (!release) throw new Error("missing release signal")
  while (!await Bun.file(release).exists()) await Bun.sleep(20)
}
if (["parallel", "stale"].includes(scenario)) await Bun.sleep(250)

if (scenario === "activity-events") {
  emit({ type: "message_update", assistantMessageEvent: { type: "thinking_delta", delta: "MODEL_REASONING_SECRET" } })
  emit({ type: "unknown", payload: "UNKNOWN_PAYLOAD_SECRET" })
  delta(`ASSISTANT_SAFE_TEXT\u0001\nprivate ${target}\nSTREAMED_CODE`)
  await Bun.sleep(1200)
}
if (scenario === "activity-single-limit") {
  delta(`${"é\u0002".repeat(1800)}SINGLE_ENTRY_TAIL`)
  await Bun.sleep(800)
}
if (scenario === "activity-chunked-limit") {
  for (let index = 0; index < 90; index++) delta(`${index.toString().padStart(3, "0")}:${"中".repeat(80)}\n`)
  delta("CHUNKED_ACTIVITY_TAIL")
  await Bun.sleep(800)
}

let replacement = process.env.AI_EDIT_FAKE_RESULT ?? "normal result\n"
if (instruction.includes("characterwise")) replacement = "BETA"
if (instruction.includes("linewise")) replacement = "TWO\nTHREE"
if (instruction.includes("delete")) replacement = ""
if (instruction.includes("tail")) replacement = targetInput.replace("HEAD_MARKER", "EDITED_HEAD")
if (scenario === "no-op") replacement = targetInput

switch (scenario) {
  case "nonzero":
    process.stderr.write("fake nonzero failure\n")
    process.exit(7)
  case "malformed":
    process.stdout.write("not JSON\n")
    response(replacement)
    break
  case "missing-response":
    delta("incomplete code")
    break
  case "duplicate-response":
    response(replacement)
    response(replacement)
    break
  case "truncated":
    response(replacement, "length")
    break
  case "tool-call":
    response(replacement, "toolUse")
    break
  case "provider-error":
    emit({ type: "message_end", message: { role: "assistant", stopReason: "error", errorMessage: "provider unavailable" } })
    break
  case "nul-output":
    response("invalid\u0000code")
    break
  case "oversized-output":
    response("x".repeat(2048))
    break
  default:
    // Fragment the JSON record, including a multibyte code point, across pipe writes.
    const record = Buffer.from(JSON.stringify({
      type: "message_end", message: { role: "assistant", stopReason: "stop", content: [{ type: "text", text: replacement }] },
    }))
    for (let offset = 0; offset < record.length; offset += 7) {
      process.stdout.write(record.subarray(offset, offset + 7))
    }
    // No trailing LF exercises the final record at EOF.
}
