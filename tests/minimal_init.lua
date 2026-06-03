-- Minimal init for running plenary tests in headless nvim.
-- The CI workflow clones plenary into ~/.local/share/nvim/site/pack/vendor/start/plenary.nvim.

local plugin_root = vim.fn.fnamemodify(vim.fn.resolve(vim.fn.expand("<sfile>:p:h:h")), ":p")
vim.opt.rtp:prepend(plugin_root)
vim.opt.swapfile = false

-- Locate plenary.nvim. Look in a few common locations so the tests run from
-- both CI and a developer machine without configuration.
local candidates = {
	vim.fn.expand("~/.local/share/nvim/site/pack/vendor/start/plenary.nvim"),
	vim.fn.expand("~/.local/share/nvim/lazy/plenary.nvim"),
	vim.fn.expand("~/.local/share/nvim/site/pack/core/opt/plenary.nvim"),
	vim.fn.expand("~/.local/share/nvim/site/pack/core/start/plenary.nvim"),
}
for _, path in ipairs(candidates) do
	if vim.fn.isdirectory(path) == 1 then
		vim.opt.rtp:prepend(path)
		break
	end
end

vim.cmd("runtime plugin/plenary.vim")
