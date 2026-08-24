import { mkdtemp, rm } from "node:fs/promises"
import { tmpdir } from "node:os"
import { join, resolve } from "node:path"

type Check = {
  name: string
  command: string[]
  oauth?: boolean
}

const root = resolve(import.meta.dir, "../..")
const mode = process.argv[2]

if (!mode || !["fake", "opencode", "oauth", "all"].includes(mode)) {
  console.error("usage: bun tests/ai_edit/run.ts <fake|opencode|oauth|all>")
  process.exit(2)
}

if (mode === "oauth" && process.env.AI_EDIT_RUN_OAUTH_SMOKE !== "1") {
  console.error("oauth mode requires AI_EDIT_RUN_OAUTH_SMOKE=1")
  process.exit(2)
}

let fixtureRoot: string | undefined
let fakeCommand = process.env.AI_EDIT_FAKE_COMMAND
if ((mode === "fake" || mode === "all") && !fakeCommand) {
  fixtureRoot = await mkdtemp(join(tmpdir(), "ai-edit-fake-"))
  fakeCommand = join(fixtureRoot, "opencode")
  const build = Bun.spawn(["bun", "build", "--compile", "tests/ai_edit/fake_opencode.ts", "--outfile", fakeCommand], {
    cwd: root,
    stdin: "ignore",
    stdout: "inherit",
    stderr: "inherit",
  })
  if ((await build.exited) !== 0) {
    await rm(fixtureRoot, { recursive: true, force: true })
    console.error("failed to compile fake OpenCode fixture")
    process.exit(1)
  }
}

function testEnvironment(oauth: boolean) {
  const baselineOpencode = process.env.AI_EDIT_REAL_OPENCODE
  const env = { ...process.env }
  for (const key of Object.keys(env)) {
    if (key.startsWith("AI_EDIT_") || key.startsWith("NVIM_AI_EDIT_")) delete env[key]
  }
  env.AI_EDIT_RUN_OAUTH_SMOKE = oauth ? "1" : "0"
  if (baselineOpencode) env.AI_EDIT_REAL_OPENCODE = baselineOpencode
  if (fakeCommand) env.AI_EDIT_FAKE_COMMAND = fakeCommand
  return env
}

const fakeChecks: Check[] = [
  { name: "tool versions", command: ["bun", "--version"] },
  { name: "StyLua", command: ["stylua", "--check", "lua", "tests"] },
  { name: "trusted stage_text tool", command: ["bun", "test", "tests/ai_edit/stage_text.test.ts"] },
  { name: "follow-up Lua regressions", command: ["bun", "test", "tests/ai_edit/followup.test.ts"] },
  { name: "running view", command: ["bun", "test", "tests/ai_edit/running_view.test.ts"] },
  { name: "TUI caret", command: ["bun", "test", "tests/ai_edit/tui.test.ts"] },
  {
    name: "headless Neovim",
    command: ["nvim", "--headless", "-u", "tests/ai_edit/minimal_init.lua", "-l", "tests/ai_edit/headless.lua"],
  },
  {
    name: "prompt and history",
    command: ["nvim", "--headless", "-u", "tests/ai_edit/minimal_init.lua", "-l", "tests/ai_edit/prompt.lua"],
  },
  {
    name: "health diagnostics",
    command: ["nvim", "--headless", "-u", "tests/ai_edit/minimal_init.lua", "-l", "tests/ai_edit/health.lua"],
  },
  {
    name: "documentation references",
    command: ["nvim", "--headless", "-u", "tests/ai_edit/minimal_init.lua", "-l", "tests/ai_edit/docs.lua"],
  },
  { name: "hostile fixtures", command: ["bun", "test", "tests/ai_edit/hostile.test.ts"] },
  {
    name: "clean startup smoke",
    command: ["nvim", "--headless", "-u", "NONE", "-l", "tests/ai_edit/startup_init.lua"],
  },
  { name: "git diff check", command: ["git", "diff", "--check"] },
]

const opencodeChecks: Check[] = [
  { name: "installed baseline OpenCode hostile boundary", command: ["bun", "test", "tests/ai_edit/real_opencode.test.ts"] },
]

const oauthChecks: Check[] = [
  {
    name: "credentialed OpenCode OAuth smoke",
    command: [
      "bun",
      "test",
      "--test-name-pattern",
      "uses bundled OpenAI OAuth while keeping hostile project extensions disabled",
      "tests/ai_edit/real_opencode.test.ts",
    ],
    oauth: true,
  },
]

const checks = mode === "fake" ? fakeChecks : mode === "opencode" ? opencodeChecks : mode === "oauth" ? oauthChecks : [...fakeChecks, ...opencodeChecks]

let failed = 0
try {
  for (const check of checks) {
    console.log(`\n== ${check.name} ==`)
    const child = Bun.spawn(check.command, {
      cwd: root,
      env: testEnvironment(check.oauth === true),
      stdin: "ignore",
      stdout: "inherit",
      stderr: "inherit",
    })
    const code = await child.exited
    if (code !== 0) {
      failed += 1
      console.error(`${check.name}: failed (${code})`)
      break
    }
  }
} finally {
  if (fixtureRoot) await rm(fixtureRoot, { recursive: true, force: true })
}

if (failed > 0) {
  console.error(`\n${failed} verification check(s) failed`)
  process.exit(1)
}

console.log(`\n${mode} ai_edit verification checks passed`)
