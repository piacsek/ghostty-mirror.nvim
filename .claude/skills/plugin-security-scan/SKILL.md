---
name: plugin-security-scan
description: Scan ghostty-mirror.nvim for security vulnerabilities and report them in order of importance. Strictly read-only — it reports findings in the conversation and never edits code, files issues, or commits. Use when the user asks for a security scan, audit, or review of the plugin, runs /plugin-security-scan, or wants a safety pass before a release.
---

# Plugin security scan

Static security review of this repository. The output is a report, ordered
most important first. What to do about each finding is the user's call.

## Ground rules

- **Read-only.** Do not edit any file, create issues or TODOs, commit, or
  push. Read-only shell commands (grep, git log, `gh issue list`, ls) are
  fine; nothing that writes.
- **Report everything you find, even hardening-level nits** — but ranked, so
  the user can stop reading when the severity drops below their bar.
- **Find them all in one sweep.** This skill has historically been run many
  times, each pass surfacing a bug the previous pass walked past. The recurrence
  is not bad luck — it's a method gap, addressed by "Completeness method" below.
  Aim to leave nothing for a second pass.

## Don't re-report what's already acknowledged

Before reporting, reconcile against the issue tracker and the accepted-by-design
baseline. A finding the user has already seen and filed (or consciously
accepted) is noise, not signal.

1. Run `gh issue list --label security --state all --json number,title,state,body`.
2. **Open** security issue → the finding is **acknowledged and tracked**. Do not
   list it as a new finding. If it still reproduces, mention it in one line under
   an "Already tracked" note (`#13 (torn read), #15 (hard-link write) — still
   open, not re-detailing`). If an open issue no longer reproduces, say so — a
   tracked issue that's been quietly fixed is worth flagging.
3. **Closed** security issue → its findings are presumed **fixed**. Spot-check
   that the fix is still in place (a regression check — read the cited lines),
   and only surface it if it has actually regressed. Map closed issues to their
   fix commits via `git log` when in doubt.
4. **Accepted by design** (never re-raise as actionable; these are stable
   trust-model decisions, documented in CLAUDE.md, code comments, and prior
   issue "No action planned" sections):
   - `$PATH`-resolved `pkill`/`tmux`/`pgrep` — argv lists, same-user trust model.
   - `theme_file` (and the tmux pointer) as a same-user control channel:
     `sync_on_startup`/`sync_on_focus`/`:ThemeFromGhostty` apply an installed
     colorscheme written there. `valid_name` confines the name; execution is
     limited to code already on the runtimepath. Defaults off.
   - `clear_cache`'s check-then-delete race — no `unlinkat` in luv; blast radius
     confined to the themes dirs; `vim.fs.dir` `type == "file"` excludes symlinks.
     Documented in the code comment.
   - The marker-line ownership model — a file whose first line is the generated
     marker is plugin-owned and may be cleared/regenerated. Documented.
   - A symlinked *themes_dir directory component* redirecting writes/deletes —
     `write_atomic` guards the leaf only; the dirs are assumed real
     directories (stated trust assumption).
   - A planted symlink/hard link *at a write destination* being **replaced** by
     the atomic rename (target untouched). Replacing the entry is the designed
     leaf defense, not a clobbering bug — last-writer-wins on the entry itself.
   - `write_atomic`'s unconditional unlink on the `O_EXCL` retry — a non-plugin
     file at exactly `<path>.<pid>.tmp` takes a pid collision to exist, and a
     planted directory there (which unlink can't clear) only wedges writes to
     that one destination: same-user DoS, outside the threat model. Documented
     in the code comment.
   - The check-then-write window on the hand-made bang protection
     (`force_may_write`'s `is_generated` read vs. the later rename) — same
     class as `clear_cache`'s check-then-delete: luv offers no atomic
     marker-check-and-replace, the window needs a hostile same-user racer
     inside a user-initiated force, and the blast radius is the themes dirs.
     Documented in the code comment.

   Re-raise one of these *only* if the code changed such that the reasoning no
   longer holds (e.g. a default flipped to on, or a name reaches a sink
   unguarded) — and then frame it as the regression, not the old finding.

## Ignore list (not part of the plugin)

Untracked cruft in the working tree is out of scope — do not report it:

- The literal `~` directory at the repo root (a stray from an unexpanded tilde).
- Other untracked, ungitignored scratch in the root (`Session.vim`, `scratch.nvim`).

These are local mess, not shipped code. Confirm with `git ls-files` /
`git status --short` that a path is actually tracked before treating it as part
of the plugin. (The `.claude/settings.local.json`-is-tracked observation *is*
in scope — it ships.)

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
- **User config** — `overrides` values, `reload_command`, `light_variant_suffix`,
  and the tmux paths are trusted as intent but must not be corrupted into
  something that executes or writes outside the owned paths. Config is plain
  data that any other plugin can mutate *after* `setup()`.
- **Environment** — `$PATH` resolution for `pkill`/`tmux`/`pgrep`,
  `$XDG_CONFIG_HOME`/`$HOME` expansion.
- **Highlight-derived strings** — colors read from `nvim_get_hl` and
  `g:terminal_color_*` (any plugin can set these) that get written into
  generated files.
- **Hostile local process running as the same user** — can plant files,
  symlinks, hard links, FIFOs, and directories at the plugin's predictable
  paths, and can win check-then-act races against it.

## Completeness method

The lesson from every prior scan: a single bug class kept reappearing in a
*new* sink that an earlier fix had skipped. Catch them together by working from
the defense outward, not from the file top-down.

1. **Enumerate every peer of each defended sink.** When you find a guard
   (`valid_name`, `normalize_color`/`hex`, the hardened `read_head` open,
   `write_atomic`), do not just confirm it where you found it — list *every*
   call site of that sink class and verify the guard is present at each. The
   historical misses were exactly the unguarded peer: `pull` while the writes
   were guarded; the public generators while `write_generated` was guarded;
   `light_variant_suffix` while the name was guarded; `health.lua`'s read while
   `read_head` was hardened. Build the list, then check it off.

   - Names → `valid_name`: every public function taking a name (`generate`,
     `generate_tmux`, `write_generated`, `write_tmux_generated`, `resolve`,
     `resolve_tmux`, `push`, `push_tmux`, `read_current`, `pull`), plus anything
     concatenated *onto* a validated name (`light_variant_suffix` via
     `safe_suffix`/`target_name`).
   - Colors → `hex`/`normalize_color`: every value emitted into a generated
     file — Normal/Cursor/Visual, the 16 palette slots, overrides, and every
     tmux `set -g ...` value.
   - File reads → the hardened open (`O_NONBLOCK` + fstat `type == "file"` +
     byte cap): `read_head`, `health.lua`'s config read, and any raw
     `readfile`/`io.open`/`vim.fn.readfile` anywhere.
   - File writes → `write_atomic`: every `writefile`/`fs_write` sink.

2. **Walk the filesystem-hostile-object matrix at every `fs_open`.** Each prior
   scan found one more row. Check all of them, for both the read and write opens,
   in one pass:

   | Object planted at the path | Concern | Defense to confirm |
   |---|---|---|
   | Live symlink | write/read redirected to target | writes: `O_EXCL` temp + `fs_rename` replaces the link, never follows it; reads: fstat `type == "file"` + `O_NONBLOCK` |
   | Dangling symlink | `O_CREAT` follows it and creates the target | the temp open is `O_CREAT\|O_EXCL` (never follows); rename replaces the link entry |
   | **Hard link** | write lands in the link target | rename swaps the directory entry; the target inode is never opened |
   | FIFO / special device | `open`/`read` blocks or reads unboundedly | reads: `O_NONBLOCK` + fstat `type == "file"` + read cap; writes never open the destination |
   | Directory | open/write misbehaves | fstat type check on reads; `fs_rename` over a directory fails |
   | Swapped between check and act (TOCTOU) | guard proves a different object than the one written | no path-based pre-write checks exist; the rename is the act |
   | Concurrent reader mid-write | torn / partial file observed | temp + fsync + `fs_rename`: readers see old or new, never a mix; a failed write unlinks the temp and leaves the destination alone |
   | Planted entry at the predictable temp name (`<path>.<pid>.tmp`) | `O_EXCL` create fails; write wedges | unlink-the-entry-and-retry-once in `write_atomic` (unlink doesn't follow links) |

3. **Validate config at the sink, not only at `setup()`.** `M.config` is plain
   data; any plugin can mutate it after setup. For every config value that
   reaches an interpreted-file sink (`light_variant_suffix`, `tmux.themes_dir`,
   `tmux.theme_file`, `reload_command`), confirm the character-class / quoting
   check repeats at the point of use — a setup-only check is bypassable.

4. **CI: one dependency-pin pass.** Enumerate *every* third-party thing the
   workflow runs — each `uses:` action, each tool-version input (e.g. stylua
   `version:`), and every `git fetch`/`clone` of test deps (plenary) — and
   confirm each is pinned to a commit SHA or exact release, not a floating tag
   or `latest`. Then confirm `permissions:` is scoped down and the trigger is
   `pull_request` (not `pull_request_target`). These were fixed one at a time
   across scans; do them as a single checklist.

## Scan dimensions, in priority order

1. **Command execution.** Every `vim.system`, `vim.fn.system`,
   `os.execute`, `io.popen`, `jobstart` call. For each: argv list or shell
   string? Where does each argument come from? Can untrusted input reach
   it?
2. **Injection into interpreted files.** Every line written into
   `theme_file` (Ghostty parses it) and the tmux pointer/themes
   (`source-file`, `set -g` — tmux executes these). Check quoting, newline
   and quote rejection, and that *every* write path (including the `force`
   commands and `pull`) is behind the name guard. (See Completeness method 1.)
3. **Filesystem writes and deletes.** Every `writefile`, `fs_write`, `mkdir`,
   `delete`, and the paths they're built from. Path traversal via names,
   `clear_cache`'s deletion scope, and the full hostile-object matrix at every
   open (Completeness method 2) — symlink, dangling symlink, hard link, FIFO,
   directory, TOCTOU, and write atomicity.
4. **Untrusted reads feeding actions.** `read_current` -> `pull` ->
   `vim.cmd.colorscheme`; the override-stamp parser; `is_generated`. Can a
   crafted file make the plugin do something its author didn't? Confirm every
   read uses the hardened open (Completeness method 1).
5. **Config-at-sink.** Every config value reaching an interpreted-file or path
   sink is re-validated at use, not only at `setup()` (Completeness method 3).
6. **TOCTOU and shared state.** Multiple nvim instances racing on one
   `theme_file`; check-then-write windows; torn reads; predictable temp paths in
   tests.
7. **Destructive operations on user-owned files.** Paths where the plugin
   deletes or overwrites a file it doesn't own — the force commands overwriting a
   hand-made theme, `clear_cache`'s scope. Weigh against the stated ownership
   invariant ("must not touch the user's hand-made theme files").
8. **CI workflow.** `.github/workflows/*`: the dependency-pin checklist
   (Completeness method 4), `pull_request_target` misuse, token permissions,
   script injection from PR-controlled values.
9. **Test and packaging hygiene.** Specs escaping the `$HOME`/`$XDG_CONFIG_HOME`
   sandbox in `tests/minimal_init.lua`; tracked files that ship local state
   (`.claude/settings.local.json`); anything in the repo that would execute on a
   user's machine at install time beyond `plugin/ghostty-mirror.lua`.

Method: grep for the sinks (`vim.system|vim.fn.system|os.execute|io.popen|writefile|fs_write|fs_open|delete\(|mkdir|vim.cmd|source-file|readfile`), then trace each argument back to its source. Read `valid_name`, `write_atomic`, `read_head`, and every caller; the interesting bugs are the paths that *skip* the guard (Completeness method 1).

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

End the report with:
- a one-line-per-finding summary table;
- a one-line "Already tracked" note listing any open issues that still reproduce
  (by number, not re-detailed);
- a one-line note of any closed-issue fixes you re-verified as still holding (or
  flag any that regressed);
- the explicit statement that nothing was modified.

If the scan comes up clean at a given severity, say so — "no Critical or High
findings" is a result, not filler.
