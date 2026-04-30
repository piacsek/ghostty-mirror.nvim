-- Auto-setup with defaults so a bare `vim.pack.add({ "...ghostty-mirror.nvim" })`
-- (or equivalent) is all you need. Call `require("ghostty-mirror").setup(opts)`
-- explicitly to override defaults; calling setup again is safe and idempotent.
if vim.g.loaded_ghostty_mirror then return end
vim.g.loaded_ghostty_mirror = true

require("ghostty-mirror").setup()
