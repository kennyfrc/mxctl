PREFIX ?= $(HOME)/.local
SOURCES = $(wildcard *.swift)

# Signs with a fixed designated requirement instead of the default hash of this exact build,
# so the Input Monitoring grant can survive rebuilds.
mxctl: $(SOURCES)
	swiftc -O -o $@ $(SOURCES)
	codesign --force --sign - --identifier local.mxctl --requirements='=designated => identifier "local.mxctl"' $@

# Also restarts the LaunchAgent, if installed, so it runs the new build.
install: mxctl
	install -m 755 mxctl $(PREFIX)/bin/mxctl
	launchctl kickstart -k gui/$$(id -u)/local.mxctl 2>/dev/null || true

clean:
	rm -f mxctl

.PHONY: install clean
