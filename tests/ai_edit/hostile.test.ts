import { afterAll, beforeAll, describe, expect, test } from "bun:test"
import { cp, mkdir, mkdtemp, readFile, rm, symlink, writeFile } from "node:fs/promises"
import { tmpdir } from "node:os"
import { join, resolve } from "node:path"

let sandbox = ""
let project = ""
let log = ""
let externalTarget = ""

beforeAll(async () => {
  sandbox = await mkdtemp(join(tmpdir(), "ai-edit-hostile-"))
  project = join(sandbox, "project")
  await cp(resolve("tests/ai_edit/fixtures/hostile-project"), project, { recursive: true })
  const gitInit = Bun.spawn(["git", "init", "-q", project], { stdout: "ignore", stderr: "pipe" })
  expect(await gitInit.exited, await new Response(gitInit.stderr).text()).toBe(0)
  await mkdir(join(project, "src"), { recursive: true })
  const outside = join(sandbox, "outside")
  await mkdir(outside, { recursive: true })
  externalTarget = join(outside, "secret.txt")
  await writeFile(externalTarget, "EXTERNAL_SYMLINK_SENTINEL\n")
  await symlink("../../outside/secret.txt", join(project, "src/external-link.txt"))
  log = join(sandbox, "fake.log")
})

afterAll(async () => {
  await rm(sandbox, { recursive: true, force: true })
})

describe("hostile project fixture", () => {
  test("keeps executable extensions, managed overrides, host commands, moves, tails, and symlink scoped", async () => {
    const child = Bun.spawn(
      ["nvim", "--headless", "-u", "tests/ai_edit/minimal_init.lua", "-l", "tests/ai_edit/hostile.lua"],
      {
        cwd: process.cwd(),
        env: {
          ...process.env,
          AI_EDIT_HOSTILE_PROJECT: project,
          AI_EDIT_EXTERNAL_TARGET: externalTarget,
          AI_EDIT_APPLY_PATCH_FIXTURE: join(project, "apply-patch-move.json"),
          AI_EDIT_LARGE_FIXTURE: resolve("tests/ai_edit/fixtures/large-tail.template"),
          AI_EDIT_FAKE_LOG: log,
        },
        stdout: "pipe",
        stderr: "pipe",
      },
    )
    const [exitCode, stdout, stderr] = await Promise.all([
      child.exited,
      new Response(child.stdout).text(),
      new Response(child.stderr).text(),
    ])
    expect(exitCode, `${stdout}\n${stderr}`).toBe(0)
    expect(await readFile(externalTarget, "utf8")).toBe("EXTERNAL_SYMLINK_SENTINEL\n")
  }, 60_000)
})
