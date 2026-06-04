---
name: plugin-security-scan
description: Scan ghostty-mirror.nvim for security vulnerabilities and report them in order of importance. Strictly read-only — it reports findings in the conversation and never edits code, files issues, or commits. Use when the user asks for a security scan, audit, or review of the plugin, runs /plugin-security-scan, or wants a safety pass before a release.
---

# Plugin security scan

Static security review of this repository. The output is a report, ordered
most important first. What to do about each finding is the user's call.

## Ground rules

- **Read-only.** Do not edit any file, create issues or TODOs, commit, or
  push. Read-only shell commands (grep, git log, ls) are fine; nothing that
  writes.
- **Report everything you find, even hardening-level nits** — but ranked, so
  the user can stop reading when the severity drops below their bar.
- If a previous scan's findings are mentioned in the conversation, re-verify
  rather than re-report: a finding that no longer reproduces is worth
  flagging as fixed.

## Threat model

What counts as untrusted input to this plugin:

- **Colorscheme names** — arrive via the `ColorScheme` event's `match` and
  via `theme_file` (which any process, or another nvim instance, can write).
  They flow into filesystem paths, a Ghostty config line, a tmux
  `source-file` command, and `vim.cmd.colorscheme`.
- **Contents of shared files** — `theme_file`, the tmux pointer, and
  everything under both `themes_dir`s live at predictable paths and are
  read back and acted on. tmux conf is *code*: a sourced file can
  `run-shell`.
- **User config** — `overrides` values and `reload_command` are trusted as
  intent but must not be corrupted into something that executes or writes
  outside the owned paths.
- **Environment** — `$PATH` resolution for `pkill`/`tmux`/`pgrep`,
  `$XDG_CONFIG_HOME`/`$HOME` expansion.
- **Highlight-derived strings** — colors read from `nvim_get_hl` and
  `g:terminal_color_*` (any plugin can set these) that get written into
  generated files.

## Scan dimensions, in priority order

1. **Command execution.** Every `vim.system`, `vim.fn.system`,
   `os.execute`, `io.popen`, `jobstart` call. For each: argv list or shell
   string? Where does each argument come from? Can untrusted input reach
   it?
2. **Injection into interpreted files.** Every line written into
   `theme_file` (Ghostty parses it) and the tmux pointer/themes
   (`source-file`, `set -g` — tmux executes these). Check quoting, newline
   and quote rejection, and that *every* write path (including the `force`
   commands and `pull`) is behind the name guard.
3. **Filesystem writes and deletes.** Every `writefile`, `mkdir`,
   `delete`, and the paths they're built from. Path traversal via names,
   `clear_cache`'s deletion scope (marker spoofing, symlinked theme files
   redirecting a write or delete into user-owned files).
4. **Untrusted reads feeding actions.** `read_current` -> `pull` ->
   `vim.cmd.colorscheme`; the override-stamp parser; `is_generated`. Can a
   crafted file make the plugin do something its author didn't?
5. **TOCTOU and shared state.** Multiple nvim instances racing on one
   `theme_file`; check-then-write windows; predictable temp paths in tests.
6. **CI workflow.** `.github/workflows/*`: script injection from
   PR-controlled values, `pull_request_target` misuse, unpinned
   third-party actions, token permissions.
7. **Test and packaging hygiene.** Specs escaping the `$HOME` sandbox in
   `tests/minimal_init.lua`; anything in the repo that would execute on a
   user's machine at install time beyond `plugin/ghostty-mirror.lua`.

Method: grep for the sinks (`vim.system|vim.fn.system|os.execute|io.popen|writefile|delete\(|mkdir|vim.cmd|source-file`), then trace each argument back to its source. Read `valid_name` and every caller; the interesting bugs are the paths that *skip* it.

## Report format

Order findings by severity, then by exploitability within a severity.
Severity scale:

- **Critical** — arbitrary code execution or writes/deletes outside the
  plugin-owned paths, reachable from untrusted input.
- **High** — injection into an interpreted file (Ghostty/tmux config) or
  command argument, reachable from untrusted input.
- **Medium** — same sinks, but requiring a hostile local user, a race, or
  an unusual config to reach.
- **Low** — defense-in-depth gaps; correct today but one refactor away
  from a real bug.
- **Info** — observations and hardening suggestions.

Each finding:

```
### <n>. <title>  [<severity>]
- Where: <file>:<line>
- Path: <untrusted source> -> <sink>
- Impact: <one sentence>
- Remediation: <described, not applied>
```

End the report with a one-line-per-finding summary table and the explicit
statement that nothing was modified. If the scan comes up clean at a given
severity, say so — "no Critical or High findings" is a result, not filler.
