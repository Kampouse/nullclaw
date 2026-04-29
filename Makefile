# NullClaw Makefile
# Usage:
#   make          - build debug (full pipeline, incremental)
#   make release  - build release (full pipeline, incremental)
#   make start    - start nullclaw in background (detached, no hang)
#   make stop     - stop all nullclaw processes
#   make restart  - rebuild + restart in background
#   make status   - quick status check
#   make logs     - tail logs (Ctrl+C to stop)
#   make agent    - start agent mode in background
#   make clean    - clean all build artifacts

ZIG    := /opt/homebrew/bin/zig
BIN    := ./zig-out/bin/nullclaw
PIDFILE := .nullclaw.pid
LOGDIR  := $(HOME)/.nullclaw/logs
LOGFILE := $(LOGDIR)/daemon.log
LOGSTAMP := $(shell date -u +"%Y-%m-%d_%H%M%S")

.PHONY: all release build-vm vm-images vm-images-force start stop restart status logs agent clean

all: build

# ── Build ──────────────────────────────────────────────

SPY_SRC := $(shell find spy/src -name '*.ts' -o -name '*.tsx' 2>/dev/null)

build: $(BIN)

release: OPTIMIZE := -Doptimize=ReleaseSmall
release: $(BIN)

VZ_LIB    := vm/libvz_wrapper.a
VZ_SRC    := src/vm/vz_wrapper.m
VZ_OBJ    := vm/vz_wrapper.o

# ── VM images ──────────────────────────────────────

vm-images:
	@bash vm/build-images.sh

vm-images-force:
	@bash vm/build-images.sh --force

# ── VM static library ──────────────────────────────

$(VZ_LIB): $(VZ_SRC)
	clang -c -fobjc-arc -framework Virtualization -framework Foundation $(VZ_SRC) -o $(VZ_OBJ)
	ar rcs $(VZ_LIB) $(VZ_OBJ)

# ── Build with VM ──────────────────────────────────

build-vm: vm-images $(VZ_LIB) $(BIN)
	$(ZIG) build -Dvm=true $(OPTIMIZE)
	codesign --entitlements src/vm/nullclaw.entitlements.plist --force --sign - $(BIN)

$(BIN): spy/dist/index.html
	$(ZIG) build $(OPTIMIZE)

spy/dist/index.html: spy/src/generated/types.ts spy/src/generated/render-map.ts $(SPY_SRC)
	cd spy && npm run build

spy/src/generated/types.ts spy/src/generated/render-map.ts: spy/src/generated/schema.json spy/scripts/gen-types.ts
	cd spy && npx tsx scripts/gen-types.ts

spy/src/generated/schema.json: gen_schema.zig src/observability/event_tap.zig
	@mkdir -p spy/dist && echo '<!-- placeholder -->' > spy/dist/index.html
	$(ZIG) build gen-schema

# ── Run in background (detached) ──────────────────────
# These targets use nohup + disown so the calling process
# (e.g. Hermes) never hangs waiting for nullclaw.

start:
	@BIN='$(BIN)'; LOGDIR=$(LOGDIR); LOGFILE=$(LOGFILE); LOGSTAMP=$(LOGSTAMP); PIDFILE='$(PIDFILE)'; \
	if pgrep -f "$$BIN" > /dev/null 2>&1; then \
		echo "Stopping existing instance..."; \
		pkill -f "$$BIN" 2>/dev/null; sleep 2; pkill -9 -f "$$BIN" 2>/dev/null || true; \
	fi; \
	mkdir -p "$$LOGDIR"; \
	if [ -f "$$LOGFILE" ] && [ -s "$$LOGFILE" ]; then \
		mv "$$LOGFILE" "$$LOGDIR/daemon.$$LOGSTAMP.log"; \
		echo "Archived previous log to daemon.$$LOGSTAMP.log"; \
	fi; \
	echo "Starting nullclaw in background..."; \
	echo "--- nullclaw gateway started $$(date -u +%Y-%m-%dT%H:%M:%SZ) PID: " > "$$LOGFILE"; \
	nohup $$BIN gateway >> "$$LOGFILE" 2>&1 & \
	echo $$! >> "$$LOGFILE"; \
	echo $$! > $$PIDFILE; \
	sleep 1; \
	if pgrep -f "$$BIN" > /dev/null 2>&1; then \
		echo "Started (PID $$(cat $$PIDFILE)) — log: $$LOGFILE"; \
	else \
		echo "Failed to start — check $$LOGFILE"; \
		rm -f $$PIDFILE; \
	fi

agent:
	@BIN='$(BIN)'; LOGDIR=$(LOGDIR); LOGFILE=$(LOGDIR)/daemon-agent.log; LOGSTAMP=$(LOGSTAMP); PIDFILE='$(PIDFILE)'; \
	if pgrep -f "$$BIN" > /dev/null 2>&1; then \
		echo "Stopping existing instance..."; \
		pkill -f "$$BIN" 2>/dev/null; sleep 2; pkill -9 -f "$$BIN" 2>/dev/null || true; \
	fi; \
	mkdir -p "$$LOGDIR"; \
	echo "Starting nullclaw agent in background..."; \
	nohup $$BIN agent >> "$$LOGFILE" 2>&1 & \
	echo $$! > $$PIDFILE; \
	sleep 1; \
	if pgrep -f "$$BIN" > /dev/null 2>&1; then \
		echo "Started (PID $$(cat $$PIDFILE)) — log: $$LOGFILE"; \
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
	rm -rf zig-out .zig-cache spy/src/generated spy/dist
