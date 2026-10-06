.PHONY: build install uninstall test test-emacs test-linux

UNAME_S := $(shell uname -s)
UNAME_M := $(shell uname -m)

# launchd: wait (up to 5 s) until the job is gone, before bootstrap or rm.
WAIT_GONE = for i in $$(seq 50); do launchctl print gui/$$(id -u)/local.dirsized >/dev/null 2>&1 || break; sleep 0.1; done
# $HOME as XML text, safe inside a sed replacement.
XML_HOME = $$(printf %s "$$HOME" | sed -e 's/&/\&amp;/g' -e 's/</\&lt;/g' | sed 's/[\\&|]/\\&/g')

build:
	zig build -Doptimize=ReleaseSafe

install: build
ifeq ($(UNAME_S),Darwin)
	install -d ~/.local/bin ~/.config/dirsized ~/.cache/dirsized
	install -m 755 zig-out/bin/dirsized ~/.local/bin/dirsized
	install -d ~/Library/LaunchAgents
	launchctl bootout gui/$$(id -u)/local.dirsized 2>/dev/null || true
	$(WAIT_GONE)
	sed "s|@HOME@|$(XML_HOME)|g" dist/local.dirsized.plist > ~/Library/LaunchAgents/local.dirsized.plist
	@sh dist/sign-macos.sh ~/.local/bin/dirsized; case $$? in \
	0) launchctl bootstrap gui/$$(id -u) ~/Library/LaunchAgents/local.dirsized.plist && \
	   echo "Installed. Check with: dirsized status" ;; \
	3) open "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles"; \
	   open -R ~/.local/bin/dirsized; \
	   printf '%s\n' \
	   "First install: the daemon is not started yet." \
	   "Without Full Disk Access, macOS asks you about each protected folder." \
	   "  1. In System Settings > Privacy & Security > Full Disk Access, add ~/.local/bin/dirsized" \
	   "     (both windows are open now)." \
	   "  2. Run: make install" \
	   "You do this one time. Later builds keep the permission." ;; \
	*) echo "could not sign ~/.local/bin/dirsized" >&2; exit 1 ;; \
	esac
else
	install -D -m 755 zig-out/bin/dirsized ~/.local/bin/dirsized
	install -D -m 644 dist/dirsized.service ~/.config/systemd/user/dirsized.service
	systemctl --user daemon-reload
	systemctl --user enable dirsized
	systemctl --user restart dirsized
	@echo "Installed. Check with: dirsized status"
endif

uninstall:
ifeq ($(UNAME_S),Darwin)
	-launchctl bootout gui/$$(id -u)/local.dirsized 2>/dev/null || true
	-$(WAIT_GONE)
	-rm ~/Library/LaunchAgents/local.dirsized.plist
	-rm ~/.local/bin/dirsized
	-rm -rf ~/.cache/dirsized
else
	-systemctl --user disable --now dirsized 2>/dev/null || true
	-rm ~/.config/systemd/user/dirsized.service
	-systemctl --user daemon-reload 2>/dev/null || true
	-rm ~/.local/bin/dirsized
	-rm -rf "$${XDG_CACHE_HOME:-$$HOME/.cache}/dirsized"
	-[ -z "$$XDG_RUNTIME_DIR" ] || rm -rf "$$XDG_RUNTIME_DIR/dirsized"
endif
ifeq ($(PURGE),1)
	-rm -rf ~/.config/dirsized
endif

test:
	zig build test
	zig build -Doptimize=ReleaseSafe
	sh test/e2e.sh

test-emacs: build
	emacs -Q --batch -L emacs -l emacs/dirsized-tests.el -f ert-run-tests-batch-and-exit

test-linux:
ifneq (,$(filter arm64 aarch64,$(UNAME_M)))
	zig build -Doptimize=ReleaseSafe -Dtarget=aarch64-linux-musl -p zig-out/linux
else
	zig build -Doptimize=ReleaseSafe -Dtarget=x86_64-linux-musl -p zig-out/linux
endif
	sh test/linux-unit.sh
	sh test/docker.sh
