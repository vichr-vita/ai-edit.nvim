import { constants } from "node:fs"
import { lstat, open, realpath, rename, rm } from "node:fs/promises"
import { createHash, randomUUID } from "node:crypto"
import { dirname, relative, resolve, sep } from "node:path"

type Source = "target" | "context"

type StageEnvironment = {
  root: string
  target: string
  context?: string
  maxBytes: number
  beforeCommit?: () => void | Promise<void>
}

type Identity = {
  dev: number | bigint
  ino: number | bigint
}

type LoadedSource = {
  bytes: Buffer
  text: string
  revision: string
  identity: Identity
}

type Cursor = {
  source: Source
  revision: string
  offset: number
}

type ExactOperation = {
  oldText: string
  newText: string
  expectedCount?: number
}

const PAGE_ENVELOPE_LIMIT = 16 * 1024
const INITIAL_PAGE_BYTES = 12 * 1024
const decoder = new TextDecoder("utf-8", { fatal: true })

function fail(message: string): never {
  throw new Error(`stage_text: ${message}`)
}

function revision(bytes: Buffer): string {
  return createHash("sha256").update(bytes).digest("hex")
}

function sameIdentity(left: Identity, right: Identity): boolean {
  return left.dev === right.dev && left.ino === right.ino
}

function validateEnvironment(environment: StageEnvironment): StageEnvironment {
  if (!environment || typeof environment !== "object") fail("missing host environment")
  if (typeof environment.root !== "string" || environment.root.length === 0) fail("missing staging root")
  if (typeof environment.target !== "string" || environment.target.length === 0) fail("missing staging target")
  if (!Number.isSafeInteger(environment.maxBytes) || environment.maxBytes <= 0) fail("invalid size limit")
  if (environment.context !== undefined && (typeof environment.context !== "string" || environment.context.length === 0)) {
    fail("invalid context path")
  }
  return environment
}

function assertOnlyKeys(input: Record<string, unknown>, allowed: string[]) {
  const allowedKeys = new Set(allowed)
  const unknown = Object.keys(input).filter((key) => !allowedKeys.has(key))
  if (unknown.length > 0) fail(`unknown argument: ${unknown.join(", ")}`)
}

async function bindPath(root: string, path: string, label: string): Promise<string> {
  const absoluteRoot = resolve(root)
  const absolutePath = resolve(path)
  const lexical = relative(absoluteRoot, absolutePath)
  if (lexical === "" || lexical === ".." || lexical.startsWith(`..${sep}`) || resolve(absoluteRoot, lexical) !== absolutePath) {
    fail(`${label} is outside staging root containment`)
  }

  let rootReal: string
  try {
    rootReal = await realpath(absoluteRoot)
  } catch {
    fail("staging root is missing")
  }

  let status
  try {
    status = await lstat(absolutePath)
  } catch {
    fail(`${label} is missing or not a regular file`)
  }
  if (status.isSymbolicLink()) fail(`${label} must not be a symlink`)
  if (!status.isFile()) fail(`${label} is not a regular file`)

  let pathReal: string
  try {
    pathReal = await realpath(absolutePath)
  } catch {
    fail(`${label} is missing or not a regular file`)
  }
  const resolvedRelative = relative(rootReal, pathReal)
  if (resolvedRelative === "" || resolvedRelative === ".." || resolvedRelative.startsWith(`..${sep}`)) {
    fail(`${label} resolves outside staging root containment`)
  }
  return absolutePath
}

async function load(path: string, maxBytes: number, label: string): Promise<LoadedSource> {
  let handle
  try {
    handle = await open(path, constants.O_RDONLY | (constants.O_NOFOLLOW ?? 0))
  } catch {
    fail(`${label} is missing, a symlink, or not a regular file`)
  }

  try {
    const before = await handle.stat()
    if (!before.isFile()) fail(`${label} is not a regular file`)
    if (before.size > maxBytes) fail(`${label} size exceeds ${maxBytes} bytes`)
    const bytes = await handle.readFile()
    const after = await handle.stat()
    if (!sameIdentity(before, after) || before.size !== after.size || bytes.byteLength !== after.size) {
      fail(`${label} identity changed while reading`)
    }
    let pathStatus
    try {
      pathStatus = await lstat(path)
    } catch {
      fail(`${label} identity changed while reading`)
    }
    if (pathStatus.isSymbolicLink() || !pathStatus.isFile() || !sameIdentity(before, pathStatus)) {
      fail(`${label} identity changed while reading`)
    }
    let text: string
    try {
      text = decoder.decode(bytes)
    } catch {
      fail(`${label} contains invalid UTF-8 encoding`)
    }
    return {
      bytes,
      text,
      revision: revision(bytes),
      identity: { dev: before.dev, ino: before.ino },
    }
  } finally {
    await handle.close()
  }
}

function utf8Page(bytes: Buffer, start: number, end: number): string | undefined {
  try {
    return decoder.decode(bytes.subarray(start, end))
  } catch {
    return undefined
  }
}

function serializedPage(source: Source, loaded: LoadedSource, startByte: number, nextCursor: () => string) {
  if (startByte < 0 || startByte > loaded.bytes.byteLength) fail("stale cursor offset")
  let endByte = Math.min(loaded.bytes.byteLength, startByte + INITIAL_PAGE_BYTES)

  while (endByte > startByte && utf8Page(loaded.bytes, startByte, endByte) === undefined) endByte -= 1
  let text = utf8Page(loaded.bytes, startByte, endByte)
  if (text === undefined) fail("page does not begin on a UTF-8 boundary")

  while (true) {
    const eof = endByte === loaded.bytes.byteLength
    const cursor = eof ? null : nextCursor()
    const value = {
      source,
      revision: loaded.revision,
      text,
      startByte,
      endByte,
      nextCursor: cursor,
      eof,
    }
    const raw = JSON.stringify(value)
    if (Buffer.byteLength(raw) < PAGE_ENVELOPE_LIMIT) return { raw, cursor, endByte, eof }
    if (endByte <= startByte) fail("serialized page envelope exceeds output limit")
    endByte = Math.max(startByte, endByte - 512)
    while (endByte > startByte && utf8Page(loaded.bytes, startByte, endByte) === undefined) endByte -= 1
    text = utf8Page(loaded.bytes, startByte, endByte)
    if (text === undefined) fail("unable to create bounded UTF-8 page")
  }
}

function exactResult(original: Buffer, operations: ExactOperation[]): Buffer {
  if (!Array.isArray(operations) || operations.length === 0) fail("submit requires one or more exact operations")
  const replacements: Array<{ start: number; end: number; bytes: Buffer }> = []

  for (const operation of operations) {
    if (!operation || typeof operation !== "object") fail("invalid exact operation")
    assertOnlyKeys(operation as unknown as Record<string, unknown>, ["oldText", "newText", "expectedCount"])
    if (typeof operation.oldText !== "string" || operation.oldText.length === 0) fail("oldText must be non-empty text")
    if (typeof operation.newText !== "string") fail("newText must be text")
    const expected = operation.expectedCount ?? 1
    if (!Number.isSafeInteger(expected) || expected <= 0) fail("expectedCount must be a positive integer")

    const needle = Buffer.from(operation.oldText, "utf8")
    const found: number[] = []
    let offset = 0
    while (offset <= original.byteLength - needle.byteLength) {
      const match = original.indexOf(needle, offset)
      if (match < 0) break
      found.push(match)
      offset = match + 1
    }
    if (found.length !== expected) {
      fail(`exact match count ${found.length} differs from expected count ${expected}`)
    }
    for (const start of found) {
      replacements.push({ start, end: start + needle.byteLength, bytes: Buffer.from(operation.newText, "utf8") })
    }
  }

  replacements.sort((left, right) => left.start - right.start || left.end - right.end)
  for (let index = 1; index < replacements.length; index += 1) {
    if (replacements[index].start < replacements[index - 1].end) fail("exact operation matches overlap")
  }

  let result = original
  for (const replacement of replacements.reverse()) {
    result = Buffer.concat([result.subarray(0, replacement.start), replacement.bytes, result.subarray(replacement.end)])
  }
  return result
}

async function atomicReplace(
  target: string,
  original: LoadedSource,
  result: Buffer,
  maxBytes: number,
  beforeCommit?: () => void | Promise<void>,
) {
  if (result.byteLength > maxBytes) fail(`replacement size exceeds ${maxBytes} bytes`)
  const temporary = resolve(dirname(target), `.stage_text-${randomUUID()}.tmp`)
  let handle
  try {
    handle = await open(temporary, constants.O_CREAT | constants.O_EXCL | constants.O_WRONLY, 0o600)
    await handle.writeFile(result)
    await handle.sync()
    await handle.close()
    handle = undefined

    if (beforeCommit) await beforeCommit()
    const current = await load(target, maxBytes, "target")
    if (!sameIdentity(original.identity, current.identity)) fail("target identity changed before commit")
    if (current.revision !== original.revision) fail("target revision became stale before commit")
    await rename(temporary, target)
  } finally {
    if (handle) await handle.close()
    await rm(temporary, { force: true })
  }
}

export async function createStageText(environment: StageEnvironment) {
  const configured = validateEnvironment(environment)
  const root = resolve(configured.root)
  const target = await bindPath(root, configured.target, "target")
  const context = configured.context ? await bindPath(root, configured.context, "context") : undefined
  const cursors = new Map<string, Cursor>()
  const targetCoverage = new Map<string, number>()
  let submitQueue = Promise.resolve()

  return {
    async execute(input: Record<string, unknown>): Promise<string> {
      if (!input || typeof input !== "object" || Array.isArray(input)) fail("input must be an object")
      if (input.action === "read") {
        assertOnlyKeys(input, ["action", "source", "cursor"])
        if (input.source !== "target" && input.source !== "context") fail("read source must be target or context")
        const source = input.source
        const path = source === "target" ? target : context
        if (!path) fail("read-only context source is unavailable")
        if (input.cursor !== undefined && typeof input.cursor !== "string") fail("cursor must be text")

        const loaded = await load(path, configured.maxBytes, source)
        let startByte = 0
        if (input.cursor !== undefined) {
          const state = cursors.get(input.cursor)
          cursors.delete(input.cursor)
          if (!state) fail("unknown or stale cursor")
          if (state.source !== source) fail("cursor belongs to another source")
          if (state.revision !== loaded.revision) fail("cursor revision is stale")
          startByte = state.offset
        } else if (source === "target" && !targetCoverage.has(loaded.revision)) {
          targetCoverage.set(loaded.revision, 0)
        }

        let issuedCursor = ""
        const result = serializedPage(source, loaded, startByte, () => {
          issuedCursor = randomUUID()
          return issuedCursor
        })
        if (result.cursor) {
          cursors.set(issuedCursor, { source, revision: loaded.revision, offset: result.endByte })
        }
        if (source === "target" && (targetCoverage.get(loaded.revision) ?? -1) === startByte) {
          targetCoverage.set(loaded.revision, result.endByte)
        }
        return result.raw
      }

      if (input.action === "submit") {
        assertOnlyKeys(input, ["action", "source", "revision", "replacement", "operations"])
        if (input.source !== undefined && input.source !== "target") fail("submit source must be target")
        if (typeof input.revision !== "string" || input.revision.length === 0) fail("submit requires a revision")
        const hasReplacement = Object.prototype.hasOwnProperty.call(input, "replacement")
        const hasOperations = Object.prototype.hasOwnProperty.call(input, "operations")
        if (hasReplacement === hasOperations) fail("submit requires exactly one replacement form")

        const previousSubmit = submitQueue
        let releaseSubmit!: () => void
        submitQueue = new Promise<void>((resolve) => {
          releaseSubmit = resolve
        })
        await previousSubmit
        try {
          const loaded = await load(target, configured.maxBytes, "target")
          if (loaded.revision !== input.revision) fail("target revision is stale")
          let result: Buffer
          if (hasReplacement) {
            if (typeof input.replacement !== "string") fail("replacement must be text")
            if ((targetCoverage.get(loaded.revision) ?? -1) !== loaded.bytes.byteLength) {
              fail("complete replacement requires sequential target read coverage through EOF")
            }
            result = Buffer.from(input.replacement, "utf8")
          } else {
            result = exactResult(loaded.bytes, input.operations as ExactOperation[])
          }
          await atomicReplace(target, loaded, result, configured.maxBytes, configured.beforeCommit)
          return JSON.stringify({ submitted: true, revision: revision(result), bytes: result.byteLength })
        } finally {
          releaseSubmit()
        }
      }

      fail("action must be read or submit")
    },
  }
}

export const createStageTextForTest = createStageText

function environmentFromProcess(): StageEnvironment | undefined {
  const root = process.env.NVIM_AI_EDIT_STAGE_ROOT
  const target = process.env.NVIM_AI_EDIT_STAGE_TARGET
  const maxBytes = Number(process.env.NVIM_AI_EDIT_MAX_BYTES)
  if (!root || !target || !Number.isSafeInteger(maxBytes) || maxBytes <= 0) return undefined
  return {
    root,
    target,
    context: process.env.NVIM_AI_EDIT_CONTEXT || undefined,
    maxBytes,
  }
}

let defaultTool: unknown = {}
const processEnvironment = environmentFromProcess()
if (processEnvironment) {
  const { tool } = await import("@opencode-ai/plugin")
  const stage = await createStageText(processEnvironment)
  defaultTool = tool({
    description:
      'Read bounded UTF-8 pages from the host-selected target or context, then submit one revision-checked target edit. Submit source may be omitted or "target"; context is read-only.',
    args: {
      action: tool.schema.enum(["read", "submit"]).describe('Use "read" before one final "submit".'),
      source: tool.schema
        .enum(["target", "context"])
        .optional()
        .describe('Required for read. For submit, omit this or use "target"; never use "context".'),
      cursor: tool.schema.string().optional(),
      revision: tool.schema.string().optional(),
      replacement: tool.schema.string().optional(),
      operations: tool.schema
        .array(
          tool.schema.object({
            oldText: tool.schema.string(),
            newText: tool.schema.string(),
            expectedCount: tool.schema.number().int().positive().optional(),
          }),
        )
        .optional(),
    },
    async execute(input) {
      return stage.execute(input)
    },
  })
}

export default defaultTool
