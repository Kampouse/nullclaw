# NullClaw Testing with llmock

This directory contains integration tests using [llmock](https://github.com/CopilotKit/llmock) - a deterministic mock LLM server for testing.

## What is llmock?

llmock is a mock server that simulates OpenAI, Anthropic, and Gemini APIs with deterministic responses. It enables:

- **Zero cost testing** - No API calls to real providers
- **Deterministic responses** - No flaky tests from LLM variability
- **Fast CI/CD** - No API rate limits
- **Error injection** - Test error handling paths easily
- **Tool call testing** - Full tool call/response coverage

## Setup

```bash
# Install dependencies
npm install

# Run all integration tests
./tests/llmock/runner.sh

# Run specific test file
./tests/llmock/runner.sh tests/integration/provider_test.zig
```

## Directory Structure

```
tests/
├── llmock/
│   ├── fixtures/          # JSON fixtures for mock responses
│   │   ├── openai.json    # OpenAI/Compatible provider fixtures
│   │   ├── anthropic.json # Anthropic Claude fixtures
│   │   └── gemini.json    # Google Gemini fixtures
│   ├── runner.sh          # Test runner script
│   └── README.md          # This file
└── integration/
    └── provider_test.zig  # Provider integration tests
```

## Adding Fixtures

Fixtures are JSON files that define mock responses. Example:

```json
{
  "fixtures": [
    {
      "match": { "userMessage": "hello" },
      "response": { "content": "Hello! I'm a mock assistant." }
    },
    {
      "match": { "userMessage": "test tool" },
      "response": {
        "toolCalls": [
          { "name": "shell", "arguments": "{\"command\":\"echo test\"}" }
        ]
      }
    }
  ]
}
```

### Matching Rules

- `userMessage`: Substring match on last user message
- `predicate`: Custom matching function (advanced)
- `model`: Match on model name
- `toolName`: Match when request contains tool
- `toolCallId`: Match tool result message

### Response Types

- `content`: Text response
- `toolCalls`: Tool call response
- `error`: Error response with status code

## Writing Tests

```zig
const std = @import("std");
const providers = @import("providers");
const OpenAiProvider = providers.openai.OpenAiProvider;

test "my test with mock" {
    const allocator = std.testing.allocator;
    
    // Uses OPENAI_BASE_URL from environment (set by runner.sh)
    var provider = OpenAiProvider.init(allocator, "mock-key");
    defer provider.deinit();
    
    const response = try provider.chatWithSystem(
        allocator,
        "You are helpful",
        "hello",  // matches fixture
        "gpt-4",
        0.7,
    );
    defer allocator.free(response);
    
    try std.testing.expect(response.len > 0);
}
```

## Environment Variables

The runner sets these automatically:

```bash
OPENAI_BASE_URL=http://localhost:4010/v1
ANTHROPIC_BASE_URL=http://localhost:4010/v1
GEMINI_BASE_URL=http://localhost:4010/v1beta
OPENAI_API_KEY=mock-key
ANTHROPIC_API_KEY=mock-key
GEMINI_API_KEY=mock-key
```

## Manual Usage

```bash
# Start mock server manually
npm run test:mock

# In another terminal, run tests
OPENAI_BASE_URL=http://localhost:4010/v1 \
OPENAI_API_KEY=mock-key \
zig test tests/integration/provider_test.zig
```

## CI/CD Integration

Add to your CI pipeline:

```yaml
- name: Install test dependencies
  run: npm install
  
- name: Run integration tests
  run: ./tests/llmock/runner.sh
```

## Tips

1. **Load order matters**: More specific fixtures should be loaded first
2. **Use catch-alls**: Add a default fixture to avoid 404s
3. **Test errors**: Use `nextRequestError()` for error injection
4. **Inspect requests**: Check `http://localhost:4010/v1/_requests`

## Resources

- [llmock GitHub](https://github.com/CopilotKit/llmock)
- [llmock npm](https://www.npmjs.com/package/@copilotkit/llmock)
