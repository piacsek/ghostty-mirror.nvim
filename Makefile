.PHONY: test

# Run the test suite headless. Plenary must be available — either installed
# system-wide via your plugin manager, or fetched into a vendor pack dir
# (the CI workflow does the latter).
test:
	nvim --headless --noplugin -u tests/minimal_init.lua \
		-c "PlenaryBustedDirectory tests { minimal_init = 'tests/minimal_init.lua' }"
