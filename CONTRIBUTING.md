# Contributing

## Tools

Use Neovim 0.11 or newer, Pi 1.1.0 or newer, Node.js 22.19 or newer, Bun 1.3 or newer, and StyLua 2.0 or newer. CI pins Pi 1.1.0.

## Checks

Run all required checks:

```sh
bun tests/ai_edit/run.ts all
```

Use `fake` for fixture-based headless, prompt, health, documentation, TUI, and staging checks. Use `pi` for the installed CLI integration. That integration talks to a local provider stub and needs no credentials or billable requests.

For future changes, run focused checks appropriate to the behavior being changed. Credentialed provider runs require trusted credentials and network access and may cost money. Never run them for untrusted pull requests.

## Pull requests

Keep changes focused and update README and Neovim help together. Describe what was tested and what remains unverified. Preserve the buffer-only model context, disabled tools and resource discovery, private staging permissions, and stale-result protection.

## Release

Before a release, confirm CI passes on Linux and macOS and exercise whole-buffer edits, UTF-8 selections, cancellation, timeout, and one-step undo. Install from the public repository in a fresh Neovim configuration and confirm the documented authentication setup. Tag and publish only after those checks pass.
