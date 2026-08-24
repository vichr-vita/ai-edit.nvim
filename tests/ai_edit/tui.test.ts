import { afterEach, describe, expect, test } from "bun:test"
import { mkdtemp, rm, writeFile } from "node:fs/promises"
import { tmpdir } from "node:os"
import { join } from "node:path"

const children: Bun.Subprocess[] = []

afterEach(async () => {
  for (const child of children.splice(0)) {
    if (child.exitCode === null) child.kill("SIGKILL")
    await child.exited.catch(() => {})
    child.terminal?.close()
  }
})

async function remote(socket: string, expression: string) {
  const child = Bun.spawn(["nvim", "--server", socket, "--remote-expr", expression], {
    cwd: process.cwd(),
    stdin: "ignore",
    stdout: "pipe",
    stderr: "pipe",
  })
  const [code, stdout, stderr] = await Promise.all([
    child.exited,
    new Response(child.stdout).text(),
    new Response(child.stderr).text(),
  ])
  if (code !== 0) throw new Error(`remote expression failed (${code}): ${expression}\n${stderr}`)
  return stdout.trim()
}

async function remoteSend(socket: string, keys: string) {
  const child = Bun.spawn(["nvim", "--server", socket, "--remote-send", keys], {
    cwd: process.cwd(),
    stdin: "ignore",
    stdout: "ignore",
    stderr: "pipe",
  })
  const [code, stderr] = await Promise.all([child.exited, new Response(child.stderr).text()])
  if (code !== 0) throw new Error(`remote send failed (${code}): ${keys}\n${stderr}`)
}

async function waitFor(predicate: () => boolean | Promise<boolean>, message: string, timeout = 20000) {
  const deadline = Date.now() + timeout
  while (Date.now() < deadline) {
    if (await predicate()) return
    await Bun.sleep(20)
  }
  throw new Error(message)
}

describe("AI edit TUI caret", () => {
  test(
    "hides only locked-target editing caret and restores it on cleanup",
    async () => {
      const root = await mkdtemp(join(tmpdir(), "ai-edit-tui-"))
      const target = join(root, "target.lua")
      const socket = join(root, "nvim.sock")
      await writeFile(target, "return 'before'\n")

      let output = ""
      const decoder = new TextDecoder()
      const child = Bun.spawn(["nvim", "-u", "tests/ai_edit/tui_init.lua", "--listen", socket, target], {
        cwd: process.cwd(),
        env: {
          ...process.env,
          TERM: "xterm-256color",
          AI_EDIT_FAKE_LOG: join(root, "fake.log"),
          AI_EDIT_FAKE_SCENARIO: "run-hold",
        },
        terminal: {
          cols: 80,
          rows: 24,
          data(_terminal, data) {
            output += decoder.decode(data, { stream: true })
          },
        },
      })
      children.push(child)
      const terminal = child.terminal!

      const cursorVisible = () => {
        let visible: boolean | undefined
        for (const match of output.matchAll(/\x1b\[\?25([hl])/g)) visible = match[1] === "h"
        return visible
      }
      const waitCursor = async (visible: boolean, message: string, timeout?: number) => {
        await waitFor(async () => {
          if (cursorVisible() !== visible) return false
          await Bun.sleep(80)
          return cursorVisible() === visible
        }, message, timeout)
      }

      try {
        await waitFor(async () => remote(socket, "v:servername").then((value) => value !== "", () => false), "Neovim server did not start")
        expect(await remote(socket, "&guicursor =~# 'AIEditHiddenCursor'")).toBe("0")
        await waitCursor(true, "default TUI caret was not visible")

        const targetBuffer = Number(await remote(socket, "bufnr('%')"))
        await remoteSend(socket, "<F8>")
        await waitFor(async () => (await remote(socket, "&buftype")) === "nofile", "AI edit prompt did not open")
        terminal.write("hide caret while running\r")
        await waitFor(async () => (await remote(socket, `getbufvar(${targetBuffer}, '&modifiable')`)) === "0", "target did not lock")
        await remote(socket, "execute('redraw!')")
        const blendOnlyCursor = process.platform === "linux" || (await remote(socket, "has('nvim-0.12')")) === "1"
        let terminalVisibility = !blendOnlyCursor
        if (terminalVisibility) {
          await waitCursor(false, "locked-target TUI caret stayed visible")
        } else {
          try {
            await waitCursor(false, "locked-target TUI caret stayed visible", 5000)
            terminalVisibility = true
          } catch {
            console.warn("TUI did not expose blend-based cursor visibility; verifying Neovim cursor ownership")
            expect(await remote(socket, "&guicursor =~# 'AIEditHiddenCursor'")).toBe("1")
            expect(await remote(socket, "luaeval(\"vim.api.nvim_get_hl(0, { name = 'AIEditHiddenCursor' }).blend\")")).toBe("100")
          }
        }

        if (terminalVisibility) {
          terminal.write(":")
          await waitCursor(true, "command-line caret was hidden")
          terminal.write("\x1b")
          await waitCursor(false, "target caret did not hide after leaving command line")
        }

        await remoteSend(socket, ":enew<CR>")
        await waitFor(async () => Number(await remote(socket, "bufnr('%')")) !== targetBuffer, "unrelated buffer did not open")
        if (terminalVisibility) await waitCursor(true, "unrelated-buffer caret stayed hidden")
        else expect(await remote(socket, "&guicursor =~# 'AIEditHiddenCursor'")).toBe("0")

        await remoteSend(socket, `:buffer ${targetBuffer}<CR>`)
        await waitFor(async () => Number(await remote(socket, "bufnr('%')")) === targetBuffer, "target buffer did not redisplay")
        if (terminalVisibility) await waitCursor(false, "redisplayed locked-target caret stayed visible")
        else expect(await remote(socket, "&guicursor =~# 'AIEditHiddenCursor'")).toBe("1")

        if (terminalVisibility) {
          terminal.write(":")
          await waitCursor(true, "cancel command-line caret was hidden")
          terminal.write("AIEditCancel\r")
        } else {
          await remoteSend(socket, ":AIEditCancel<CR>")
        }
        await waitFor(async () => (await remote(socket, `getbufvar(${targetBuffer}, '&modifiable')`)) === "1", "cancel did not unlock target")
        await waitFor(
          async () => (await remote(socket, 'luaeval("require(\'ai_edit\').statusline()")')) === "",
          "cancel did not finish job",
        )
        if (terminalVisibility) await waitCursor(true, "terminal cleanup did not restore TUI caret")
        else expect(await remote(socket, "&guicursor =~# 'AIEditHiddenCursor'")).toBe("0")

        terminal.write(":qa!\r")
        expect(await child.exited).toBe(0)
      } finally {
        if (child.exitCode === null) child.kill("SIGKILL")
        await child.exited.catch(() => {})
        terminal.close()
        children.splice(children.indexOf(child), 1)
        await rm(root, { recursive: true, force: true })
      }
    },
    60_000,
  )
})
