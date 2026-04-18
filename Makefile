# NullClaw Makefile
# Usage:
#   make          - build debug
#   make release  - build release
#   make start    - start nullclaw in background (detached, no hang)
#   make stop     - stop all nullclaw processes
#   make restart  - rebuild + restart in background
#   make status   - quick status check
#   make logs     - tail logs (Ctrl+C to stop)
#   make agent    - start agent mode in background
#   make clean    - clean zig build artifacts

ZIG    := ~/.local/zig/zig
BIN    := ./zig-out/bin/nullclaw
PIDFILE := .nullclaw.pid
LOGFILE := ~/nullclaw.log

.PHONY: all release start stop restart status logs agent clean

all: build

# ── Build ──────────────────────────────────────────────

build:
	$(ZIG) build

release:
	$(ZIG) build -Doptimize=ReleaseSmall

# ── Run in background (detached) ──────────────────────
# These targets use nohup + disown so the calling process
# (e.g. Hermes) never hangs waiting for nullclaw.

start:
	@BIN='$(BIN)'; LOGFILE=$(LOGFILE); PIDFILE='$(PIDFILE)'; \
	if pgrep -f "$$BIN" > /dev/null 2>&1; then \
		echo "Stopping existing instance..."; \
		pkill -f "$$BIN" 2>/dev/null; sleep 2; pkill -9 -f "$$BIN" 2>/dev/null || true; \
	fi; \
	echo "Starting nullclaw in background..."; \
	nohup $$BIN gateway >> $$LOGFILE 2>&1 & \
	echo $$! > $$PIDFILE; \
	sleep 1; \
	if pgrep -f "$$BIN" > /dev/null 2>&1; then \
		echo "Started (PID $$(cat $$PIDFILE))"; \
	else \
		echo "Failed to start — check $$LOGFILE"; \
		rm -f $$PIDFILE; \
	fi

agent:
	@BIN='$(BIN)'; LOGFILE=$(LOGFILE); PIDFILE='$(PIDFILE)'; \
	if pgrep -f "$$BIN" > /dev/null 2>&1; then \
		echo "Stopping existing instance..."; \
		pkill -f "$$BIN" 2>/dev/null; sleep 2; pkill -9 -f "$$BIN" 2>/dev/null || true; \
	fi; \
	echo "Starting nullclaw agent in background..."; \
	nohup $$BIN agent >> $$LOGFILE 2>&1 & \
	echo $$! > $$PIDFILE; \
	sleep 1; \
	if pgrep -f "$$BIN" > /dev/null 2>&1; then \
		echo "Started (PID $$(cat $$PIDFILE))"; \
	else \
		echo "Failed to start — check $$LOGFILE"; \
		rm -f $$PIDFILE; \
	fi

# ── Stop ──────────────────────────────────────────────

stop:
	@echo "Stopping nullclaw..."
	@pkill -f '$(BIN)' 2>/dev/null; sleep 2; pkill -9 -f '$(BIN)' 2>/dev/null || true
	@rm -f $(PIDFILE)
	@echo "Stopped."

# ── Restart ───────────────────────────────────────────

restart: stop build start

restart-release: stop release start

# ── Status / Logs ─────────────────────────────────────

status:
	@if pgrep -f '$(BIN)' > /dev/null 2>&1; then \
		echo "Running: PID $$(pgrep -f '$(BIN)')"; \
	else \
		echo "Not running."; \
	fi

logs:
	@tail -f $(LOGFILE)

# ── Clean ─────────────────────────────────────────────

clean:
	rm -f $(PIDFILE)
	$(ZIG) build clean
