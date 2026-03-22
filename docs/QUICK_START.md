# NullClaw Quick Reference

A cheat sheet for the most common NullClaw commands and tasks.

## 🚀 First-Time Setup

```bash
# Install and setup (one command)
nullclaw onboard

# Start chatting
nullclaw agent

# Check everything is working
nullclaw doctor
```

## 💬 Essential Agent Commands

### **Starting Conversations**
```bash
# Interactive chat
nullclaw agent

# Single message
nullclaw agent -m "Your message"

# With specific model
nullclaw agent --model anthropic/claude-3-5-sonnet-20241022

# With custom temperature (0.0-2.0)
nullclaw agent --temperature 0.3
```

### **Useful First Prompts**
```
> Hello! What can you help me with?
> Help me write a Python script to...
> Explain this error: [paste error]
> Create a new Rust project
> Check my Git repository status
```

## 🔧 System Management

### **Status & Diagnostics**
```bash
# System overview
nullclaw status

# Health check
nullclaw doctor

# Configuration
nullclaw config show
nullclaw config edit

# Reconfigure
nullclaw onboard --channels-only
```

### **Memory Management**
```bash
# Search conversations
nullclaw memory search "rust project"

# Recent activity
nullclaw memory recent

# Statistics
nullclaw memory stats

# Cleanup
nullclaw memory cleanup
```

## ⏰ Task Scheduling

### **Cron Jobs**
```bash
# List scheduled tasks
nullclaw cron list

# Add a task
nullclaw cron add "0 9 * * *" "Run system updates"

# Remove a task
nullclaw cron remove <task-id>

# Run history
nullclaw cron runs
```

### **Common Schedules**
```bash
# Daily at 9 AM
nullclaw cron add "0 9 * * *" "Task description"

# Every Monday at 8 AM
nullclaw cron add "0 8 * * 1" "Weekly backup"

# Every 6 hours
nullclaw cron add "0 */6 * * *" "Check system status"

# At system startup
nullclaw cron add "@reboot" "Startup task"
```

## 🌐 Channel Management

### **Setup Channels**
```bash
# Interactive channel setup
nullclaw channel setup

# Configure Telegram
nullclaw channel configure telegram

# Configure Discord
nullclaw channel configure discord

# List all channels
nullclaw channel list

# Test channel
nullclaw channel test telegram
```

### **Gateway Server**
```bash
# Start gateway (HTTP/WebSocket)
nullclaw gateway

# Custom port
nullclaw gateway --port 8080

# Background with logging
nohup nullclaw gateway > gateway.log 2>&1 &
```

## 📁 File Operations

### **Through Agent**
```
> Read the file README.md
> Create a new file called hello.txt with content "Hello, World!"
> Edit config.json and change the timeout to 30
> List all files in the current directory
> Find all Python files in src/
```

### **Direct Operations**
```bash
# Workspace location
echo ~/.nullclaw/workspace/

# Configuration location
cat ~/.nullclaw/config.json

# Logs location
ls ~/.nullclaw/logs/
```

## 🔐 Security & Privacy

### **Check Security Status**
```bash
# Current security settings
nullclaw status | grep Security

# Audit log
tail -f ~/.nullclaw/logs/audit.log
```

### **Adjust Security**
```bash
# Edit configuration
nano ~/.nullclaw/config.json

# Common settings:
{
  "autonomy": {
    "workspace_only": true,        // Restrict to workspace
    "max_actions_per_hour": 20      // Limit actions
  },
  "security": {
    "sandbox": { "backend": "auto" }, // Enable sandbox
    "audit": { "enabled": true }      // Enable logging
  }
}
```

## 🎯 Common Workflows

### **Software Development**
```bash
nullclaw agent
```
```
> Create a new Rust project called "my-app"
> Add dependencies: tokio, serde
> Generate a basic HTTP server
> Run the tests
> Check for memory leaks
> Create a release build
```

### **System Administration**
```bash
nullclaw agent
```
```
> Show disk usage and find large files
> Monitor CPU usage for 30 seconds
> Find files older than 30 days and delete them
> Check system logs for errors
> Update all system packages
```

### **Git Operations**
```bash
nullclaw agent
```
```
> Initialize a new Git repository
> Create a .gitignore file for Rust projects
> Commit all changes with message "Initial commit"
> Create a new branch called "feature"
> Push to remote repository
```

### **Automation**
```bash
# Daily backup
nullclaw cron add "0 2 * * *" "Backup ~/Documents to /backup"

# Weekly cleanup
nullclaw cron add "0 3 * * 0" "Clean up temp files"

# Hourly health check
nullclaw cron add "0 * * * *" "Check system health and alert if issues"
```

## 🧠 Memory Operations

### **Search & Retrieve**
```bash
# Search by keyword
nullclaw memory search "project setup"

# Recent conversations
nullclaw memory recent

# Memory statistics
nullclaw memory stats

# View memory sources
nullclaw memory sources
```

### **Memory Management**
```bash
# Cleanup old memories
nullclaw memory cleanup

# Export memory
nullclaw memory export backup.json

# Import memory
nullclaw memory import backup.json

# Rebuild search index
nullclaw memory rebuild
```

## 🛠️ Development Tools

### **Build & Test**
```bash
# Build debug version
zig build

# Build release version
zig build -Doptimize=ReleaseSmall

# Run tests
zig build test

# Test specific tool
zig build test -Dtest-file=tools/cargo

# Build with custom options
zig build -Denable-memory-redis=true
```

### **Service Management**
```bash
# Install as system service
nullclaw service install

# Start service
nullclaw service start

# Check status
nullclaw service status

# Stop service
nullclaw service stop

# Restart service
nullclaw service restart

# Uninstall service
nullclaw service uninstall
```

## 🐛 Troubleshooting

### **Quick Diagnostics**
```bash
# Full health check
nullclaw doctor

# Check logs
tail -f ~/.nullclaw/logs/agent.log

# Verbose mode
nullclaw agent --verbose

# Test configuration
nullclaw config validate
```

### **Common Issues**

#### **API Key Problems**
```bash
# Reset API key
nullclaw onboard --api-key NEW_KEY --provider openai
```

#### **Memory Issues**
```bash
# Check memory usage
nullclaw memory stats

# Cleanup
nullclaw memory cleanup
```

#### **Permission Errors**
```bash
# Check workspace permissions
ls -la ~/.nullclaw/workspace/

# Fix permissions
chmod -R 755 ~/.nullclaw/workspace/
```

#### **Agent Not Responding**
```bash
# Check if running
ps aux | grep nullclaw

# Restart
killall nullclaw
nullclaw agent
```

## 📊 Monitoring

### **Resource Usage**
```bash
# Check agent resources
nullclaw status

# System resources (through agent)
nullclaw agent -m "Show CPU, memory, and disk usage"

# Monitor specific process
nullclaw agent -m "Monitor process nullclaw and alert if > 80% CPU"
```

### **Logging**
```bash
# Agent logs
tail -f ~/.nullclaw/logs/agent.log

# Error logs
tail -f ~/.nullclaw/logs/errors.log

# Audit log
tail -f ~/.nullclaw/logs/audit.log

# All logs
ls ~/.nullclaw/logs/
```

## 🎓 Tips & Tricks

### **Productivity**
1. **Use specific prompts** - More details = better results
2. **Break complex tasks** - Split into smaller steps
3. **Use memory** - Let NullClaw remember important info
4. **Automate repetitive tasks** - Use cron scheduling
5. **Customize models** - Use different models for different tasks

### **Performance**
1. **Local models** - Faster, no API costs (Ollama, LM Studio)
2. **Cache responses** - Enable response caching in config
3. **Optimize memory** - Regular cleanup and indexing
4. **Adjust temperature** - Lower = faster, more focused

### **Security**
1. **Workspace only** - Restrict file access for safety
2. **Enable audit** - Track all operations
3. **Use local models** - Keep data private
4. **Review logs** - Regular security audits

## 🔗 Useful Links

- **Full Documentation**: [docs/](.)
- **Getting Started**: [GETTING_STARTED.md](GETTING_STARTED.md)
- **User Guide**: [USER_GUIDE.md](USER_GUIDE.md)
- **Configuration**: [CONFIGURATION.md](CONFIGURATION.md)
- **Troubleshooting**: [TROUBLESHOOTING.md](TROUBLESHOOTING.md)

## 💡 Keyboard Shortcuts

### **In Agent Mode**
- `Ctrl+D` - Exit agent
- `Ctrl+C` - Cancel current operation
- `exit` or `quit` - Exit agent

### **In Shell Mode**
- `Ctrl+C` - Interrupt command
- `Ctrl+D` - End input

---

**Remember**: `nullclaw --help` on any command shows detailed options!

**Need help?** Run `nullclaw doctor` for diagnostics.