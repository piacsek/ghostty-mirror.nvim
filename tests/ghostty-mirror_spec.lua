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

		it("returns nil when no matching theme file exists and generation is off", function()
			with_tmp_dir(function(themes_dir)
				local mirror = fresh_require()
				mirror.setup({ themes_dir = themes_dir, generate = false })
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

		it("is a no-op when no theme file matches and generation is off", function()
			with_tmp_dir(function(dir)
				local themes_dir = dir .. "/themes"
				local theme_file = dir .. "/theme-current"
				vim.fn.mkdir(themes_dir, "p")

				local calls, restore = stub_system()
				local mirror = fresh_require()
				mirror.setup({ themes_dir = themes_dir, theme_file = theme_file, generate = false })
				mirror.push("nonexistent")
				restore()

				assert.equals(0, vim.fn.filereadable(theme_file))
				assert.equals(0, #calls)
			end)
		end)
	end)

	describe("generate", function()
		---Set a full terminal palette plus Normal/Cursor/Visual highlights so
		---generation has everything it needs, and return a cleanup function.
		local function with_palette(fn)
			local saved = {}
			for i = 0, 15 do
				saved[i] = vim.g["terminal_color_" .. i]
				vim.g["terminal_color_" .. i] = string.format("#%02x0000", i)
			end
			vim.o.background = "dark"
			vim.api.nvim_set_hl(0, "Normal", { fg = 0xcdd6f4, bg = 0x1e1e2e })
			vim.api.nvim_set_hl(0, "Cursor", { bg = 0xf5e0dc })
			vim.api.nvim_set_hl(0, "Visual", { bg = 0x45475a })
			local ok, err = pcall(fn)
			for i = 0, 15 do
				vim.g["terminal_color_" .. i] = saved[i]
			end
			if not ok then error(err) end
		end

		it("builds background, foreground and a 16-color palette from live highlights", function()
			with_palette(function()
				local mirror = fresh_require()
				mirror.setup({ generate = true })
				local lines = mirror.generate("mytheme")
				assert.is_not_nil(lines)
				local joined = table.concat(lines, "\n")
				assert.is_truthy(joined:find("background = #1e1e2e", 1, true))
				assert.is_truthy(joined:find("foreground = #cdd6f4", 1, true))
				assert.is_truthy(joined:find("cursor%-color = #f5e0dc"))
				assert.is_truthy(joined:find("selection%-background = #45475a"))
				assert.is_truthy(joined:find("palette = 0=#000000", 1, true))
				assert.is_truthy(joined:find("palette = 15=#0f0000", 1, true))
			end)
		end)

		it("returns nil when the terminal palette is incomplete", function()
			with_palette(function()
				vim.g.terminal_color_7 = nil
				local mirror = fresh_require()
				mirror.setup({ generate = true })
				assert.is_nil(mirror.generate("mytheme"))
			end)
		end)

		it("resolve generates and caches a theme file when none exists", function()
			with_palette(function()
				with_tmp_dir(function(themes_dir)
					local mirror = fresh_require()
					mirror.setup({ themes_dir = themes_dir, generate = true })
					assert.equals("mytheme", mirror.resolve("mytheme"))
					assert.equals(1, vim.fn.filereadable(themes_dir .. "/mytheme"))
				end)
			end)
		end)

		it("creates themes_dir when it does not exist before writing", function()
			with_palette(function()
				with_tmp_dir(function(dir)
					local themes_dir = dir .. "/nested/themes"
					local mirror = fresh_require()
					mirror.setup({ themes_dir = themes_dir, generate = true })
					assert.equals("mytheme", mirror.resolve("mytheme"))
					assert.equals(1, vim.fn.filereadable(themes_dir .. "/mytheme"))
				end)
			end)
		end)

		it("prefers an existing hand-made file over generating", function()
			with_palette(function()
				with_tmp_dir(function(themes_dir)
					vim.fn.writefile({ "background = #abcdef" }, themes_dir .. "/mytheme")
					local mirror = fresh_require()
					mirror.setup({ themes_dir = themes_dir, generate = true })
					assert.equals("mytheme", mirror.resolve("mytheme"))
					-- untouched: still the hand-made one line, not a generated file
					assert.same({ "background = #abcdef" }, vim.fn.readfile(themes_dir .. "/mytheme"))
				end)
			end)
		end)

		it("caches the light variant under the suffixed name when background is light", function()
			with_palette(function()
				with_tmp_dir(function(themes_dir)
					local mirror = fresh_require()
					mirror.setup({ themes_dir = themes_dir, generate = true })
					vim.o.background = "light"
					assert.equals("mytheme-light", mirror.resolve("mytheme"))
					assert.equals(1, vim.fn.filereadable(themes_dir .. "/mytheme-light"))
					vim.o.background = "dark"
				end)
			end)
		end)
	end)

	describe("clear_cache", function()
		it("deletes generated theme files but leaves hand-made ones", function()
			with_tmp_dir(function(themes_dir)
				vim.fn.writefile(
					{ "# Generated by ghostty-mirror.nvim from nvim colorscheme: gen", "background = #000000" },
					themes_dir .. "/gen"
				)
				vim.fn.writefile({ "background = #abcdef" }, themes_dir .. "/handmade")
				local mirror = fresh_require()
				mirror.setup({ themes_dir = themes_dir })

				local cleared = mirror.clear_cache()

				assert.equals(0, vim.fn.filereadable(themes_dir .. "/gen"))
				assert.equals(1, vim.fn.filereadable(themes_dir .. "/handmade"))
				assert.same({ "gen" }, cleared)
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

		it("creates the ThemeFromGhostty command", function()
			local mirror = fresh_require()
			mirror.setup()
			assert.is_not_nil(vim.api.nvim_get_commands({})["ThemeFromGhostty"])
		end)

		it("creates the ThemeToGhostty command", function()
			local mirror = fresh_require()
			mirror.setup()
			assert.is_not_nil(vim.api.nvim_get_commands({})["ThemeToGhostty"])
		end)

		it("creates the ThemeCacheClear command", function()
			local mirror = fresh_require()
			mirror.setup()
			assert.is_not_nil(vim.api.nvim_get_commands({})["ThemeCacheClear"])
		end)

		it("does not register any keymap (left to the user)", function()
			pcall(vim.keymap.del, "n", "<M-t>")
			local mirror = fresh_require()
			mirror.setup()
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

	describe("integration: palette ownership", function()
		---Set a full terminal palette as if left behind by a previous colorscheme,
		---returning a function that restores the prior values.
		local function with_stale_palette()
			local saved = {}
			for i = 0, 15 do
				saved[i] = vim.g["terminal_color_" .. i]
				vim.g["terminal_color_" .. i] = string.format("#%02x0000", i)
			end
			return function()
				for i = 0, 15 do
					vim.g["terminal_color_" .. i] = saved[i]
				end
			end
		end

		it("skips generation when the colorscheme leaves the terminal palette unchanged", function()
			with_tmp_dir(function(dir)
				local themes_dir = dir .. "/themes"
				local theme_file = dir .. "/theme-current"
				vim.fn.mkdir(themes_dir, "p")

				local restore_palette = with_stale_palette()
				local calls, restore_sys = stub_system()
				local mirror = fresh_require()
				mirror.setup({
					themes_dir = themes_dir,
					theme_file = theme_file,
					reload_command = { "echo" },
				})
				-- `default` sets a complete Normal but never touches terminal_color_*,
				-- so the palette stays exactly as the previous scheme left it.
				vim.cmd.colorscheme("default")
				restore_sys()
				restore_palette()

				assert.equals(0, vim.fn.filereadable(theme_file))
				assert.equals(0, vim.fn.filereadable(themes_dir .. "/default"))
				assert.equals(0, #calls)
			end)
		end)

		it("still generates when the colorscheme sets its own palette", function()
			with_tmp_dir(function(dir)
				local themes_dir = dir .. "/themes"
				local theme_file = dir .. "/theme-current"
				vim.fn.mkdir(themes_dir, "p")

				local restore_palette = with_stale_palette()
				local calls, restore_sys = stub_system()
				local mirror = fresh_require()
				mirror.setup({
					themes_dir = themes_dir,
					theme_file = theme_file,
					reload_command = { "echo" },
				})
				-- `habamax` installs its own full terminal palette, replacing the
				-- stale one, so the new palette is genuinely the current scheme's.
				vim.cmd.colorscheme("habamax")
				restore_sys()
				restore_palette()

				assert.same({ "theme = habamax" }, vim.fn.readfile(theme_file))
				assert.equals(1, vim.fn.filereadable(themes_dir .. "/habamax"))
				assert.equals(1, #calls)
			end)
		end)

		it("force regenerates from the live palette even after an unowned colorscheme", function()
			with_tmp_dir(function(dir)
				local themes_dir = dir .. "/themes"
				local theme_file = dir .. "/theme-current"
				vim.fn.mkdir(themes_dir, "p")

				local restore_palette = with_stale_palette()
				local _, restore_sys = stub_system()
				local mirror = fresh_require()
				mirror.setup({
					themes_dir = themes_dir,
					theme_file = theme_file,
					reload_command = { "echo" },
				})
				-- `default` leaves the palette stale → not owned → mirror skipped it.
				vim.cmd.colorscheme("default")
				-- ThemeToGhostty forces a regenerate; force trusts the live palette.
				mirror.push("forced", { force = true })
				restore_sys()
				restore_palette()

				assert.same({ "theme = forced" }, vim.fn.readfile(theme_file))
				assert.equals(1, vim.fn.filereadable(themes_dir .. "/forced"))
			end)
		end)

		it("notifies once when the colorscheme exposes no terminal palette", function()
			with_tmp_dir(function(dir)
				local themes_dir = dir .. "/themes"
				local theme_file = dir .. "/theme-current"
				vim.fn.mkdir(themes_dir, "p")

				local restore_palette = with_stale_palette()
				local _, restore_sys = stub_system()
				local notes = {}
				local orig_notify = vim.notify
				vim.notify = function(msg) ---@diagnostic disable-line: duplicate-set-field
					table.insert(notes, msg)
				end
				local mirror = fresh_require()
				mirror.setup({
					themes_dir = themes_dir,
					theme_file = theme_file,
					reload_command = { "echo" },
				})
				-- `default` never sets a palette, so it's unowned and generation skips.
				vim.cmd.colorscheme("default")
				vim.cmd.colorscheme("default")
				vim.notify = orig_notify
				restore_sys()
				restore_palette()

				assert.equals(1, #notes)
				assert.is_truthy(notes[1]:find("default", 1, true))
			end)
		end)
	end)
end)
