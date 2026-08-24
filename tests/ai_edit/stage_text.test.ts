import { afterEach, beforeEach, describe, expect, test } from "bun:test"
import { mkdtemp, mkdir, readFile, realpath, rename, rm, symlink, writeFile } from "node:fs/promises"
import { tmpdir } from "node:os"
import { dirname, join, resolve } from "node:path"
import { pathToFileURL } from "node:url"

type StageEnvironment = {
  root: string
  target: string
  context?: string
  maxBytes: number
  beforeCommit?: () => void | Promise<void>
}

type StageTool = {
  execute(input: Record<string, unknown>): Promise<string>
}

type Page = {
  source: "target" | "context"
  revision: string
  text: string
  startByte: number
  endByte: number
  nextCursor: string | null
  eof: boolean
}

const sourcePath = resolve(
  process.env.AI_EDIT_STAGE_TEXT_SOURCE ?? "lua/vichr/ai_edit/stage_text.ts",
)

let root = ""
let target = ""
let context = ""

async function factory(environment: StageEnvironment): Promise<StageTool> {
  const implementation = await import(`${pathToFileURL(sourcePath).href}?test=${crypto.randomUUID()}`)
  const create = implementation.createStageTextForTest ?? implementation.createStageText
  expect(typeof create).toBe("function")
  return await create(environment)
}

function decode(raw: string): Record<string, unknown> {
  expect(typeof raw).toBe("string")
  expect(raw.split("\n")).toHaveLength(1)
  return JSON.parse(raw)
}

function page(raw: string): Page {
  const value = decode(raw)
  return {
    source: value.source as Page["source"],
    revision: value.revision as string,
    text: (value.text ?? value.content) as string,
    startByte: (value.startByte ?? value.start_byte ?? value.byteStart) as number,
    endByte: (value.endByte ?? value.end_byte ?? value.byteEnd) as number,
    nextCursor: (value.nextCursor ?? value.next_cursor ?? null) as string | null,
    eof: value.eof as boolean,
  }
}

async function readAll(tool: StageTool, source: Page["source"]): Promise<{ text: string; revision: string }> {
  let cursor: string | null = null
  let text = ""
  let revision = ""
  let expectedStart = 0
  for (let index = 0; index < 10000; index += 1) {
    const current = page(
      await tool.execute({ action: "read", source, ...(cursor ? { cursor } : {}) }),
    )
    expect(current.source).toBe(source)
    expect(current.startByte).toBe(expectedStart)
    expect(current.endByte).toBeGreaterThanOrEqual(current.startByte)
    expect(current.revision).toBe(revision || current.revision)
    text += current.text
    revision = current.revision
    expectedStart = current.endByte
    if (current.eof) {
      expect(current.nextCursor).toBeNull()
      return { text, revision }
    }
    expect(current.nextCursor).toBeString()
    cursor = current.nextCursor
  }
  throw new Error("pagination did not reach EOF")
}

async function expectReject(action: () => Promise<unknown>, pattern: RegExp) {
  await expect(action()).rejects.toThrow(pattern)
}

beforeEach(async () => {
  root = await mkdtemp(join(tmpdir(), "ai-edit-stage-test-"))
  target = join(root, "target.ts")
  context = join(root, "context.ts")
  await writeFile(target, "alpha beta gamma\n", "utf8")
  await writeFile(context, "before\nalpha beta gamma\nafter\n", "utf8")
})

afterEach(async () => {
  await rm(root, { recursive: true, force: true })
})

describe("bounded authoritative reads", () => {
  test("pages target and context past 50 KiB and 2,000 lines without losing UTF-8", async () => {
    const targetText = `${"🙂target\n".repeat(7000)}TARGET_TAIL`
    const contextText = `${"λ-context\n".repeat(6000)}CONTEXT_TAIL`
    expect(Buffer.byteLength(targetText)).toBeGreaterThan(50 * 1024)
    expect(targetText.split("\n").length).toBeGreaterThan(2000)
    await writeFile(target, targetText)
    await writeFile(context, contextText)
    const tool = await factory({ root, target, context, maxBytes: 1024 * 1024 })

    expect((await readAll(tool, "target")).text).toBe(targetText)
    expect((await readAll(tool, "context")).text).toBe(contextText)
  })

  test("keeps every complete serialized envelope below byte and line budgets", async () => {
    await writeFile(target, `${"quoted \\\" text \\ newline\n".repeat(5000)}TAIL`)
    const tool = await factory({ root, target, maxBytes: 1024 * 1024 })
    let cursor: string | null = null
    do {
      const raw = await tool.execute({ action: "read", source: "target", ...(cursor ? { cursor } : {}) })
      expect(Buffer.byteLength(raw)).toBeLessThan(16 * 1024)
      expect(raw.split("\n").length).toBeLessThanOrEqual(10)
      const current = page(raw)
      cursor = current.nextCursor
      if (current.eof) break
    } while (true)
  })

  test("binds cursor chains to source and revision", async () => {
    await writeFile(target, "target-line\n".repeat(5000))
    await writeFile(context, "context-line\n".repeat(5000))
    const tool = await factory({ root, target, context, maxBytes: 1024 * 1024 })
    const first = page(await tool.execute({ action: "read", source: "target" }))
    expect(first.eof).toBeFalse()

    await expectReject(
      () => tool.execute({ action: "read", source: "context", cursor: first.nextCursor }),
      /cursor|source/i,
    )
    await writeFile(target, `changed\n${await readFile(target, "utf8")}`)
    await expectReject(
      () => tool.execute({ action: "read", source: "target", cursor: first.nextCursor }),
      /stale|revision|cursor/i,
    )
  })
})

describe("revision-checked submissions", () => {
  test("accepts an explicit target source on submit", async () => {
    const tool = await factory({ root, target, maxBytes: 1024 * 1024 })
    const current = page(await tool.execute({ action: "read", source: "target" }))

    decode(
      await tool.execute({
        action: "submit",
        source: "target",
        revision: current.revision,
        operations: [{ oldText: "beta", newText: "updated" }],
      }),
    )
    expect(await readFile(target, "utf8")).toBe("alpha updated gamma\n")
  })

  test("permits exactly one concurrent submit for the same revision", async () => {
    let beforeCommitCalls = 0
    let firstReachedCommit!: () => void
    let releaseFirst!: () => void
    const firstAtCommit = new Promise<void>((resolve) => {
      firstReachedCommit = resolve
    })
    const firstRelease = new Promise<void>((resolve) => {
      releaseFirst = resolve
    })
    const tool = await factory({
      root,
      target,
      maxBytes: 1024 * 1024,
      beforeCommit: async () => {
        beforeCommitCalls += 1
        if (beforeCommitCalls === 1) {
          firstReachedCommit()
          await Promise.race([firstRelease, Bun.sleep(250)])
        } else {
          releaseFirst()
        }
      },
    })
    const revision = page(await tool.execute({ action: "read", source: "target" })).revision

    const first = tool.execute({ action: "submit", revision, replacement: "first\n" })
    await firstAtCommit
    const second = tool.execute({ action: "submit", revision, replacement: "second\n" })
    const results = await Promise.allSettled([first, second])

    expect(results.filter((result) => result.status === "fulfilled")).toHaveLength(1)
    const rejected = results.filter((result) => result.status === "rejected")
    expect(rejected).toHaveLength(1)
    expect(String((rejected[0] as PromiseRejectedResult).reason)).toMatch(/stale|revision/i)
    expect(["first\n", "second\n"]).toContain(await readFile(target, "utf8"))
  })

  test("preserves completed coverage across a same-revision first-page reread", async () => {
    await writeFile(target, "large-target\n".repeat(5000))
    const tool = await factory({ root, target, maxBytes: 1024 * 1024 })
    const complete = await readAll(tool, "target")

    const reread = page(await tool.execute({ action: "read", source: "target" }))
    expect(reread.revision).toBe(complete.revision)
    expect(reread.eof).toBeFalse()

    decode(await tool.execute({ action: "submit", revision: complete.revision, replacement: "complete\n" }))
    expect(await readFile(target, "utf8")).toBe("complete\n")
  })

  test("requires same-revision sequential EOF coverage for a multi-page full replacement", async () => {
    await writeFile(target, "large-target\n".repeat(5000))
    const tool = await factory({ root, target, maxBytes: 1024 * 1024 })
    const first = page(await tool.execute({ action: "read", source: "target" }))
    expect(first.eof).toBeFalse()
    await expectReject(
      () => tool.execute({ action: "submit", revision: first.revision, replacement: "complete\n" }),
      /coverage|EOF|read/i,
    )

    const complete = await readAll(tool, "target")
    decode(await tool.execute({ action: "submit", revision: complete.revision, replacement: "complete\n" }))
    expect(await readFile(target, "utf8")).toBe("complete\n")
  })

  test("applies exact operations without reading full target", async () => {
    const original = `${"prefix\n".repeat(5000)}UNREAD_UNIQUE_TAIL\n`
    await writeFile(target, original)
    const tool = await factory({ root, target, maxBytes: 1024 * 1024 })
    const first = page(await tool.execute({ action: "read", source: "target" }))
    expect(first.eof).toBeFalse()
    decode(
      await tool.execute({
        action: "submit",
        revision: first.revision,
        operations: [{ oldText: "UNREAD_UNIQUE_TAIL", newText: "EDITED_TAIL" }],
      }),
    )
    expect(await readFile(target, "utf8")).toBe(original.replace("UNREAD_UNIQUE_TAIL", "EDITED_TAIL"))
  })

  test("rejects context submission and any model-selected path", async () => {
    const tool = await factory({ root, target, context, maxBytes: 1024 * 1024 })
    const targetPage = page(await tool.execute({ action: "read", source: "target" }))
    const contextPage = page(await tool.execute({ action: "read", source: "context" }))
    await expectReject(
      () =>
        tool.execute({
          action: "submit",
          source: "context",
          revision: contextPage.revision,
          replacement: "mutated",
        }),
      /context|source|submit/i,
    )
    await expectReject(
      () => tool.execute({ action: "read", source: "target", path: join(root, "other.ts") }),
      /path|argument|unknown/i,
    )
    await expectReject(
      () =>
        tool.execute({
          action: "submit",
          revision: targetPage.revision,
          replacement: "mutated",
          path: join(root, "other.ts"),
        }),
      /path|argument|unknown/i,
    )
    expect(await readFile(context, "utf8")).toContain("before")
  })

  test("rejects missing, ambiguous, unexpected-count, overlapping, and stale exact edits atomically", async () => {
    await writeFile(target, "one two one three\n")
    const cases: Array<{ operations: unknown[]; error: RegExp }> = [
      { operations: [{ oldText: "missing", newText: "x" }], error: /missing|match|count/i },
      { operations: [{ oldText: "one", newText: "x" }], error: /ambiguous|count|match/i },
      {
        operations: [{ oldText: "one", newText: "x", expectedCount: 3 }],
        error: /count|expected/i,
      },
      {
        operations: [
          { oldText: "one two", newText: "x" },
          { oldText: "two one", newText: "y" },
        ],
        error: /overlap/i,
      },
    ]
    for (const item of cases) {
      const tool = await factory({ root, target, maxBytes: 1024 * 1024 })
      const revision = page(await tool.execute({ action: "read", source: "target" })).revision
      await expectReject(
        () => tool.execute({ action: "submit", revision, operations: item.operations }),
        item.error,
      )
      expect(await readFile(target, "utf8")).toBe("one two one three\n")
    }

    const tool = await factory({ root, target, maxBytes: 1024 * 1024 })
    const revision = page(await tool.execute({ action: "read", source: "target" })).revision
    await writeFile(target, "newer user content\n")
    await expectReject(
      () =>
        tool.execute({
          action: "submit",
          revision,
          operations: [{ oldText: "three", newText: "four" }],
        }),
      /stale|revision/i,
    )
    expect(await readFile(target, "utf8")).toBe("newer user content\n")
  })

  test("accepts an empty full replacement", async () => {
    const tool = await factory({ root, target, maxBytes: 1024 * 1024 })
    const revision = page(await tool.execute({ action: "read", source: "target" })).revision
    decode(await tool.execute({ action: "submit", revision, replacement: "" }))
    expect(await readFile(target)).toHaveLength(0)
  })
})

describe("host-bound filesystem safety", () => {
  test("rejects configured paths outside root, missing paths, directories, and symlinks", async () => {
    const outside = join(dirname(root), `${crypto.randomUUID()}.ts`)
    await writeFile(outside, "outside")
    await expectReject(
      async () => (await factory({ root, target: outside, maxBytes: 1024 })).execute({ action: "read", source: "target" }),
      /contain|outside|root/i,
    )

    const missing = join(root, "missing.ts")
    await expectReject(
      async () => (await factory({ root, target: missing, maxBytes: 1024 })).execute({ action: "read", source: "target" }),
      /missing|regular|file/i,
    )

    const directory = join(root, "directory.ts")
    await mkdir(directory)
    await expectReject(
      async () => (await factory({ root, target: directory, maxBytes: 1024 })).execute({ action: "read", source: "target" }),
      /regular|file/i,
    )

    const link = join(root, "link.ts")
    await symlink(outside, link)
    await expectReject(
      async () => (await factory({ root, target: link, maxBytes: 1024 })).execute({ action: "read", source: "target" }),
      /symlink|regular|contain/i,
    )
    expect(await realpath(outside)).not.toStartWith(`${await realpath(root)}/`)
    await rm(outside, { force: true })
  })

  test("rejects a target identity swap before commit", async () => {
    const replacementFile = join(root, "replacement.ts")
    await writeFile(replacementFile, "replacement identity\n")
    const tool = await factory({
      root,
      target,
      maxBytes: 1024 * 1024,
      beforeCommit: async () => {
        await rename(replacementFile, target)
      },
    })
    const revision = page(await tool.execute({ action: "read", source: "target" })).revision
    await expectReject(
      () => tool.execute({ action: "submit", revision, replacement: "must not commit\n" }),
      /identity|changed|stale/i,
    )
    expect(await readFile(target, "utf8")).toBe("replacement identity\n")
  })

  test("enforces target and replacement size limits", async () => {
    await writeFile(target, "x".repeat(1025))
    const oversizedTarget = await factory({ root, target, maxBytes: 1024 })
    await expectReject(
      () => oversizedTarget.execute({ action: "read", source: "target" }),
      /size|large|limit|bytes/i,
    )

    await writeFile(target, "small")
    const oversizedReplacement = await factory({ root, target, maxBytes: 1024 })
    const revision = page(await oversizedReplacement.execute({ action: "read", source: "target" })).revision
    await expectReject(
      () =>
        oversizedReplacement.execute({
          action: "submit",
          revision,
          replacement: "x".repeat(1025),
        }),
      /size|large|limit|bytes/i,
    )
    expect(await readFile(target, "utf8")).toBe("small")
  })

  test("rejects invalid UTF-8 staging content", async () => {
    await writeFile(target, Uint8Array.from([0x66, 0x6f, 0x80, 0x6f]))
    const tool = await factory({ root, target, maxBytes: 1024 })
    await expectReject(
      () => tool.execute({ action: "read", source: "target" }),
      /utf-?8|encoding|invalid/i,
    )
  })
})
