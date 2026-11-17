# Git Hooks

[English](<README.md>) | [简体中文](<README.zh-CN.md>)

## Pre-commit Hook

The [pre-commit hook](pre-commit) runs `moon check` from the repository root
before a commit. Install the MoonBit toolchain and make `moon` available on
`PATH` before enabling it. A failed check blocks the commit. The hook uses the
working tree and the module's default target; it does not limit checks to staged
files or run formatting, tests, or moonlint.

### Usage Instructions

To use this pre-commit hook:

1. Make the hook executable if it isn't already:
   ```bash
   chmod +x .githooks/pre-commit
   ```

2. Configure Git to use the hooks in the .githooks directory:
   ```bash
   git config core.hooksPath .githooks
   ```

3. The hook will automatically run when you execute `git commit`.
