# 🤖 NullClaw - The Smallest AI Assistant

<div align="center">

**Zig-powered** • **Privacy-focused** • **Extensible** • **Cross-platform**

The smallest, fastest AI assistant that runs anywhere. Built with Zig for maximum performance and minimal resource usage.

[![Build Status](https://img.shields.io/badge/zig-0.13.0-blue)](https://ziglang.org/)
[![License](https://img.shields.io/badge/license-MIT-green)](LICENSE)

</div>

## 🎯 What is NullClaw?

NullClaw is a **lightweight AI assistant** that helps you with software development, system administration, and everyday tasks through natural language conversation. Unlike heavy AI platforms, NullClaw:

- **Runs locally** - Your data stays on your machine
- **Extremely fast** - Built with Zig for maximum performance
- **Resource efficient** - Minimal CPU and memory usage
- **Extensible** - Easy to add custom tools and skills
- **Privacy-focused** - No telemetry, no data collection
- **Multi-platform** - Works on Linux, macOS, Windows, and more

## ✨ What Can It Do?

NullClaw can help you with:

- **💻 Software Development**
  - Write, debug, and review code
  - Run builds, tests, and Git operations
  - Manage projects (Cargo, Zig, npm, etc.)

- **🔧 System Administration**
  - Execute shell commands safely
  - Manage files and directories
  - Monitor system resources
  - Schedule automated tasks

- **📝 Documentation & Writing**
  - Generate documentation
  - Write and edit text files
  - Create reports and summaries

- **🧠 Memory & Learning**
  - Remember information across sessions
  - Search and retrieve past conversations
  - Build a personal knowledge base

- **🌐 Integration & Automation**
  - Connect to messaging platforms (Telegram, Discord, etc.)
  - Automate repetitive tasks
  - Build custom workflows

## 🚀 Quick Start

### 1. Installation

#### **From Source** (Recommended)
```bash
# Clone the repository
git clone https://github.com/yourusername/nullclaw.git
cd nullclaw

# Build
./build.sh

# Or build optimized release
./build.sh --release
```

#### **Using Zig Build System**
```bash
zig build
```

The binary will be created at `./zig-out/bin/nullclaw`.

### 2. Initial Setup

Run the interactive setup wizard:

```bash
./zig-out/bin/nullclaw onboard --interactive
```

Or use quick setup with defaults:

```bash
./zig-out/bin/nullclaw onboard
```

This will:
- Create your workspace directory (`~/.nullclaw/`)
- Generate configuration file with sensible defaults
- Set up memory backend for storing conversations
- Configure your AI provider (supports OpenAI, Anthropic, local models, etc.)

### 3. Start Chatting

```bash
./zig-out/bin/nullclaw agent
```

Try these commands:
```
> Hello! What can you help me with?
> Write a simple Hello World program in Python
> Check the status of my Git repository
> Help me debug this error: [paste error]
```

## 📖 Common Use Cases

### **Development Assistant**
```bash
nullclaw agent
```
```
> Create a new Rust project with Cargo
> Add dependencies: serde and tokio
> Write a simple HTTP server example
> Run the tests
```

### **System Administration**
```bash
nullclaw agent
```
```
> Check disk usage and show me the largest directories
> Find files larger than 100MB in /home
> Monitor CPU usage for the next 30 seconds
> Clean up log files older than 30 days
```

### **Automation**
```bash
# Schedule a task
nullclaw cron add "0 9 * * *" "Run system updates and send me a summary"

# Run a one-off task
nullclaw agent -m "Backup /home/user/documents to /backup"
```

## 🔧 Configuration

NullClaw uses a simple JSON configuration file at `~/.nullclaw/config.json`.

### Basic Configuration
```json
{
  "models": {
    "providers": {
      "openai": {
        "api_key": "your-openai-api-key"
      }
    }
  },
  "agents": {
    "defaults": {
      "model": {
        "primary": "openai/gpt-4"
      }
    }
  },
  "memory": {
    "backend": "sqlite",
    "auto_save": true
  },
  "autonomy": {
    "level": "supervised",
    "workspace_only": true
  }
}
```

### Available Providers
- **OpenAI** - GPT-4, GPT-3.5
- **Anthropic** - Claude 3.5 Sonnet, Haiku
- **Local models** - Ollama, LM Studio
- **OpenRouter** - Access to many models
- **Custom** - Bring your own API

## 🌟 Features

### **Multi-Channel Support**
Connect NullClaw to your favorite platforms:
- **CLI** - Interactive terminal interface
- **Telegram** - Chat with your bot
- **Discord** - Server integration
- **Slack** - Workspace assistant
- **Web** - HTTP/WebSocket gateway

### **Memory System**
NullClaw remembers your conversations:
- **Semantic search** - Find relevant past discussions
- **Auto-save** - Never lose important information
- **Multiple backends** - SQLite, PostgreSQL, Redis, Markdown files
- **Citations** - See source of retrieved information

### **Extensible Tools**
Built-in tools for common tasks:
- 📁 File operations (read, write, edit)
- 🔧 Shell command execution
- 📦 Package management (Cargo, Zig, npm)
- 🔄 Git operations
- 🖼️ Image processing
- ⏰ Task scheduling
- 🧠 Memory management

### **Security & Privacy**
- **Sandboxed execution** - Commands run in controlled environment
- **Workspace restrictions** - Limit file system access
- **Audit logging** - Track all operations
- **No telemetry** - Your data stays private
- **Local-first** - Works without internet (with local models)

## 📚 Documentation

- [**Getting Started Guide**](docs/GETTING_STARTED.md) - Detailed first-time setup
- [**User Guide**](docs/USER_GUIDE.md) - Comprehensive usage documentation
- [**Configuration Reference**](docs/CONFIGURATION.md) - All config options explained
- [**Examples**](examples/) - Sample workflows and use cases
- [**Troubleshooting**](docs/TROUBLESHOOTING.md) - Common issues and solutions

## 🤝 Contributing

We welcome contributions! See [CONTRIBUTING.md](CONTRIBUTING.md) for guidelines.

### Development
```bash
# Run tests
zig build test

# Run specific tests
zig build test -Dtest-file=tools/cargo

# Build with debug info
zig build -Doptimize=Debug
```

## 🆘 Support

- **Documentation** - Check the [docs/](docs/) directory
- **Issues** - Report bugs on GitHub Issues
- **Doctor Command** - Run `nullclaw doctor` for diagnostics
- **Logs** - Check `~/.nullclaw/logs/` for detailed logs

## 📊 System Requirements

### Minimum
- **RAM:** 512MB
- **Storage:** 100MB
- **CPU:** Any 64-bit processor

### Recommended
- **RAM:** 2GB+
- **Storage:** 500MB+
- **CPU:** Modern multi-core processor

### Supported Platforms
- ✅ Linux (all distributions)
- ✅ macOS (Intel & Apple Silicon)
- ✅ Windows (WSL recommended)
- ✅ BSD variants
- ✅ Embedded systems (with appropriate Zig target)

## 🎓 Learning Resources

### For Users
- [**Tutorial: Your First Conversation**](docs/tutorials/first_conversation.md)
- [**Example Workflows**](docs/workflows/) - Common tasks step-by-step
- [**Tips & Tricks**](docs/tips.md) - Power user techniques

### For Developers
- [**Tool Development Guide**](docs/TOOL_DEVELOPMENT_GUIDE.md) - Create custom tools
- [**Architecture Overview**](docs/ARCHITECTURE.md) - System design
- [**API Reference**](docs/API.md) - Programmatic access

## 🗺️ Roadmap

- [ ] Web UI for configuration and chat
- [ ] Mobile apps (iOS, Android)
- [ ] Voice interaction
- [ ] More local model support
- [ ] Plugin marketplace
- [ ] Multi-agent collaboration

## 📄 License

MIT License - see [LICENSE](LICENSE) for details.

## 🙏 Acknowledgments

Built with:
- [Zig](https://ziglang.org/) - Systems programming language
- [OpenAI/Anthropic APIs](https://openai.com/) - AI capabilities
- Various open-source libraries

## 🌟 Star History

If you find NullClaw useful, please consider giving it a star!

---

<div align="center">

**Made with ❤️ in Zig**

[Website](https://nullclaw.dev) • [Documentation](docs/) • [Community](https://discord.gg/nullclaw)

</div>