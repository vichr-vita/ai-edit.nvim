import { describe, test } from "bun:test"

const cases = [
  ["rejects visual target mutation while prompt is open", "visual-mutation"],
  ["retries short positive staging writes", "short-write"],
  ["propagates staging fsync errors", "fsync-error"],
] as const

describe("Lua staging regressions", () => {
  for (const [name, scenario] of cases) {
    test(
      name,
      async () => {
        const child = Bun.spawn(
          ["nvim", "--headless", "-u", "tests/ai_edit/minimal_init.lua", "-l", "tests/ai_edit/followup.lua"],
          {
            cwd: process.cwd(),
            env: { ...process.env, AI_EDIT_FOLLOWUP_CASE: scenario },
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
      30_000,
    )
  }
})
