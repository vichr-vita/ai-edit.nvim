# Contributing

## Tools

Use Neovim 0.11 or newer, a current Pi CLI, and StyLua 2.0 or newer. Bun 1.3 or newer runs the existing test utilities.

## Checks

The existing tests and CI target the previous OpenCode implementation. They need migration to the Pi invocation, code-only response protocol, and dedicated configuration directory. Do not treat that suite as validation of the new runner.

For future changes, run focused checks appropriate to the behavior being changed. Credentialed provider runs require trusted credentials and network access and may cost money. Never run them for untrusted pull requests.

## Pull requests

Keep changes focused and update README and Neovim help together. Describe what was tested and what remains unverified. Preserve the buffer-only model context, disabled tools and resource discovery, private staging permissions, and stale-result protection.

## Release

Before a release, migrate the runner tests and CI, exercise Pi on Linux and macOS, and confirm whole-buffer edits, UTF-8 selections, cancellation, timeout, and one-step undo. Install from the public repository in a fresh Neovim configuration and confirm the documented authentication setup. Tag and publish only after those checks pass.
