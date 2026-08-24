import { afterAll, beforeAll, describe, expect, test } from "bun:test"
import { createHash } from "node:crypto"
import { chmod, cp, lstat, mkdir, mkdtemp, readFile, readdir, rm, writeFile } from "node:fs/promises"
import { tmpdir } from "node:os"
import { join, resolve } from "node:path"

const opencode = Bun.which("opencode")
let sandbox = ""
let project = ""
let stageRoot = ""
let stageTarget = ""
let projectTarget = ""
let projectBytes = ""
let env: Record<string, string | undefined> = {}
let discoveryEnv: Record<string, string | undefined> = {}
let globalToolSentinel = ""
let globalConfigHome = ""
let globalHome = ""
let isolatedCacheHome = ""
let emptyManagedConfigDir = ""
let sessionsBefore = new Set<string>()

async function setTreeMode(path: string, readonly: boolean) {
  const info = await lstat(path)
  if (info.isSymbolicLink()) return
  if (info.isDirectory()) {
    if (!readonly) await chmod(path, 0o700)
    for (const entry of await readdir(path)) await setTreeMode(join(path, entry), readonly)
    if (readonly) await chmod(path, 0o500)
  } else {
    await chmod(path, readonly ? 0o400 : 0o600)
  }
}

async function run(args: string[], cwd = project, environment = env) {
  if (!opencode) throw new Error("opencode executable is unavailable")
  const child = Bun.spawn([opencode, ...args], {
    cwd,
    env: environment,
    stdin: "ignore",
    stdout: "pipe",
    stderr: "pipe",
  })
  const timeout = setTimeout(() => child.kill(), 60_000)
  const [code, stdout, stderr] = await Promise.all([
    child.exited,
    new Response(child.stdout).text(),
    new Response(child.stderr).text(),
  ])
  clearTimeout(timeout)
  return { code, stdout, stderr }
}

beforeAll(async () => {
  sandbox = await mkdtemp(join(tmpdir(), "ai-edit-real-opencode-"))
  project = join(sandbox, "project")
  await cp(resolve("tests/ai_edit/fixtures/hostile-project"), project, { recursive: true })
  const git = Bun.spawn(["git", "init", "-q", project], { stdout: "ignore", stderr: "pipe" })
  expect(await git.exited, await new Response(git.stderr).text()).toBe(0)

  await mkdir(join(project, "src"), { recursive: true })
  projectTarget = join(project, "src/target.ts")
  projectBytes = "REAL_PROJECT_TARGET\nunchanged bytes\n"
  await writeFile(projectTarget, projectBytes)

  stageRoot = join(sandbox, "stage")
  stageTarget = join(stageRoot, "target.ts")
  await mkdir(stageRoot, { mode: 0o700 })
  await writeFile(stageTarget, "staged original\n")

  globalToolSentinel = join(sandbox, "GLOBAL_TOOL_EXECUTED")
  globalConfigHome = join(sandbox, "hostile-global-config")
  const globalConfigDir = join(globalConfigHome, "opencode")
  globalHome = join(sandbox, "hostile-home")
  await mkdir(join(globalConfigDir, "tool"), { recursive: true })
  await mkdir(globalHome)
  await writeFile(
    join(globalConfigDir, "tool/hostile-global.ts"),
    `import { writeFileSync } from "node:fs"\nwriteFileSync(process.env.AI_EDIT_GLOBAL_TOOL_SENTINEL!, "global tool imported\\n")\nexport default { description: "must not import", args: {}, execute: async () => "no" }\n`,
  )
  await writeFile(
    join(globalConfigDir, "opencode.json"),
    JSON.stringify({ model: "opencode/big-pickle", provider: { opencode: { options: { inherited: true } } } }),
  )

  const isolatedConfigHome = join(sandbox, "isolated-runtime")
  const configDir = join(isolatedConfigHome, "opencode")
  isolatedCacheHome = join(sandbox, "empty-xdg-cache")
  emptyManagedConfigDir = join(sandbox, "empty-managed-config")
  const isolatedHome = join(sandbox, "isolated-home")
  await mkdir(join(configDir, "tool"), { recursive: true, mode: 0o700 })
  await mkdir(isolatedCacheHome)
  await mkdir(emptyManagedConfigDir)
  await mkdir(isolatedHome)
  expect(await readdir(isolatedCacheHome)).toEqual([])
  const helperSource = await readFile(resolve("lua/vichr/ai_edit/stage_text.ts"))
  await writeFile(join(configDir, "tool/stage_text.ts"), helperSource)
  await writeFile(join(configDir, "package.json"), JSON.stringify({ dependencies: { "@opencode-ai/plugin": "1.18.21" } }))

  const permission = {
    invalid: "deny",
    read: "allow",
    glob: "allow",
    grep: "allow",
    stage_text: "allow",
    apply_patch: "deny",
    edit: "deny",
    write: "deny",
    bash: "deny",
    webfetch: "deny",
    websearch: "deny",
    codesearch: "deny",
    task: "deny",
    todowrite: "deny",
    question: "deny",
    skill: "deny",
    external_directory: "deny",
    lsp: "deny",
  }
  const tools = {
    invalid: false,
    read: true,
    glob: true,
    grep: true,
    stage_text: true,
    apply_patch: false,
    edit: false,
    write: false,
    bash: false,
    webfetch: false,
    websearch: false,
    codesearch: false,
    task: false,
    todowrite: false,
    question: false,
    skill: false,
  }
  const config = {
    model: "opencode/big-pickle",
    provider: { opencode: { options: { inherited: true } } },
    share: "disabled",
    snapshot: false,
    formatter: false,
    lsp: false,
    plugin: [],
    tool_output: { max_bytes: 32768, max_lines: 10 },
    tools,
    permission,
    agent: {
      "real-hostile": {
        mode: "primary",
        disable: false,
        prompt: "Use only the host-bound staging tool.",
        permission,
      },
    },
  }
  const { OPENCODE_DISABLE_DEFAULT_PLUGINS: _disabledDefaults, ...trustedBundleEnvironment } = process.env
  env = {
    ...trustedBundleEnvironment,
    XDG_CONFIG_HOME: isolatedConfigHome,
    XDG_CACHE_HOME: isolatedCacheHome,
    OPENCODE_TEST_HOME: isolatedHome,
    OPENCODE_TEST_MANAGED_CONFIG_DIR: emptyManagedConfigDir,
    OPENCODE_CONFIG_DIR: configDir,
    OPENCODE_CONFIG_CONTENT: JSON.stringify(config),
    OPENCODE_PURE: "1",
    OPENCODE_DISABLE_PROJECT_CONFIG: "1",
    OPENCODE_DISABLE_AUTOSHARE: "1",
    NVIM_AI_EDIT_STAGE_ROOT: stageRoot,
    NVIM_AI_EDIT_STAGE_TARGET: stageTarget,
    NVIM_AI_EDIT_MAX_BYTES: String(1024 * 1024),
    AI_EDIT_GLOBAL_TOOL_SENTINEL: globalToolSentinel,
  }
  const bootstrap = await run(["debug", "agent", "real-hostile", "--pure"])
  expect(bootstrap.code, bootstrap.stderr).toBe(0)
  const installedPlugin = JSON.parse(await readFile(join(configDir, "node_modules/@opencode-ai/plugin/package.json"), "utf8"))
  expect(installedPlugin.version).toBe("1.18.21")
  expect(await Bun.file(join(configDir, "node_modules/@opencode-ai/plugin/dist/index.js")).exists()).toBe(true)

  discoveryEnv = {
    ...trustedBundleEnvironment,
    XDG_CONFIG_HOME: globalConfigHome,
    XDG_CACHE_HOME: isolatedCacheHome,
    OPENCODE_TEST_HOME: globalHome,
    OPENCODE_TEST_MANAGED_CONFIG_DIR: emptyManagedConfigDir,
    OPENCODE_CONFIG_CONTENT: JSON.stringify({ ...config, model: undefined, provider: undefined }),
    OPENCODE_PURE: "1",
    OPENCODE_DISABLE_PROJECT_CONFIG: "1",
    OPENCODE_DISABLE_AUTOSHARE: "1",
    AI_EDIT_GLOBAL_TOOL_SENTINEL: globalToolSentinel,
  }
  const sessions = await run(["session", "list", "--format", "json"])
  expect(sessions.code, sessions.stderr).toBe(0)
  sessionsBefore = new Set(JSON.parse(sessions.stdout).map((session: { id: string }) => session.id))
  await setTreeMode(configDir, true)
}, 90_000)

afterAll(async () => {
  if (project && opencode) {
    const sessions = await run(["session", "list", "--format", "json"])
    if (sessions.code === 0) {
      for (const session of JSON.parse(sessions.stdout) as { id: string }[]) {
        if (!sessionsBefore.has(session.id)) await run(["session", "delete", session.id])
      }
    }
  }
  await setTreeMode(sandbox, false).catch(() => {})
  await rm(sandbox, { recursive: true, force: true })
}, 30_000)

describe("installed OpenCode hostile boundary", () => {
  test("rejects managed local MCP before process execution or session creation", async () => {
    expect(opencode).toBeTruthy()
    const managedConfigDir = join(sandbox, "managed-local-mcp")
    const mcpCommand = join(sandbox, "hostile-mcp")
    const mcpSentinel = join(sandbox, "MCP_EXECUTED")
    await mkdir(managedConfigDir)
    await writeFile(mcpCommand, '#!/bin/sh\nprintf "managed MCP executed\\n" > "$AI_EDIT_MCP_SENTINEL"\n')
    await chmod(mcpCommand, 0o700)
    await writeFile(
      join(managedConfigDir, "opencode.json"),
      JSON.stringify({ mcp: { hostile: { type: "local", command: [mcpCommand], enabled: true } } }),
    )

    const before = await run(["session", "list", "--format", "json"])
    expect(before.code, before.stderr).toBe(0)
    const child = Bun.spawn(
      ["nvim", "--headless", "-u", "tests/ai_edit/minimal_init.lua", "-l", "tests/ai_edit/real_mcp_guard.lua"],
      {
        cwd: process.cwd(),
        env: {
          ...process.env,
          XDG_CONFIG_HOME: globalConfigHome,
          XDG_CACHE_HOME: isolatedCacheHome,
          OPENCODE_TEST_HOME: globalHome,
          OPENCODE_TEST_MANAGED_CONFIG_DIR: managedConfigDir,
          OPENCODE_CONFIG: undefined,
          OPENCODE_CONFIG_DIR: undefined,
          OPENCODE_CONFIG_CONTENT: undefined,
          AI_EDIT_MCP_SENTINEL: mcpSentinel,
          AI_EDIT_REAL_PROJECT: project,
          AI_EDIT_REAL_OPENCODE: opencode!,
        },
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
    expect(code, `${stdout}\n${stderr}`).toBe(0)
    expect(`${stdout}\n${stderr}`).toContain("installed OpenCode managed MCP guard passed")
    await Bun.sleep(100)
    expect(await Bun.file(mcpSentinel).exists(), "managed MCP process executed").toBe(false)

    const after = await run(["session", "list", "--format", "json"])
    expect(after.code, after.stderr).toBe(0)
    expect(JSON.parse(after.stdout)).toEqual(JSON.parse(before.stdout))
    expect(await readFile(projectTarget, "utf8")).toBe(projectBytes)
  }, 30_000)

  test("keeps project extensions unloaded and all writes staged", async () => {
    expect(opencode).toBeTruthy()
    const version = await run(["--version"])
    expect(version.code, version.stderr).toBe(0)
    expect(version.stdout.trim()).toBe("1.18.21")
    expect(env.OPENCODE_DISABLE_DEFAULT_PLUGINS).toBeUndefined()

    const discovered = await run(["debug", "config", "--pure"], project, discoveryEnv)
    expect(discovered.code, discovered.stderr).toBe(0)
    expect(JSON.parse(discovered.stdout).model).toBe("opencode/big-pickle")
    expect(JSON.parse(discovered.stdout).provider.opencode.options.inherited).toBe(true)
    expect(await Bun.file(globalToolSentinel).exists(), "global tool during config resolution").toBe(false)

    const resolved = await run(["debug", "config", "--pure"])
    expect(resolved.code, resolved.stderr).toBe(0)
    const config = JSON.parse(resolved.stdout)
    expect(config.share).toBe("disabled")
    expect(config.snapshot).toBe(false)
    expect(config.formatter).toBe(false)
    expect(config.lsp).toBe(false)
    expect(config.plugin).toEqual([])
    expect(config.tool_output).toEqual({ max_bytes: 32768, max_lines: 10 })
    expect(await Bun.file(join(project, "PLUGIN_EXECUTED")).exists(), "plugin after config preflight").toBe(false)

    const agentResult = await run([
      "debug",
      "agent",
      "real-hostile",
      "--pure",
      "--print-logs",
      "--log-level",
      "DEBUG",
    ])
    expect(agentResult.code, agentResult.stderr).toBe(0)
    const agent = JSON.parse(agentResult.stdout)
    const enabled = Object.entries(agent.tools)
      .filter(([, value]) => value === true)
      .map(([name]) => name)
      .sort()
    expect(enabled).toEqual(["glob", "grep", "read", "stage_text"])
    expect(agent.tools.apply_patch).not.toBe(true)
    expect(await Bun.file(join(project, "PLUGIN_EXECUTED")).exists(), "plugin after agent preflight").toBe(false)
    expect(await Bun.file(globalToolSentinel).exists(), "global tool after agent preflight").toBe(false)

    const denied = await run([
      "debug",
      "agent",
      "real-hostile",
      "--pure",
      "--tool",
      "apply_patch",
      "--params",
      JSON.stringify({ patchText: "*** Begin Patch\n*** Update File: src/target.ts\n@@\n-REAL\n+MUTATED\n*** End Patch" }),
    ])
    expect(denied.code).not.toBe(0)
    expect(denied.stderr).toMatch(/disabled|not found/)
    expect(await readFile(projectTarget, "utf8")).toBe(projectBytes)
    expect(await Bun.file(join(project, "PLUGIN_EXECUTED")).exists(), "plugin after denied tool").toBe(false)

    const originalStage = await readFile(stageTarget)
    const submitted = await run([
      "debug",
      "agent",
      "real-hostile",
      "--pure",
      "--tool",
      "stage_text",
      "--params",
      JSON.stringify({
        action: "submit",
        revision: createHash("sha256").update(originalStage).digest("hex"),
        operations: [{ oldText: "staged original\n", newText: "real staged result\n", expectedCount: 1 }],
      }),
    ])
    expect(submitted.code, submitted.stderr).toBe(0)
    expect(await readFile(stageTarget, "utf8")).toBe("real staged result\n")
    expect(await readFile(projectTarget, "utf8")).toBe(projectBytes)
    expect(await Bun.file(join(project, "PLUGIN_EXECUTED")).exists(), "plugin after staged submit").toBe(false)

    for (const sentinel of [
      "PLUGIN_EXECUTED",
      "TOOL_EXECUTED",
      "FORMATTER_EXECUTED",
      "LSP_EXECUTED",
      "MOVED_BY_APPLY_PATCH",
    ]) {
      expect(await Bun.file(join(project, sentinel)).exists(), sentinel).toBe(false)
    }
    expect(await Bun.file(globalToolSentinel).exists(), "global tool after run-equivalent tool loading").toBe(false)

  }, 60_000)

  test.skipIf(process.env.AI_EDIT_RUN_OAUTH_SMOKE !== "1")(
    "uses bundled OpenAI OAuth while keeping hostile project extensions disabled",
    async () => {
      const sessionsBeforeSmoke = await run(["session", "list", "--format", "json"])
      expect(sessionsBeforeSmoke.code, sessionsBeforeSmoke.stderr).toBe(0)
      const smoke = Bun.spawn(
        ["nvim", "--headless", "-u", "tests/ai_edit/minimal_init.lua", "-l", "tests/ai_edit/real_oauth_smoke.lua"],
        {
          cwd: process.cwd(),
          env: {
            ...process.env,
            AI_EDIT_REAL_PROJECT: project,
            AI_EDIT_REAL_OPENCODE: opencode!,
          },
          stdout: "pipe",
          stderr: "pipe",
        },
      )
      const [smokeCode, smokeStdout, smokeStderr] = await Promise.all([
        smoke.exited,
        new Response(smoke.stdout).text(),
        new Response(smoke.stderr).text(),
      ])
      expect(smokeCode, `${smokeStdout}\n${smokeStderr}`).toBe(0)
      expect(`${smokeStdout}\n${smokeStderr}`).toContain(
        "OpenCode whole-buffer and UTF-8 selection OAuth smoke passed",
      )
      expect(await readFile(projectTarget, "utf8")).toBe(projectBytes)
      expect(await Bun.file(join(project, "PLUGIN_EXECUTED")).exists()).toBe(false)
      expect(await Bun.file(globalToolSentinel).exists()).toBe(false)

      const sessionsAfterSmoke = await run(["session", "list", "--format", "json"])
      expect(sessionsAfterSmoke.code, sessionsAfterSmoke.stderr).toBe(0)
      expect(JSON.parse(sessionsAfterSmoke.stdout)).toEqual(JSON.parse(sessionsBeforeSmoke.stdout))
    },
    210_000,
  )
})
