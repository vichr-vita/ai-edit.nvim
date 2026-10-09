import { expect, test } from "bun:test"
import { mkdir, mkdtemp, readFile, readdir, rm, writeFile } from "node:fs/promises"
import { tmpdir } from "node:os"
import { join } from "node:path"

type CompletionRequest = {
  model: string
  stream: boolean
  tools?: unknown[]
  messages: { role: string; content: string | { text?: string }[] }[]
}

test("installed Pi edits only buffer context with no tools or inherited resources", async () => {
  const root = await mkdtemp(join(tmpdir(), "ai-edit-real-pi-"))
  const requests: CompletionRequest[] = []
  const server = Bun.serve({
    hostname: "127.0.0.1",
    port: 0,
    async fetch(request) {
      if (new URL(request.url).pathname !== "/v1/chat/completions") return new Response("unexpected path", { status: 404 })
      const body = await request.json() as CompletionRequest
      requests.push(body)
      const content = requests.length === 1 ? "return 'from Pi'\n" : "BETA"
      const chunk = (delta: Record<string, string>, finishReason: string | null) => `data: ${JSON.stringify({
        id: "pi-ci", object: "chat.completion.chunk", created: 0, model: "buffer",
        choices: [{ index: 0, delta, finish_reason: finishReason }],
      })}\n\n`
      return new Response(chunk({ role: "assistant", content }, null) + chunk({}, "stop") + "data: [DONE]\n\n", {
        headers: { "Content-Type": "text/event-stream" },
      })
    },
  })
  let child: Bun.Subprocess | undefined
  try {
    const config = join(root, "config")
    const project = join(root, "project")
    await mkdir(config)
    await mkdir(join(project, ".pi"), { recursive: true })
    const extension = join(root, "hostile.ts")
    await writeFile(extension, `throw new Error("HOSTILE_EXTENSION_LOADED")\n`)
    for (const directory of [config, join(project, ".pi")]) {
      await writeFile(join(directory, "settings.json"), JSON.stringify({
        defaultProvider: "pi-ci", defaultModel: "buffer", defaultTools: ["bash"], extensions: [extension],
      }))
      await writeFile(join(directory, "SYSTEM.md"), "HOSTILE_SYSTEM_INSTRUCTIONS")
      await writeFile(join(directory, "APPEND_SYSTEM.md"), "HOSTILE_APPEND_INSTRUCTIONS")
    }
    await writeFile(join(config, "AGENTS.md"), "HOSTILE_USER_INSTRUCTIONS")
    await writeFile(join(project, "AGENTS.md"), "HOSTILE_PROJECT_INSTRUCTIONS")
    await writeFile(join(config, "models.json"), JSON.stringify({
      providers: {
        "pi-ci": {
          baseUrl: `http://127.0.0.1:${server.port}/v1`, api: "openai-completions", apiKey: "ci-local-key",
          models: [{ id: "buffer", reasoning: false, input: ["text"], contextWindow: 8192, maxTokens: 1024 }],
        },
      },
    }))
    child = Bun.spawn(["nvim", "--headless", "-u", "tests/ai_edit/minimal_init.lua", "-l", "tests/ai_edit/real_pi.lua"], {
      cwd: process.cwd(),
      env: { ...process.env, AI_EDIT_REAL_ROOT: root, XDG_CACHE_HOME: join(root, "cache") },
      stdin: "ignore", stdout: "pipe", stderr: "pipe",
    })
    const [code, stdout, stderr] = await Promise.all([
      child.exited, new Response(child.stdout).text(), new Response(child.stderr).text(),
    ])
    expect(code, `${stdout}\n${stderr}`).toBe(0)
    expect(requests).toHaveLength(2)
    const prompt = (await readFile("lua/ai_edit/prompt.md", "utf8")).trim()
    for (const request of requests) {
      expect(request.model).toBe("buffer")
      expect(request.stream).toBe(true)
      expect(request.tools ?? []).toHaveLength(0)
      const system = request.messages.filter((message) => message.role === "system")
      expect(system).toHaveLength(1)
      const systemContent = system[0]?.content
      expect(typeof systemContent).toBe("string")
      if (typeof systemContent !== "string") throw new Error("expected text system prompt")
      // Pi appends the private working directory even with a custom system prompt.
      expect(systemContent.replace(/\n+<cwd>\n[^\n]+\n<\/cwd>$/, "")).toBe(prompt)
      expect(systemContent).toMatch(/<cwd>\n[^\n]+\/nvim-ai-edit\/staging\/[a-f0-9]{24}\n<\/cwd>$/)
      expect(JSON.stringify(request.messages)).not.toContain("HOSTILE_")
      expect(JSON.stringify(request.messages)).not.toContain("disk sentinel")
    }
    expect(JSON.stringify(requests[0]?.messages)).toContain("unsaved snapshot")
    expect(JSON.stringify(requests[1]?.messages)).toContain("alpha beta omega")
    expect(await readdir(join(root, "cache/nvim/nvim-ai-edit/staging"))).toHaveLength(0)
  } finally {
    if (child?.exitCode === null) child.kill("SIGKILL")
    await child?.exited
    server.stop(true)
    await rm(root, { recursive: true, force: true })
  }
}, 90_000)
