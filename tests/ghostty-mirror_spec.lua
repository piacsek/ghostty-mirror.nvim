local function with_tmp_dir(fn)
	local dir = vim.fn.tempname()
	vim.fn.mkdir(dir, "p")
	local ok, err = pcall(fn, dir)
	vim.fn.delete(dir, "rf")
	if not ok then error(err) end
end

---Reload the module fresh so each test gets a clean copy with default config.
local function fresh_require()
	package.loaded["ghostty-mirror"] = nil
	return require("ghostty-mirror")
end

---Stub vim.system to capture invocations and return immediately.
local function stub_system()
	local calls = {}
	local original = vim.system
	vim.system = function(cmd, opts) ---@diagnostic disable-line: duplicate-set-field
		table.insert(calls, { cmd = cmd, opts = opts })
		return { wait = function() return { code = 0 } end }
	end
	return calls, function() vim.system = original end
end

describe("ghostty-mirror", function()
	describe("resolve", function()
		it("returns the colorscheme name when a matching theme file exists", function()
			with_tmp_dir(function(themes_dir)
				vim.fn.writefile({ "background = #000000" }, themes_dir .. "/foo")
				local mirror = fresh_require()
				mirror.setup({ themes_dir = themes_dir })
				assert.equals("foo", mirror.resolve("foo"))
			end)
		end)

		it("returns nil when no matching theme file exists", function()
			with_tmp_dir(function(themes_dir)
				local mirror = fresh_require()
				mirror.setup({ themes_dir = themes_dir })
				assert.is_nil(mirror.resolve("nonexistent"))
			end)
		end)

		it("prefers <name>-light when background is light and the variant exists", function()
			with_tmp_dir(function(themes_dir)
				vim.fn.writefile({ "" }, themes_dir .. "/foo")
				vim.fn.writefile({ "" }, themes_dir .. "/foo-light")
				local mirror = fresh_require()
				mirror.setup({ themes_dir = themes_dir })
				vim.o.background = "light"
				assert.equals("foo-light", mirror.resolve("foo"))
			end)
		end)

		it("uses the base name when background is light but no -light variant exists", function()
			with_tmp_dir(function(themes_dir)
				vim.fn.writefile({ "" }, themes_dir .. "/foo")
				local mirror = fresh_require()
				mirror.setup({ themes_dir = themes_dir })
				vim.o.background = "light"
				assert.equals("foo", mirror.resolve("foo"))
			end)
		end)

		it("uses the base name when background is dark even if -light exists", function()
			with_tmp_dir(function(themes_dir)
				vim.fn.writefile({ "" }, themes_dir .. "/foo")
				vim.fn.writefile({ "" }, themes_dir .. "/foo-light")
				local mirror = fresh_require()
				mirror.setup({ themes_dir = themes_dir })
				vim.o.background = "dark"
				assert.equals("foo", mirror.resolve("foo"))
			end)
		end)

		it("honors a custom light_variant_suffix", function()
			with_tmp_dir(function(themes_dir)
				vim.fn.writefile({ "" }, themes_dir .. "/foo")
				vim.fn.writefile({ "" }, themes_dir .. "/foo_day")
				local mirror = fresh_require()
				mirror.setup({ themes_dir = themes_dir, light_variant_suffix = "_day" })
				vim.o.background = "light"
				assert.equals("foo_day", mirror.resolve("foo"))
			end)
		end)
	end)

	describe("push", function()
		it("writes 'theme = <name>' to theme_file and invokes the reload command", function()
			with_tmp_dir(function(dir)
				local themes_dir = dir .. "/themes"
				local theme_file = dir .. "/theme-current"
				vim.fn.mkdir(themes_dir, "p")
				vim.fn.writefile({ "" }, themes_dir .. "/foo")

				local calls, restore = stub_system()
				local mirror = fresh_require()
				mirror.setup({
					themes_dir = themes_dir,
					theme_file = theme_file,
					reload_command = { "echo", "reload" },
				})
				mirror.push("foo")
				restore()

				assert.same({ "theme = foo" }, vim.fn.readfile(theme_file))
				assert.equals(1, #calls)
				assert.same({ "echo", "reload" }, calls[1].cmd)
			end)
		end)

		it("is a no-op when no theme file matches", function()
			with_tmp_dir(function(dir)
				local themes_dir = dir .. "/themes"
				local theme_file = dir .. "/theme-current"
				vim.fn.mkdir(themes_dir, "p")

				local calls, restore = stub_system()
				local mirror = fresh_require()
				mirror.setup({ themes_dir = themes_dir, theme_file = theme_file })
				mirror.push("nonexistent")
				restore()

				assert.equals(0, vim.fn.filereadable(theme_file))
				assert.equals(0, #calls)
			end)
		end)
	end)

	describe("read_current", function()
		it("parses 'theme = <name>' from theme_file", function()
			with_tmp_dir(function(dir)
				local theme_file = dir .. "/theme-current"
				vim.fn.writefile({ "theme = bar" }, theme_file)
				local mirror = fresh_require()
				mirror.setup({ theme_file = theme_file })
				assert.equals("bar", mirror.read_current())
			end)
		end)

		it("returns nil when the file is missing", function()
			with_tmp_dir(function(dir)
				local mirror = fresh_require()
				mirror.setup({ theme_file = dir .. "/missing" })
				assert.is_nil(mirror.read_current())
			end)
		end)

		it("returns nil when the file's content is malformed", function()
			with_tmp_dir(function(dir)
				local theme_file = dir .. "/theme-current"
				vim.fn.writefile({ "garbage" }, theme_file)
				local mirror = fresh_require()
				mirror.setup({ theme_file = theme_file })
				assert.is_nil(mirror.read_current())
			end)
		end)

		it("tolerates extra whitespace around '='", function()
			with_tmp_dir(function(dir)
				local theme_file = dir .. "/theme-current"
				vim.fn.writefile({ "theme   =   spaced" }, theme_file)
				local mirror = fresh_require()
				mirror.setup({ theme_file = theme_file })
				assert.equals("spaced", mirror.read_current())
			end)
		end)
	end)

	describe("setup", function()
		it("registers the ColorScheme autocmd in the ghostty-mirror augroup", function()
			local mirror = fresh_require()
			mirror.setup()
			local autocmds = vim.api.nvim_get_autocmds({
				event = "ColorScheme",
				group = "ghostty-mirror",
			})
			assert.is_true(#autocmds > 0)
		end)

		it("creates the user command by default", function()
			local mirror = fresh_require()
			mirror.setup()
			assert.is_not_nil(vim.api.nvim_get_commands({})["ThemeFromGhostty"])
		end)

		it("skips the user command when user_command is false", function()
			pcall(vim.api.nvim_del_user_command, "ThemeFromGhostty")
			local mirror = fresh_require()
			mirror.setup({ user_command = false })
			assert.is_nil(vim.api.nvim_get_commands({})["ThemeFromGhostty"])
		end)

		it("registers the keymap by default", function()
			local mirror = fresh_require()
			mirror.setup()
			local maps = vim.api.nvim_get_keymap("n")
			local found = false
			for _, m in ipairs(maps) do
				if m.lhs == "<M-t>" then found = true; break end
			end
			assert.is_true(found)
		end)

		it("skips the keymap when keymap is false", function()
			pcall(vim.keymap.del, "n", "<M-t>")
			local mirror = fresh_require()
			mirror.setup({ keymap = false })
			local maps = vim.api.nvim_get_keymap("n")
			for _, m in ipairs(maps) do
				assert.are_not.equals("<M-t>", m.lhs)
			end
		end)
	end)

	describe("integration: ColorScheme autocmd", function()
		it("writes the theme file when :colorscheme fires for a known theme", function()
			with_tmp_dir(function(dir)
				local themes_dir = dir .. "/themes"
				local theme_file = dir .. "/theme-current"
				vim.fn.mkdir(themes_dir, "p")
				-- Use a real bundled colorscheme so :colorscheme actually loads.
				vim.fn.writefile({ "" }, themes_dir .. "/elflord")

				local _, restore = stub_system()
				local mirror = fresh_require()
				mirror.setup({
					themes_dir = themes_dir,
					theme_file = theme_file,
					reload_command = { "echo" },
				})
				vim.cmd.colorscheme("elflord")
				restore()

				assert.same({ "theme = elflord" }, vim.fn.readfile(theme_file))
			end)
		end)
	end)
end)
