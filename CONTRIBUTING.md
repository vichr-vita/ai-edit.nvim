# Contributing

## Tools

- Neovim 0.11 or newer.
- Bun 1.3 or newer.
- StyLua 2.0 or newer.
- Baseline OpenCode 1.18.21 for installed boundary checks.

Bun and StyLua are contributor dependencies. Users do not need them separately from OpenCode.

## Checks

Run required fake, headless, TUI, documentation, formatting, and installed-boundary checks:

```sh
bun tests/ai_edit/run.ts all
```

Groups can run separately:

```sh
bun tests/ai_edit/run.ts fake
bun tests/ai_edit/run.ts opencode
```

`opencode` requires installed exact baseline OpenCode 1.18.21. Fake regressions cover higher compatible stable versions and exact matching helper SDK selection.

Optional OAuth smoke requires trusted credentials and network access, contacts a real provider, and may cost money:

```sh
AI_EDIT_RUN_OAUTH_SMOKE=1 bun tests/ai_edit/run.ts oauth
```

Never run credentialed smoke for untrusted pull requests. Record whether it ran in release notes.

## Pull requests

- Keep behavior changes focused and update tests plus README/help together.
- Run `bun tests/ai_edit/run.ts all`.
- Run `git diff --check`.
- Do not weaken helper-cache permissions, project-extension isolation, tool allowlists, or supported version boundaries to make a test pass.

## Release

1. Confirm Linux CI on Neovim 0.11 and stable, plus macOS CI on stable.
2. Confirm baseline OpenCode 1.18.21 hostile-boundary checks pass.
3. Record optional OAuth smoke result.
4. Clone public remote into a fresh directory.
5. Install it through a fresh Lazy configuration with `main = 'ai_edit'` and `opts = {}`.
6. Run health plus fake whole-buffer and UTF-8 selection smoke tests from remote content.
7. Confirm docs state Neovim 0.11+, macOS/Linux, and stable OpenCode `>=1.18.21 <2.0.0` with exact matching helper SDK.
8. Tag `v0.1.0`, push tag, then publish GitHub release.

Do not tag before required CI and remote-clone verification pass.
