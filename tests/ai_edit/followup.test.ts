import { describe, expect, test } from "bun:test"
import { chmod, lstat, mkdtemp, readdir, rm, stat } from "node:fs/promises"
import { tmpdir } from "node:os"
import { join } from "node:path"

const cases = [
  ["rejects visual target mutation while prompt is open", "visual-mutation"],
  ["retries short positive staging writes", "short-write"],
  ["propagates staging fsync errors", "fsync-error"],
] as const

async function makeWritable(path: string) {
  const info = await lstat(path)
  if (info.isSymbolicLink()) return
  if (info.isDirectory()) {
    await chmod(path, 0o700)
    for (const entry of await readdir(path)) await makeWritable(join(path, entry))
  } else {
    await chmod(path, 0o600)
  }
}

describe("Lua staging regressions", () => {
  for (const [name, scenario] of cases) {
    test(name, async () => {
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
    })
  }

  test("publishes one immutable helper cache across concurrent first bootstrap", async () => {
    const root = await mkdtemp(join(tmpdir(), "ai-edit-bootstrap-"))
    const cacheHome = join(root, "cache")
    try {
      const children = ["one", "two"].map((name) =>
        Bun.spawn(["nvim", "--headless", "-u", "tests/ai_edit/minimal_init.lua", "-l", "tests/ai_edit/followup.lua"], {
          cwd: process.cwd(),
          env: {
            ...process.env,
            AI_EDIT_FOLLOWUP_CASE: "bootstrap",
            AI_EDIT_FAKE_LOG: join(root, `${name}.log`),
            AI_EDIT_BOOTSTRAP_DELAY_MS: "200",
            XDG_CACHE_HOME: cacheHome,
          },
          stdin: "ignore",
          stdout: "pipe",
          stderr: "pipe",
        }),
      )
      const results = await Promise.all(
        children.map(async (child) => {
          const [code, stdout, stderr] = await Promise.all([
            child.exited,
            new Response(child.stdout).text(),
            new Response(child.stderr).text(),
          ])
          return { code, stdout, stderr }
        }),
      )
      for (const result of results) expect(result.code, `${result.stdout}\n${result.stderr}`).toBe(0)

      const cache = join(cacheHome, "nvim", "nvim-ai-edit")
      const entries = await readdir(cache)
      expect(entries.filter((entry) => entry.startsWith("helper-5-"))).toHaveLength(1)
      expect(entries.filter((entry) => entry.startsWith(".helper-build-"))).toHaveLength(0)
      const published = join(cache, entries.find((entry) => entry.startsWith("helper-5-"))!)
      expect((await stat(published)).mode & 0o222).toBe(0)
      expect((await stat(join(published, "opencode/tool/stage_text.ts"))).mode & 0o222).toBe(0)
      expect((await stat(join(published, "opencode/package.json"))).mode & 0o222).toBe(0)
      expect((await stat(join(published, "opencode/node_modules/@opencode-ai/plugin/package.json"))).mode & 0o222).toBe(0)
    } finally {
      await makeWritable(root).catch(() => {})
      await rm(root, { recursive: true, force: true })
    }
  }, 15_000)
})
