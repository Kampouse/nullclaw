# Getting Started with NullClaw

Welcome to NullClaw! This guide will walk you through everything you need to know to get started with your new AI assistant.

## 🎯 What You'll Learn

1. How to install NullClaw
2. Initial setup and configuration
3. Your first conversation
4. Basic commands and concepts
5. Common tasks and workflows

## 📥 Installation

### Option 1: Build from Source (Recommended)

#### Prerequisites
- **Zig** compiler (0.13.0 or later)
- **Git** (for cloning the repository)

#### Step 1: Install Zig
```bash
# On macOS
brew install zig

# On Linux
# Download from https://ziglang.org/download/
# Or use your distribution's package manager

# Verify installation
zig version
```

#### Step 2: Clone and Build
```bash
# Clone the repository
git clone https://github.com/yourusername/nullclaw.git
cd nullclaw

# Build the project
./build.sh

# Or build an optimized release version
./build.sh --release
```

The binary will be created at `./zig-out/bin/nullclaw`.

#### Step 3: (Optional) Install System-Wide
```bash
# On Linux/macOS
sudo cp ./zig-out/bin/nullclaw /usr/local/bin/

# Or add to PATH
export PATH="$PATH:$PWD/zig-out/bin"
```

### Option 2: Download Pre-built Binary

Coming soon! Pre-built binaries will be available for:
- Linux (AMD64, ARM64)
- macOS (Intel, Apple Silicon)
- Windows (AMD64)

## 🚀 Initial Setup

### Quick Setup (Recommended for First-Time Users)

The quick setup uses sensible defaults and gets you running in seconds:

```bash
nullclaw onboard
```

This will:
- ✅ Create workspace at `~/.nullclaw/`
- ✅ Generate configuration file
- ✅ Set up SQLite memory backend
- ✅ Configure default AI provider
- ✅ Enable all security features

**Output:**
```
  ███╗   ██╗██╗   ██╗██╗     ██╗      ██████╗██╗      █████╗ ██╗    ██╗
  ████╗  ██║██║   ██║██║     ██║     ██╔════╝██║     ██╔══██╗██║    ██║
  ██╔██╗ ██║██║   ██║██║     ██║     ██║     ██║     ███████║██║ █╗ ██║
  ██║╚██╗██║██║   ██║██║     ██║     ██║     ██║     ██╔══██║██║███╗██║
  ██║ ╚████║╚██████╔╝███████╗███████╗╚██████╗███████╗██║  ██║╚███╔███╔╝
  ╚═╝  ╚═══╝ ╚═════╝ ╚══════╝╚══════╝ ╚═════╝╚══════╝╚═╝  ╚═╝ ╚══╝╚══╝

  The smallest AI assistant. Zig-powered.
  Quick Setup -- generating config with sensible defaults...

  [OK] Workspace:   /Users/youruser/.nullclaw/workspace
  [OK] Provider:    openrouter
  [OK] Model:       anthropic/claude-sonnet-4
  [OK] API Key:     sk-or-...
  [OK] Memory:      sqlite

  Next steps:
    1. Chat:     nullclaw agent
    2. Gateway:  nullclaw gateway
    3. Status:   nullclaw status
```

### Interactive Setup (Custom Configuration)

For more control over your setup:

```bash
nullclaw onboard --interactive
```

You'll be prompted for:
- **AI Provider** (OpenAI, Anthropic, local models, etc.)
- **API Key** (your provider's API key)
- **Model Selection** (which model to use)
- **Memory Backend** (SQLite, PostgreSQL, Redis, Markdown)
- **Security Options** (workspace restrictions, sandboxing)
- **Channel Configuration** (Telegram, Discord, etc.)

### Manual Setup

If you prefer to configure everything yourself:

```bash
# Copy example configuration
cp config.example.json ~/.nullclaw/config.json

# Edit with your settings
nano ~/.nullclaw/config.json
```

## 💬 Your First Conversation

### Start the Agent

```bash
nullclaw agent
```

### Try These Example Prompts

#### 1. **Introduction**
```
> Hello! What can you help me with?
```

#### 2. **Code Writing**
```
> Write a Python function that calculates fibonacci numbers
```

#### 3. **System Administration**
```
> Show me the disk usage of my home directory
```

#### 4. **Git Operations**
```
> Check the status of my Git repository and show recent commits
```

#### 5. **File Operations**
```
> Create a new file called hello.txt with the content "Hello, World!"
```

#### 6. **Package Management**
```
> Initialize a new Rust project with Cargo
```

### Basic Conversation Tips

- **Be specific** - More details = better responses
- **Use natural language** - Talk like you would to a human assistant
- **Ask for clarification** - "What do you mean by that?"
- **Multi-step tasks** - Break complex tasks into steps
- **Follow-up questions** - Ask for more details or alternatives

## 🔧 Essential Commands

### **Agent Commands**
```bash
# Start interactive chat
nullclaw agent

# Send a single message
nullclaw agent -m "Your message here"

# Use a different model
nullclaw agent --model anthropic/claude-3-5-sonnet-20241022

# Adjust creativity (0.0 = focused, 1.0 = creative)
nullclaw agent --temperature 0.5
```

### **System Management**
```bash
# Check system status
nullclaw status

# Run diagnostics
nullclaw doctor

# View configuration
nullclaw config show

# Reconfigure
nullclaw onboard --channels-only
```

### **Memory Management**
```bash
# Search your memory
nullclaw memory search "project setup"

# View recent memories
nullclaw memory recent

# Memory statistics
nullclaw memory stats
```

### **Scheduled Tasks**
```bash
# List scheduled tasks
nullclaw cron list

# Add a scheduled task
nullclaw cron add "0 9 * * *" "Run system updates"

# Remove a task
nullclaw cron remove <task-id>
```

## 🎓 Core Concepts

### **Agents**
An agent is an AI assistant that can:
- Understand natural language
- Execute commands safely
- Remember previous conversations
- Use tools to accomplish tasks

### **Tools**
Tools are capabilities the agent can use:
- **File tools** - Read, write, edit files
- **Shell tool** - Execute commands
- **Git tool** - Version control
- **Cargo/Zig tools** - Package management
- **Memory tools** - Store and retrieve information

### **Memory**
NullClaw remembers your conversations:
- **Auto-save** - Conversations saved automatically
- **Semantic search** - Find relevant past discussions
- **Citations** - See source of retrieved information
- **Backends** - SQLite (default), PostgreSQL, Redis, Markdown

### **Channels**
Connect NullClaw to different platforms:
- **CLI** - Terminal interface (always available)
- **Telegram** - Chat with your bot
- **Discord** - Server integration
- **Web** - HTTP/WebSocket gateway

### **Workspace**
The workspace is where NullClaw operates:
- **Location**: `~/.nullclaw/workspace/`
- **Restrictions**: Agent can only access files here (by default)
- **Safety**: Prevents accidental system-wide changes

## 🎯 Common Workflows

### **Software Development**

#### 1. **Start a New Project**
```bash
nullclaw agent
```
```
> Create a new Rust project called "my-app"
> Add dependencies: tokio and serde
> Generate a basic HTTP server example
> Run the application
```

#### 2. **Debug Code**
```
> I'm getting this error: [paste error]
> Analyze the problem and suggest fixes
> Apply the fix and test it
```

#### 3. **Code Review**
```
> Review the code in src/main.rs
> Suggest improvements for performance
> Check for security issues
```

### **System Administration**

#### 1. **System Monitoring**
```
> Show me CPU and memory usage
> What processes are using the most resources?
> Monitor disk usage and warn me if > 80% full
```

#### 2. **Maintenance Tasks**
```
> Find and clean up log files older than 30 days
> Check for system updates
> Backup my documents folder
```

### **Automation**

#### 1. **Schedule Regular Tasks**
```bash
# Daily backup at 2 AM
nullclaw cron add "0 2 * * *" "Backup ~/Documents to /backup"

# Weekly system cleanup
nullclaw cron add "0 3 * * 0" "Clean up temporary files and old logs"
```

#### 2. **Automated Workflows**
```
> Every morning at 9 AM, check my email and summarize important messages
> Monitor this API endpoint and alert me if it's down
```

## 🔒 Security & Privacy

### **Default Security Settings**
- ✅ **Workspace-only** - Agent can only access `~/.nullclaw/workspace/`
- ✅ **Sandboxed** - Commands run in controlled environment
- ✅ **Audit logging** - All operations are logged
- ✅ **No telemetry** - Your data stays private

### **Adjusting Security**

#### **Enable Full System Access** (Use with caution!)
```bash
# Edit config
nano ~/.nullclaw/config.json

# Set:
"autonomy": {
  "workspace_only": false
}
```

#### **Configure Allowed Paths**
```json
"autonomy": {
  "allowed_paths": [
    "/home/user/projects",
    "/home/user/documents"
  ]
}
```

### **Privacy Tips**
- **Use local models** - No data leaves your machine
- **Review logs** - Check `~/.nullclaw/logs/` regularly
- **Audit mode** - All operations are logged by default
- **Memory backends** - Choose local storage (SQLite, Markdown)

## 🆘 Troubleshooting

### **Common Issues**

#### **"API key not found"**
```bash
# Re-run setup
nullclaw onboard --api-key YOUR_KEY --provider openai
```

#### **"Permission denied" errors**
```bash
# Check workspace permissions
ls -la ~/.nullclaw/workspace/

# Fix permissions
chmod 755 ~/.nullclaw/workspace/
```

#### **"Out of memory"**
```bash
# Check memory usage
nullclaw memory stats

# Clean up old memories
nullclaw memory cleanup
```

#### **Agent not responding**
```bash
# Run diagnostics
nullclaw doctor

# Check logs
tail -f ~/.nullclaw/logs/agent.log
```

### **Get Help**

1. **Built-in help**
   ```bash
   nullclaw --help
   nullclaw agent --help
   ```

2. **Diagnostic tool**
   ```bash
   nullclaw doctor
   ```

3. **Verbose mode**
   ```bash
   nullclaw agent --verbose
   ```

4. **Check logs**
   ```bash
   ls ~/.nullclaw/logs/
   ```

## 📚 Next Steps

1. **Explore examples** - Check the [examples/](../examples/) directory
2. **Read user guide** - Comprehensive [USER_GUIDE.md](USER_GUIDE.md)
3. **Configure channels** - Set up Telegram, Discord, etc.
4. **Customize tools** - Learn about [tool development](TOOL_DEVELOPMENT_GUIDE.md)
5. **Join community** - Connect with other users

## 🎉 You're Ready!

You've successfully set up NullClaw and learned the basics. Here are some suggestions for what to do next:

### **Try These Projects**
- Build a personal task manager
- Automate your development workflow
- Create a system monitoring dashboard
- Set up a chat bot for your team

### **Explore Advanced Features**
- Connect to messaging platforms
- Create custom tools
- Set up automated workflows
- Experiment with different AI models

### **Stay Updated**
- Check for updates regularly
- Read the documentation
- Join the community
- Share your feedback

---

**Need help?** Check [TROUBLESHOOTING.md](TROUBLESHOOTING.md) or open an issue on GitHub.

**Enjoy using NullClaw!** 🚀