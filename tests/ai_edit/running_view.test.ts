import { describe, test } from "bun:test"

const cases = [
  ["locks target while unrelated buffers remain editable", "lock-basic"],
  ["keeps concurrent target locks and views independent", "lock-concurrency"],
  ["preserves active jobs across repeated setup", "setup-active"],
  ["rejects forced, renamed, unloaded, and deleted targets", "stale-targets"],
  ["suppresses hostile modifiable OptionSet handlers", "lock-optionset"],
  ["owns and restores guarded guicursor state", "cursor"],
  ["renders passive allowlisted activity", "activity-events"],
  ["bounds UTF-8 activity entries and aggregates", "activity-bounds"],
  ["tears down every terminal path", "terminal-matrix"],
] as const

describe("AI edit running view", () => {
  for (const [name, scenario] of cases) {
    test(
      name,
      async () => {
        const child = Bun.spawn(
          ["nvim", "--headless", "-u", "tests/ai_edit/minimal_init.lua", "-l", "tests/ai_edit/running_view.lua"],
          {
            cwd: process.cwd(),
            env: { ...process.env, AI_EDIT_RUNNING_VIEW_CASE: scenario },
            stdin: "ignore",
            stdout: "pipe",
            stderr: "pipe",
          },
        )
        const [code, stdout, stderr] = await Promise.all([
          child.exited,
          new Response(child.stdout).text(),
          new Response(child.stderr).text(),
        ])
        if (code !== 0) throw new Error(`${scenario} failed (${code})\n${stdout}${stderr}`)
      },
      20_000,
    )
  }
})
