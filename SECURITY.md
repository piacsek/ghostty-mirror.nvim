# Security policy

## Supported versions

Only the latest release (and `main`) receive fixes.

## Reporting a vulnerability

Report privately via [GitHub security advisories](https://github.com/piacsek/ghostty-mirror.nvim/security/advisories/new)
or email felipe@piacsek.me. Please don't open a public issue for security
problems. You'll get a response within a week.

## Scope

The plugin runs entirely locally with no network access. Its security-relevant
surface is the files it writes: the Ghostty include file (`theme_file`), the
tmux pointer, and generated theme files under `themes_dir`. Anything that could
make it write outside those paths, follow attacker-controlled paths, or modify
the user's main Ghostty config or hand-made theme files is in scope.
