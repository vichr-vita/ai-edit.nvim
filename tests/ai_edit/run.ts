type Check = {
  name: string
  command: string[]
}

const checks: Check[] = [
  {
    name: "targeted Stylua",
    command: [
      "stylua",
      "--check",
      "lua/vichr/ai_edit.lua",
      "tests/ai_edit/minimal_init.lua",
      "tests/ai_edit/prompt.lua",
      "tests/ai_edit/followup.lua",
      "tests/ai_edit/headless.lua",
      "tests/ai_edit/hostile.lua",
      "tests/ai_edit/real_mcp_guard.lua",
      "tests/ai_edit/real_oauth_smoke.lua",
      "tests/ai_edit/running_view.lua",
      "tests/ai_edit/startup_init.lua",
      "tests/ai_edit/tui_init.lua",
    ],
  },
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
  { name: "hostile fixtures", command: ["bun", "test", "tests/ai_edit/hostile.test.ts"] },
  { name: "installed OpenCode hostile boundary", command: ["bun", "test", "tests/ai_edit/real_opencode.test.ts"] },
  {
    name: "git diff check",
    command: [
      "git",
      "diff",
      "--check",
      "--",
      "lua/vichr/ai_edit.lua",
      "lua/vichr/ai_edit/stage_text.ts",
      "tests/ai_edit",
      "openspec/changes/add-opencode-ai-edit",
      "openspec/changes/add-ai-edit-running-view",
      "openspec/changes/improve-ai-edit-prompt",
    ],
  },
  {
    name: "clean startup smoke",
    command: ["nvim", "--headless", "-u", "NONE", "-l", "tests/ai_edit/startup_init.lua"],
  },
]

let failed = 0
for (const check of checks) {
  console.log(`\n== ${check.name} ==`)
  const child = Bun.spawn(check.command, {
    cwd: process.cwd(),
    env: process.env,
    stdin: "ignore",
    stdout: "inherit",
    stderr: "inherit",
  })
  const code = await child.exited
  if (code !== 0) {
    failed += 1
    console.error(`${check.name}: failed (${code})`)
  }
}

if (failed > 0) {
  console.error(`\n${failed} verification check(s) failed`)
  process.exit(1)
}

console.log("\nall ai_edit verification checks passed")
