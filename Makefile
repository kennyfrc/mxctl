PREFIX ?= $(HOME)/.local

# Signs with a fixed designated requirement instead of the default hash of this exact build,
# so the Input Monitoring grant can survive rebuilds.
mxdpi: mxdpi.swift
	swiftc -O -o $@ mxdpi.swift
	codesign --force --sign - --identifier local.mxdpi --requirements='=designated => identifier "local.mxdpi"' $@

# Also restarts the LaunchAgent, if installed, so it runs the new build.
install: mxdpi
	install -m 755 mxdpi $(PREFIX)/bin/mxdpi
	launchctl kickstart -k gui/$$(id -u)/local.mxdpi 2>/dev/null || true

clean:
	rm -f mxdpi

.PHONY: install clean
