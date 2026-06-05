# Contributing

Thanks for your interest in improving ghostty-mirror.nvim. Issues and pull
requests are welcome.

## Before you start

For anything beyond a small fix, open an issue first so we can agree on the
approach before you invest time in it.

## Development setup

Requires Neovim 0.10+ and [plenary.nvim](https://github.com/nvim-lua/plenary.nvim)
on the runtimepath (`tests/minimal_init.lua` finds it in common install
locations).

```sh
make test   # headless nvim + PlenaryBustedDirectory
make lint   # stylua --check (config in stylua.toml)
```

Both must pass; CI runs them on Neovim stable and nightly for every push and PR.

## Guidelines

- **Every behavior change needs a test.** Reuse the spec helpers in
  `tests/ghostty-mirror_spec.lua` (`with_tmp_dir`, `fresh_require`,
  `stub_system`). Tests that mutate global state (`vim.o.background`,
  `vim.g.terminal_color_*`, highlights) must restore it.
- **Indentation is tabs** in Lua sources. `stylua .` fixes formatting.
- **LuaCATS annotations** on every public function and config field, matching
  the existing density.
- **Fail silently, never wrongly:** on missing or incomplete inputs, no-op
  rather than writing something Ghostty can't load.
- New config options need a default in `defaults`, a `---@field` doc, a
  `README.md` entry, and a `doc/ghostty-mirror.txt` entry — the README and
  vimdoc must not drift.
- The plugin owns only the include file (`theme_file`) and the themes it
  generates. It must never touch the user's main Ghostty config or hand-made
  theme files.
- No emojis in docs, commit messages, or release notes.

## Releases

Versioning and tags are handled by the maintainer; pull requests should not
bump versions or edit `ROADMAP.md`.
