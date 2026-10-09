import { mkdtemp, rm } from "node:fs/promises"
import { tmpdir } from "node:os"
import { join, resolve } from "node:path"

const root = resolve(import.meta.dir, "../..")
const mode = process.argv[2]
if (!mode || !["fake", "pi", "all"].includes(mode)) {
  console.error("usage: bun tests/ai_edit/run.ts <fake|pi|all>")
  process.exit(2)
}

const fixtureRoot = await mkdtemp(join(tmpdir(), "ai-edit-pi-tests-"))
try {
  const fakeCommand = join(fixtureRoot, "pi")
  if (mode !== "pi") {
    const build = Bun.spawn(["bun", "build", "--compile", "tests/ai_edit/fake_pi.ts", "--outfile", fakeCommand], {
      cwd: root,
      stdin: "ignore",
      stdout: "inherit",
      stderr: "inherit",
    })
    if ((await build.exited) !== 0) throw new Error("failed to compile fake Pi fixture")
  }

  const fakeChecks = [
    ["stylua", "--check", "lua", "tests"],
    ["bun", "test", "tests/ai_edit/followup.test.ts", "tests/ai_edit/running_view.test.ts", "tests/ai_edit/tui.test.ts"],
    ...["headless", "prompt", "health", "docs"].map((name) =>
      ["nvim", "--headless", "-u", "tests/ai_edit/minimal_init.lua", "-l", `tests/ai_edit/${name}.lua`]),
    ["nvim", "--headless", "-u", "NONE", "-l", "tests/ai_edit/startup_init.lua"],
    ["git", "diff", "--check"],
  ]
  const piChecks = [["bun", "test", "tests/ai_edit/real_pi.test.ts"]]
  const checks = mode === "fake" ? fakeChecks : mode === "pi" ? piChecks : [...fakeChecks, ...piChecks]
  for (const command of checks) {
    console.log(`Running ${command.join(" ")}`)
    const child = Bun.spawn(command, {
      cwd: root,
      env: {
        ...process.env,
        AI_EDIT_FAKE_COMMAND: fakeCommand,
        XDG_CACHE_HOME: join(fixtureRoot, "cache"),
        XDG_CONFIG_HOME: join(fixtureRoot, "config"),
      },
      stdin: "ignore",
      stdout: "inherit",
      stderr: "inherit",
    })
    const code = await child.exited
    if (code !== 0) throw new Error(`${command.join(" ")} failed (${code})`)
  }
  console.log(`${mode} ai_edit checks passed`)
} finally {
  await rm(fixtureRoot, { recursive: true, force: true })
}
