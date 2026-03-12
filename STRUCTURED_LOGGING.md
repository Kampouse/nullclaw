# Structured Logging with Grafana/Loki

This document explains how to use nullclaw's structured logging with Grafana and Loki for observability and monitoring.

## Overview

Nullclaw outputs structured JSON logs to stderr in the following format:

```json
{
  "timestamp": "2025-03-12T10:30:45.123Z",
  "level": "DEBUG",
  "scope": "agent",
  "message": "turn_start",
  "fields": {}
}
```

## Log Levels

- **DEBUG**: Detailed debugging information
- **INFO**: Informational messages
- **WARN**: Warning messages
- **ERROR**: Error messages

## Scopes (Modules)

Current logging scopes:
- `process_util`: Process execution and tool calls
- `agent`: Agent turn execution and tool coordination
- More scopes will be added as structured logging is extended

## Setting Up Loki

### 1. Install Loki

```bash
# Download Loki
wget https://github.com/grafana/loki/releases/download/v2.9.2/loki-linux-amd64.zip
unzip loki-linux-amd64.zip

# Create config
cat > loki-config.yaml <<EOF
server:
  http_listen_port: 3100

positions:
  filename: /tmp/positions.yaml

clients:
  - url: http://localhost:3100/loki/api/v1/push

scrape_configs:
  - job_name: nullclaw
    static_configs:
      - targets:
          - localhost
        labels:
          job: nullclow
          __path__: /var/log/nullclaw/*.log
EOF

# Start Loki
./loki-linux-amd64 -config.file=loki-config.yaml
```

### 2. Configure Promtail to Collect Logs

```yaml
# promtail-config.yaml
server:
  http_listen_port: 9080

positions:
  filename: /tmp/positions.yaml

clients:
  - url: http://localhost:3100/loki/api/v1/push

scrape_configs:
  - job_name: nullclaw
    static_configs:
      - targets:
          - localhost
        labels:
          job: nullclaw
          __path__: /path/to/nullclow/stderr.log
```

### 3. Install Grafana

```bash
# Download Grafana
wget https://dl.grafana.com/oss/release/grafana-10.0.3.linux-amd64.tar.gz
tar -zxvf grafana-10.0.3.linux-amd64.tar.gz

# Start Grafana
cd grafana-10.0.3
./bin/grafana server web
```

Access Grafana at `http://localhost:3000` (default credentials: admin/admin)

### 4. Add Loki as Data Source in Grafana

1. Go to Configuration → Data Sources
2. Add new data source → Loki
3. URL: `http://localhost:3100`
4. Save & Test

## Grafana Queries

### Basic Queries

```
# All logs
{job="nullclaw"}

# Filter by scope
{scope="agent"}

# Filter by level
{level="ERROR"}

# Filter by message
{message="tool_execute_start"}
```

### Advanced Queries with LogQL

```
# Parse JSON and filter by field
{scope="agent"} | json | line_format "{{.fields.tool}}"

# Count errors per scope
sum(count_over_time({level="ERROR"} | json [5m]))

# Show tool execution duration
{scope="process_util"} | json | range > 1s
```

### Example Dashboard Queries

**Agent Turn Execution:**
```logql
{scope="agent"} | json | message != "tool_iteration"
```

**Tool Execution Tracking:**
```logql
{message="tool_execute_start"} | json | line_format "{{.fields.tool}}"
```

**Error Analysis:**
```logql
{level="ERROR"} | json | line_format "{{.scope}}: {{.message}}"
```

**Process Execution Flow:**
```logql
{scope="process_util"} | json
```

## Example Logs

### Agent Turn Execution
```json
{"timestamp":"2025-03-12T10:30:45.123Z","level":"DEBUG","scope":"agent","message":"turn_start"}
{"timestamp":"2025-03-12T10:30:45.234Z","level":"DEBUG","scope":"agent","message":"llm_call_start"}
{"timestamp":"2025-03-12T10:30:46.456Z","level":"DEBUG","scope":"agent","message":"llm_success"}
{"timestamp":"2025-03-12T10:30:46.500Z","level":"DEBUG","scope":"agent","message":"tool_execute_start","fields":{"tool":"zig"}}
```

### Process Execution
```json
{"timestamp":"2025-03-12T10:30:47.000Z","level":"DEBUG","scope":"process_util","message":"process_run_start"}
{"timestamp":"2025-03-12T10:30:47.100Z","level":"DEBUG","scope":"process_util","message":"spawning_process"}
{"timestamp":"2025-03-12T10:30:47.500Z","level":"DEBUG","scope":"process_util","message":"process_completed"}
```

## Extending Structured Logging

To add structured logging to other modules:

1. Import the module:
```zig
const slog = @import("structured_log.zig");
```

2. Replace TRACE logs:
```zig
// Before
std.debug.print("[TRACE] my_function: doing something\n", .{});

// After
slog.logStructured("DEBUG", "my_scope", "doing_something", .{});
```

3. With fields:
```zig
slog.logStructured("INFO", "my_scope", "user_action", .{
    .user_id = "123",
    .action = "login"
});
```

## Best Practices

1. **Use descriptive message names**: `turn_start` instead of `start`
2. **Include relevant fields**: Add context with structured fields
3. **Use appropriate log levels**: ERROR for failures, DEBUG for tracing
4. **Keep scopes consistent**: Use module/component names as scopes
5. **Add timestamps**: Real timestamps coming soon (TODO in getTimestamp())

## Troubleshooting

### Logs not appearing in Grafana
- Check Loki is running: `curl http://localhost:3100/ready`
- Verify Promtail is collecting logs
- Check data source configuration in Grafana

### JSON parsing errors
- Ensure log output is valid JSON
- Check for escaped quotes or special characters
- Use LogQL parser: `| json` to debug

### Missing fields
- Verify field names don't use reserved keywords (e.g., `error`)
- Use single-field format for complex structures
- Check field types are compatible with formatting

## Future Improvements

- [ ] Real timestamp generation using `std.time.timestamp()`
- [ ] Extend structured logging to all modules
- [ ] Add log level filtering via environment variable
- [ ] Support for arbitrary field structures
- [ ] Performance optimization for high-volume logging
