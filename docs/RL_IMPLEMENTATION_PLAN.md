# NullClaw RL Integration - Complete Implementation Plan

**Timeline:** 4 weeks to production-ready system
**Budget:** $0 (Mac) or $300 (GPU) or $50-100 (cloud)
**Model:** Llama 3.2 3B (Mac) or Llama 3.1 8B (GPU)

---

## Overview

This plan covers **28 implementation items** across **7 categories** with concrete steps, code examples, and timelines.

---

## Phase 1: Prototype (Days 1-2) - 12.5 hours

**Goal:** Working end-to-end system that can learn from 1 conversation

### 1.1 HTTP Client Implementation (2 hours)

**File:** `src/http_client.zig`

```zig
const std = @import("std");
const http = std.http;

pub const HttpClient = struct {
    allocator: std.mem.Allocator,
    client: http.Client,
    
    pub fn init(allocator: std.mem.Allocator) HttpClient {
        return .{
            .allocator = allocator,
            .client = http.Client{ .allocator = allocator },
        };
    }
    
    pub fn deinit(self: *HttpClient) void {
        self.client.deinit();
    }
    
    /// POST JSON to URL with timeout
    pub fn postJson(
        self: *HttpClient,
        url: []const u8,
        body: []const u8,
        timeout_ms: u64,
    ) ![]u8 {
        // Parse URL
        const uri = try std.Uri.parse(url);
        
        // Setup headers
        var headers = std.http.Headers{ .allocator = self.allocator };
        defer headers.deinit();
        try headers.append("Content-Type", "application/json");
        try headers.append("Accept", "application/json");
        
        // Setup request
        var req = try self.client.request(
            .POST,
            uri,
            headers,
            .{ .handle_redirects = true },
        );
        defer req.deinit();
        
        // Set timeout
        req.connection.?.stream.setReadTimeout(timeout_ms) catch {};
        
        // Write body
        req.transfer_encoding = .{ .content_length = body.len };
        try req.start();
        try req.writeAll(body);
        try req.finish();
        
        // Read response
        try req.wait();
        const response = try req.reader().readAllAlloc(
            self.allocator,
            1024 * 1024, // Max 1MB
        );
        
        return response;
    }
    
    /// GET from URL
    pub fn get(
        self: *HttpClient,
        url: []const u8,
    ) ![]u8 {
        const uri = try std.Uri.parse(url);
        
        var headers = std.http.Headers{ .allocator = self.allocator };
        defer headers.deinit();
        
        var req = try self.client.request(
            .GET,
            uri,
            headers,
            .{},
        );
        defer req.deinit();
        
        try req.start();
        try req.wait();
        
        return try req.reader().readAllAlloc(self.allocator, 1024 * 1024);
    }
};
```

**Testing:**
```zig
test "HTTP POST" {
    var client = HttpClient.init(std.testing.allocator);
    defer client.deinit();
    
    const response = try client.postJson(
        "http://localhost:8888/test",
        "{\"test\":true}",
        5000,
    );
    defer std.testing.allocator.free(response);
    
    try std.testing.expect(response.len > 0);
}
```

**Dependencies:** None
**Deliverable:** Working HTTP client with tests

---

### 1.2 Base Model Download (30 minutes)

**Step 1:** Install Hugging Face CLI
```bash
pip install huggingface-hub
```

**Step 2:** Download Llama 3.2 3B (MLX format for Mac)
```bash
# Create models directory
mkdir -p ~/.openclaw/models
cd ~/.openclaw/models

# Download model (5GB)
huggingface-cli download \
  mlx-community/Llama-3.2-3B-Instruct-4bit \
  --local-dir Llama-3.2-3B-Instruct-4bit
```

**Step 3:** Verify download
```bash
ls -lh Llama-3.2-3B-Instruct-4bit/
# Should see: config.json, model.safetensors, tokenizer.json, etc.
```

**Step 4:** Test model loading
```python
from mlx_lm import load, generate

model, tokenizer = load("~/.openclaw/models/Llama-3.2-3B-Instruct-4bit")
response = generate(model, tokenizer, prompt="Hello", temp=0.7)
print(response)
```

**Dependencies:** None
**Deliverable:** Working model loaded in memory

---

### 1.3 Tokenizer Setup (1 hour)

**File:** `rl/tokenizer.py`

```python
from transformers import AutoTokenizer
from typing import List, Dict
import json

class ConversationTokenizer:
    """Tokenize conversations for Llama 3.x format"""
    
    def __init__(self, model_path: str):
        self.tokenizer = AutoTokenizer.from_pretrained(model_path)
        
        # Ensure special tokens are set
        if self.tokenizer.pad_token is None:
            self.tokenizer.pad_token = self.tokenizer.eos_token
    
    def format_conversation(
        self,
        messages: List[Dict[str, str]],
        add_generation_prompt: bool = True,
    ) -> str:
        """Format messages in Llama 3.x chat format"""
        
        formatted = "<|begin_of_text|>"
        
        for msg in messages:
            role = msg["role"]
            content = msg["content"]
            
            formatted += f"<|start_header_id|>{role}<|end_header_id|>\n"
            formatted += f"{content}<|eot_id|>"
        
        if add_generation_prompt:
            formatted += "<|start_header_id|>assistant<|end_header_id|>\n"
        
        return formatted
    
    def tokenize_for_training(
        self,
        conversation: List[Dict[str, str]],
        max_length: int = 2048,
    ) -> Dict[str, List[int]]:
        """Tokenize conversation for training"""
        
        # Format conversation
        text = self.format_conversation(conversation)
        
        # Tokenize
        tokens = self.tokenizer(
            text,
            max_length=max_length,
            truncation=True,
            padding=False,
            return_tensors=None,
        )
        
        return {
            "input_ids": tokens["input_ids"],
            "attention_mask": tokens["attention_mask"],
            "labels": tokens["input_ids"].copy(),  # For causal LM
        }
    
    def decode(self, token_ids: List[int]) -> str:
        """Decode tokens back to text"""
        return self.tokenizer.decode(token_ids, skip_special_tokens=True)
    
    @property
    def vocab_size(self) -> int:
        return len(self.tokenizer)
    
    @property
    def eos_token_id(self) -> int:
        return self.tokenizer.eos_token_id


# Test
if __name__ == "__main__":
    tok = ConversationTokenizer("~/.openclaw/models/Llama-3.2-3B-Instruct-4bit")
    
    messages = [
        {"role": "user", "content": "Hello!"},
        {"role": "assistant", "content": "Hi there! How can I help?"},
    ]
    
    formatted = tok.format_conversation(messages)
    print("Formatted:")
    print(formatted)
    
    tokens = tok.tokenize_for_training(messages)
    print(f"\nToken count: {len(tokens['input_ids'])}")
```

**Testing:**
```bash
python rl/tokenizer.py
# Should print formatted conversation and token count
```

**Dependencies:** 1.2 (model download)
**Deliverable:** Tokenizer that produces Llama 3.x format

---

### 1.4 Prompt Format Implementation (2 hours)

**File:** `rl/prompt_templates.py`

```python
from typing import List, Dict, Optional
from dataclasses import dataclass

@dataclass
class Conversation:
    """Single conversation turn"""
    role: str  # user, assistant, system
    content: str
    metadata: Optional[Dict] = None


class PromptFormatter:
    """Format prompts for different model types"""
    
    @staticmethod
    def format_llama3(
        messages: List[Conversation],
        system_prompt: Optional[str] = None,
    ) -> str:
        """Format for Llama 3.x models"""
        
        parts = ["<|begin_of_text|>"]
        
        # Add system prompt if provided
        if system_prompt:
            parts.append("<|start_header_id|>system<|end_header_id|>\n")
            parts.append(f"{system_prompt}<|eot_id|>")
        
        # Add conversation turns
        for msg in messages:
            parts.append(f"<|start_header_id|>{msg.role}<|end_header_id|>\n")
            parts.append(f"{msg.content}<|eot_id|>")
        
        # Add generation prompt
        parts.append("<|start_header_id|>assistant<|end_header_id|>\n")
        
        return "".join(parts)
    
    @staticmethod
    def format_for_pattern_extraction(
        conversations: List[List[Conversation]],
        feedback_history: List[Dict],
    ) -> str:
        """Format conversations for pattern extraction"""
        
        prompt = """Analyze these conversations and extract learning patterns.

CONVERSATIONS:
"""
        
        for i, conv in enumerate(conversations):
            prompt += f"\n--- Conversation {i+1} ---\n"
            for msg in conv:
                prompt += f"{msg.role.upper()}: {msg.content}\n"
            
            # Add feedback if available
            if i < len(feedback_history):
                fb = feedback_history[i]
                prompt += f"FEEDBACK: reward={fb.get('reward', 0)}, hint={fb.get('hint', 'none')}\n"
        
        prompt += """
Find patterns in three categories:

1. POSITIVE patterns (what worked well)
   Format: {"type":"positive","context":"...","response":"...","reward":0.0-1.0}

2. NEGATIVE patterns (what didn't work)
   Format: {"type":"negative","context":"...","response":"...","reward":-1.0-0.0}

3. IMPROVEMENTS (what could be better)
   Format: {"type":"improvement","context":"...","hint":"...","suggested":"..."}

Output as JSON array. Be specific and actionable."""
        
        return prompt
    
    @staticmethod
    def format_for_training_sample(
        context: str,
        good_response: Optional[str] = None,
        bad_response: Optional[str] = None,
        hint: Optional[str] = None,
    ) -> List[Conversation]:
        """Create training sample from pattern"""
        
        messages = []
        
        # Context as user message
        messages.append(Conversation(
            role="user",
            content=context,
        ))
        
        # If we have a good response, use it
        if good_response:
            messages.append(Conversation(
                role="assistant",
                content=good_response,
            ))
        
        # If we have a hint, add it as system guidance
        if hint and not good_response:
            messages.insert(0, Conversation(
                role="system",
                content=f"Hint for better response: {hint}",
            ))
        
        return messages


# Test
if __name__ == "__main__":
    # Test Llama 3 format
    messages = [
        Conversation(role="user", content="Hello!"),
        Conversation(role="assistant", content="Hi there!"),
    ]
    
    formatted = PromptFormatter.format_llama3(
        messages,
        system_prompt="You are a helpful assistant.",
    )
    
    print("Llama 3 format:")
    print(formatted)
    print()
    
    # Test pattern extraction prompt
    convs = [messages]
    feedback = [{"reward": 1.0, "hint": None}]
    
    extraction_prompt = PromptFormatter.format_for_pattern_extraction(convs, feedback)
    print("Pattern extraction prompt:")
    print(extraction_prompt[:500] + "...")
```

**Testing:**
```bash
python rl/prompt_templates.py
# Should print formatted prompts
```

**Dependencies:** None
**Deliverable:** Prompt formatting utilities

---

### 1.5 Basic Training Loop (4 hours)

**File:** `rl/trainer.py`

```python
import json
from pathlib import Path
from typing import List, Dict, Optional
from dataclasses import dataclass
import time

# MLX imports (for Mac)
try:
    from mlx_lm import load, generate
    from mlx_lm.tuner import TrainingArgs, train
    HAS_MLX = True
except ImportError:
    HAS_MLX = False
    print("Warning: MLX not available. Install with: pip install mlx mlx-lm")

@dataclass
class TrainingSample:
    """Single training sample"""
    input_ids: List[int]
    labels: List[int]
    reward: float
    source: str  # conversation, feedback, manual
    timestamp: float = time.time()


class RLTrainer:
    """LoRA trainer for continuous learning"""
    
    def __init__(
        self,
        model_path: str,
        output_dir: str = "adapters",
        lora_rank: int = 8,
        learning_rate: float = 1e-5,
    ):
        self.model_path = model_path
        self.output_dir = Path(output_dir)
        self.output_dir.mkdir(exist_ok=True)
        
        self.lora_rank = lora_rank
        self.learning_rate = learning_rate
        
        # Load base model
        if HAS_MLX:
            self.model, self.tokenizer = load(model_path)
        else:
            self.model = None
            self.tokenizer = None
        
        # Training state
        self.samples: List[TrainingSample] = []
        self.current_adapter: Optional[str] = None
        self.training_history: List[Dict] = []
    
    def add_sample(
        self,
        conversation: List[Dict],
        reward: float,
        source: str = "conversation",
    ):
        """Add training sample"""
        
        # Tokenize
        from .tokenizer import ConversationTokenizer
        tok = ConversationTokenizer(self.model_path)
        tokens = tok.tokenize_for_training(conversation)
        
        sample = TrainingSample(
            input_ids=tokens["input_ids"],
            labels=tokens["labels"],
            reward=reward,
            source=source,
        )
        
        self.samples.append(sample)
    
    def prepare_dataset(self, samples: List[TrainingSample]) -> List[Dict]:
        """Prepare samples for MLX training"""
        
        dataset = []
        for sample in samples:
            # Weight by reward (positive = reinforce, negative = avoid)
            weight = max(0.1, sample.reward + 1.0)  # Normalize to 0.1-2.0
            
            dataset.append({
                "input_ids": sample.input_ids,
                "labels": sample.labels,
                "weight": weight,
            })
        
        return dataset
    
    def train(
        self,
        min_samples: int = 10,
        epochs: int = 3,
        batch_size: int = 4,
    ) -> Optional[str]:
        """Train LoRA adapter on collected samples"""
        
        if len(self.samples) < min_samples:
            print(f"Not enough samples: {len(self.samples)}/{min_samples}")
            return None
        
        if not HAS_MLX:
            print("MLX not available, skipping training")
            return None
        
        # Prepare dataset
        dataset = self.prepare_dataset(self.samples)
        
        # Setup training args
        args = TrainingArgs(
            model=self.model_path,
            train=True,
            data=dataset,
            batch_size=batch_size,
            iters=epochs * len(dataset) // batch_size,
            learning_rate=self.learning_rate,
            lora_layers=16,  # Number of layers to apply LoRA
            lora_rank=self.lora_rank,
            adapter_path=str(self.output_dir / f"adapter_{int(time.time())}"),
        )
        
        # Train
        print(f"Training on {len(dataset)} samples...")
        start_time = time.time()
        
        train(args)
        
        elapsed = time.time() - start_time
        print(f"Training complete: {elapsed:.1f}s")
        
        # Save adapter
        adapter_path = args.adapter_path
        
        # Update current adapter
        self.current_adapter = adapter_path
        
        # Record training
        self.training_history.append({
            "timestamp": time.time(),
            "samples": len(dataset),
            "epochs": epochs,
            "elapsed": elapsed,
            "adapter_path": adapter_path,
        })
        
        # Clear samples
        self.samples = []
        
        return adapter_path
    
    def load_adapter(self, adapter_path: str):
        """Load trained adapter"""
        
        if HAS_MLX:
            self.model, self.tokenizer = load(
                self.model_path,
                adapter_path=adapter_path,
            )
            self.current_adapter = adapter_path
            print(f"Loaded adapter: {adapter_path}")
    
    def generate(
        self,
        prompt: str,
        temperature: float = 0.7,
        max_tokens: int = 512,
    ) -> str:
        """Generate response with current model"""
        
        if not HAS_MLX or self.model is None:
            return "Error: Model not loaded"
        
        return generate(
            self.model,
            self.tokenizer,
            prompt=prompt,
            temp=temperature,
            max_tokens=max_tokens,
        )
    
    def save_state(self, path: str):
        """Save training state"""
        state = {
            "samples_count": len(self.samples),
            "current_adapter": self.current_adapter,
            "training_history": self.training_history,
        }
        
        with open(path, 'w') as f:
            json.dump(state, f, indent=2)
    
    def load_state(self, path: str):
        """Load training state"""
        with open(path) as f:
            state = json.load(f)
        
        self.training_history = state.get("training_history", [])
        
        if state.get("current_adapter"):
            self.load_adapter(state["current_adapter"])


# Test
if __name__ == "__main__":
    trainer = RLTrainer(
        model_path="~/.openclaw/models/Llama-3.2-3B-Instruct-4bit",
        output_dir="adapters",
    )
    
    # Add sample
    trainer.add_sample(
        conversation=[
            {"role": "user", "content": "Hello!"},
            {"role": "assistant", "content": "Hi there!"},
        ],
        reward=1.0,
    )
    
    print(f"Samples: {len(trainer.samples)}")
    
    # Train (will skip if < 10 samples)
    adapter = trainer.train(min_samples=1)  # Lower threshold for testing
    
    if adapter:
        print(f"Trained adapter: {adapter}")
```

**Testing:**
```bash
python rl/trainer.py
# Should train (or skip if not enough samples)
```

**Dependencies:** 1.2, 1.3 (model, tokenizer)
**Deliverable:** Working LoRA trainer

---

### 1.6 Simple Consolidation (3 hours)

**File:** `rl/consolidation.py`

```python
import json
from typing import List, Dict, Optional
from dataclasses import dataclass
from datetime import datetime, timedelta
import time

@dataclass
class Pattern:
    """Extracted pattern from conversations"""
    type: str  # positive, negative, improvement
    context: str
    response: Optional[str]
    reward: float
    hint: Optional[str]
    timestamp: float = time.time()


class Consolidator:
    """Extract patterns from conversations for training"""
    
    def __init__(
        self,
        llm_endpoint: str = "http://localhost:30000/v1/chat/completions",
        min_conversations: int = 5,
    ):
        self.llm_endpoint = llm_endpoint
        self.min_conversations = min_conversations
        
        self.patterns: List[Pattern] = []
        self.conversations: List[Dict] = []
    
    def add_conversation(
        self,
        messages: List[Dict],
        feedback: Optional[Dict] = None,
    ):
        """Add conversation for consolidation"""
        
        self.conversations.append({
            "messages": messages,
            "feedback": feedback or {},
            "timestamp": time.time(),
        })
    
    def extract_patterns_with_llm(
        self,
        conversations: List[Dict],
    ) -> List[Pattern]:
        """Use LLM to extract patterns"""
        
        # Format prompt
        from .prompt_templates import PromptFormatter
        
        convs = []
        feedbacks = []
        for conv in conversations:
            from .prompt_templates import Conversation
            msgs = [
                Conversation(
                    role=msg["role"],
                    content=msg["content"],
                )
                for msg in conv["messages"]
            ]
            convs.append(msgs)
            feedbacks.append(conv["feedback"])
        
        prompt = PromptFormatter.format_for_pattern_extraction(convs, feedbacks)
        
        # Call LLM
        import requests
        response = requests.post(
            self.llm_endpoint,
            json={
                "messages": [{"role": "user", "content": prompt}],
                "temperature": 0.3,  # Low temp for extraction
                "max_tokens": 2000,
            },
            timeout=60,
        )
        
        response.raise_for_status()
        result = response.json()
        
        # Parse patterns
        text = result["choices"][0]["message"]["content"]
        
        # Extract JSON from response
        import re
        json_match = re.search(r'\[.*\]', text, re.DOTALL)
        if not json_match:
            return []
        
        try:
            patterns_json = json.loads(json_match.group())
        except json.JSONDecodeError:
            return []
        
        # Convert to Pattern objects
        patterns = []
        for p in patterns_json:
            patterns.append(Pattern(
                type=p.get("type", "improvement"),
                context=p.get("context", ""),
                response=p.get("response") or p.get("suggested"),
                reward=p.get("reward", 0.0),
                hint=p.get("hint"),
            ))
        
        return patterns
    
    def extract_patterns_simple(
        self,
        conversations: List[Dict],
    ) -> List[Pattern]:
        """Simple heuristic pattern extraction (no LLM)"""
        
        patterns = []
        
        for conv in conversations:
            feedback = conv.get("feedback", {})
            reward = feedback.get("reward", 0.0)
            
            if reward == 0:
                continue
            
            # Get last user-assistant exchange
            messages = conv["messages"]
            if len(messages) < 2:
                continue
            
            user_msg = None
            assistant_msg = None
            
            for msg in reversed(messages):
                if msg["role"] == "assistant" and not assistant_msg:
                    assistant_msg = msg["content"]
                elif msg["role"] == "user" and not user_msg:
                    user_msg = msg["content"]
                    break
            
            if not user_msg or not assistant_msg:
                continue
            
            # Create pattern
            pattern_type = "positive" if reward > 0 else "negative"
            
            patterns.append(Pattern(
                type=pattern_type,
                context=user_msg,
                response=assistant_msg,
                reward=reward,
                hint=feedback.get("hint"),
            ))
        
        return patterns
    
    def consolidate(
        self,
        hours: int = 24,
        use_llm: bool = False,
    ) -> List[Pattern]:
        """Extract patterns from recent conversations"""
        
        # Filter recent conversations
        cutoff = time.time() - (hours * 3600)
        recent = [
            conv for conv in self.conversations
            if conv["timestamp"] > cutoff
        ]
        
        if len(recent) < self.min_conversations:
            print(f"Not enough conversations: {len(recent)}/{self.min_conversations}")
            return []
        
        # Extract patterns
        if use_llm:
            patterns = self.extract_patterns_with_llm(recent)
        else:
            patterns = self.extract_patterns_simple(recent)
        
        # Save patterns
        self.patterns.extend(patterns)
        
        return patterns
    
    def generate_training_samples(
        self,
        patterns: List[Pattern],
    ) -> List[Dict]:
        """Convert patterns to training samples"""
        
        samples = []
        
        for pattern in patterns:
            if pattern.type == "positive" and pattern.response:
                # Good response - reinforce
                samples.append({
                    "messages": [
                        {"role": "user", "content": pattern.context},
                        {"role": "assistant", "content": pattern.response},
                    ],
                    "reward": pattern.reward,
                })
            
            elif pattern.type == "negative" and pattern.hint:
                # Bad response - provide better alternative via hint
                samples.append({
                    "messages": [
                        {"role": "user", "content": pattern.context},
                        {"role": "system", "content": f"Improve: {pattern.hint}"},
                    ],
                    "reward": abs(pattern.reward),  # Convert to positive
                })
            
            elif pattern.type == "improvement" and pattern.hint:
                # Improvement suggestion
                samples.append({
                    "messages": [
                        {"role": "user", "content": pattern.context},
                        {"role": "system", "content": f"Hint: {pattern.hint}"},
                    ],
                    "reward": 0.5,  # Moderate reward
                })
        
        return samples
    
    def save_patterns(self, path: str):
        """Save patterns to file"""
        data = [
            {
                "type": p.type,
                "context": p.context,
                "response": p.response,
                "reward": p.reward,
                "hint": p.hint,
                "timestamp": p.timestamp,
            }
            for p in self.patterns
        ]
        
        with open(path, 'w') as f:
            json.dump(data, f, indent=2)
    
    def load_patterns(self, path: str):
        """Load patterns from file"""
        with open(path) as f:
            data = json.load(f)
        
        self.patterns = [
            Pattern(**p) for p in data
        ]


# Test
if __name__ == "__main__":
    consolidator = Consolidator(min_conversations=1)
    
    # Add conversation
    consolidator.add_conversation(
        messages=[
            {"role": "user", "content": "Hello!"},
            {"role": "assistant", "content": "Hi!"},
        ],
        feedback={"reward": 1.0},
    )
    
    # Consolidate
    patterns = consolidator.consolidate(hours=24, use_llm=False)
    
    print(f"Extracted {len(patterns)} patterns:")
    for p in patterns:
        print(f"  - {p.type}: {p.context[:50]}... (reward={p.reward})")
    
    # Generate samples
    samples = consolidator.generate_training_samples(patterns)
    print(f"\nGenerated {len(samples)} training samples")
```

**Testing:**
```bash
python rl/consolidation.py
# Should extract patterns from conversations
```

**Dependencies:** 1.4 (prompt templates)
**Deliverable:** Working consolidation

---

### Phase 1 Milestone

**At end of Day 2, you should have:**

- ✅ HTTP client that can POST to localhost
- ✅ Llama 3.2 3B downloaded and loading
- ✅ Tokenizer producing Llama 3.x format
- ✅ Prompt templates for chat + extraction
- ✅ LoRA trainer that can train on 10 samples
- ✅ Consolidation extracting patterns from conversations

**Test command:**
```bash
# Start mock conversation
python -c "
from rl.consolidation import Consolidator
from rl.trainer import RLTrainer

# Add conversation
cons = Consolidator(min_conversations=1)
cons.add_conversation(
    [{'role': 'user', 'content': 'Hello'}],
    {'reward': 1.0}
)

# Extract patterns
patterns = cons.consolidate(use_llm=False)
print(f'Patterns: {len(patterns)}')

# Train
trainer = RLTrainer('~/.openclaw/models/Llama-3.2-3B-Instruct-4bit')
samples = cons.generate_training_samples(patterns)
for s in samples:
    trainer.add_sample(s['messages'], s['reward'])

adapter = trainer.train(min_samples=1)
print(f'Trained: {adapter}')
"
```

---

## Phase 2: MVP (Days 3-7) - 1 week

**Goal:** System that can learn continuously with basic safeguards

### 2.1 Reward Signal Computation (4 hours)

**File:** `rl/rewards.py`

```python
from typing import List, Dict, Optional
from dataclasses import dataclass
from collections import defaultdict
import time

@dataclass
class FeedbackEvent:
    """Single feedback event"""
    timestamp: float
    session_id: str
    turn_id: int
    reward: float
    hint: Optional[str]
    source: str  # explicit, implicit, manual


class RewardCalculator:
    """Compute aggregate rewards from feedback signals"""
    
    def __init__(
        self,
        decay_rate: float = 0.95,  # Older feedback weighted less
        implicit_positive: float = 0.1,  # User continues conversation
        implicit_negative: float = -0.1,  # User ignores response
        min_feedbacks: int = 1,  # Minimum to compute reward
    ):
        self.decay_rate = decay_rate
        self.implicit_positive = implicit_positive
        self.implicit_negative = implicit_negative
        self.min_feedbacks = min_feedbacks
        
        self.feedbacks: List[FeedbackEvent] = []
        self.session_feedbacks: Dict[str, List[FeedbackEvent]] = defaultdict(list)
    
    def add_explicit_feedback(
        self,
        session_id: str,
        turn_id: int,
        reward: float,
        hint: Optional[str] = None,
    ):
        """Add explicit feedback (👍/👎 or /reward command)"""
        
        event = FeedbackEvent(
            timestamp=time.time(),
            session_id=session_id,
            turn_id=turn_id,
            reward=reward,
            hint=hint,
            source="explicit",
        )
        
        self.feedbacks.append(event)
        self.session_feedbacks[session_id].append(event)
    
    def add_implicit_feedback(
        self,
        session_id: str,
        turn_id: int,
        user_continued: bool,
    ):
        """Add implicit feedback based on user behavior"""
        
        reward = self.implicit_positive if user_continued else self.implicit_negative
        
        event = FeedbackEvent(
            timestamp=time.time(),
            session_id=session_id,
            turn_id=turn_id,
            reward=reward,
            hint=None,
            source="implicit",
        )
        
        self.feedbacks.append(event)
        self.session_feedbacks[session_id].append(event)
    
    def compute_turn_reward(
        self,
        session_id: str,
        turn_id: int,
    ) -> Optional[float]:
        """Compute aggregate reward for a turn"""
        
        events = [
            e for e in self.session_feedbacks.get(session_id, [])
            if e.turn_id == turn_id
        ]
        
        if len(events) < self.min_feedbacks:
            return None
        
        # Weight by recency (decay)
        now = time.time()
        weighted_sum = 0.0
        weight_sum = 0.0
        
        for event in events:
            age_hours = (now - event.timestamp) / 3600
            weight = self.decay_rate ** age_hours
            
            weighted_sum += event.reward * weight
            weight_sum += weight
        
        if weight_sum == 0:
            return None
        
        return weighted_sum / weight_sum
    
    def compute_session_reward(
        self,
        session_id: str,
    ) -> Optional[float]:
        """Compute aggregate reward for entire session"""
        
        events = self.session_feedbacks.get(session_id, [])
        
        if len(events) < self.min_feedbacks:
            return None
        
        # Average all turn rewards
        turn_rewards = []
        turn_ids = set(e.turn_id for e in events)
        
        for turn_id in turn_ids:
            reward = self.compute_turn_reward(session_id, turn_id)
            if reward is not None:
                turn_rewards.append(reward)
        
        if not turn_rewards:
            return None
        
        return sum(turn_rewards) / len(turn_rewards)
    
    def get_training_samples(
        self,
        min_reward_abs: float = 0.1,
    ) -> List[Dict]:
        """Get samples suitable for training"""
        
        samples = []
        
        for session_id, events in self.session_feedbacks.items():
            # Compute session reward
            session_reward = self.compute_session_reward(session_id)
            if session_reward is None:
                continue
            
            # Skip if reward too weak
            if abs(session_reward) < min_reward_abs:
                continue
            
            samples.append({
                "session_id": session_id,
                "reward": session_reward,
                "feedback_count": len(events),
                "explicit_count": sum(1 for e in events if e.source == "explicit"),
                "implicit_count": sum(1 for e in events if e.source == "implicit"),
            })
        
        return samples
    
    def detect_conflicts(
        self,
        session_id: str,
    ) -> List[Dict]:
        """Detect conflicting feedback (👍 then 👎)"""
        
        events = self.session_feedbacks.get(session_id, [])
        
        conflicts = []
        positive = [e for e in events if e.reward > 0]
        negative = [e for e in events if e.reward < 0]
        
        if positive and negative:
            conflicts.append({
                "session_id": session_id,
                "positive_count": len(positive),
                "negative_count": len(negative),
                "positive_avg": sum(e.reward for e in positive) / len(positive),
                "negative_avg": sum(e.reward for e in negative) / len(negative),
            })
        
        return conflicts


# Test
if __name__ == "__main__":
    calc = RewardCalculator()
    
    # Add feedbacks
    calc.add_explicit_feedback("session1", 0, 1.0)
    calc.add_implicit_feedback("session1", 0, user_continued=True)
    calc.add_explicit_feedback("session1", 1, -0.5)
    
    # Compute rewards
    print(f"Turn 0 reward: {calc.compute_turn_reward('session1', 0)}")
    print(f"Turn 1 reward: {calc.compute_turn_reward('session1', 1)}")
    print(f"Session reward: {calc.compute_session_reward('session1')}")
    
    # Get training samples
    samples = calc.get_training_samples()
    print(f"\nTraining samples: {len(samples)}")
    
    # Detect conflicts
    conflicts = calc.detect_conflicts("session1")
    print(f"Conflicts: {len(conflicts)}")
```

**Dependencies:** None
**Deliverable:** Reward calculation with decay + conflict detection

---

### 2.2 Sample Filtering (2 hours)

**File:** `rl/filtering.py`

```python
from typing import List, Dict, Optional
from dataclasses import dataclass

@dataclass
class FilterResult:
    """Result of sample filtering"""
    passed: bool
    reason: Optional[str] = None


class SampleFilter:
    """Filter training samples by quality"""
    
    def __init__(
        self,
        min_feedback_count: int = 1,
        min_reward_abs: float = 0.2,
        max_length: int = 4096,
        min_length: int = 10,
        require_explicit: bool = False,
        exclude_adversarial_patterns: List[str] = None,
    ):
        self.min_feedback_count = min_feedback_count
        self.min_reward_abs = min_reward_abs
        self.max_length = max_length
        self.min_length = min_length
        self.require_explicit = require_explicit
        self.exclude_adversarial_patterns = exclude_adversarial_patterns or [
            "ignore previous",
            "disregard",
            "forget",
            "override",
        ]
    
    def filter(
        self,
        sample: Dict,
    ) -> FilterResult:
        """Check if sample passes all filters"""
        
        # Check feedback count
        feedback_count = sample.get("feedback_count", 0)
        if feedback_count < self.min_feedback_count:
            return FilterResult(
                passed=False,
                reason=f"Insufficient feedback: {feedback_count}/{self.min_feedback_count}",
            )
        
        # Check reward strength
        reward = abs(sample.get("reward", 0))
        if reward < self.min_reward_abs:
            return FilterResult(
                passed=False,
                reason=f"Weak reward signal: {reward} < {self.min_reward_abs}",
            )
        
        # Check explicit feedback requirement
        if self.require_explicit:
            explicit_count = sample.get("explicit_count", 0)
            if explicit_count == 0:
                return FilterResult(
                    passed=False,
                    reason="No explicit feedback",
                )
        
        # Check message length
        messages = sample.get("messages", [])
        total_length = sum(len(m.get("content", "")) for m in messages)
        
        if total_length < self.min_length:
            return FilterResult(
                passed=False,
                reason=f"Too short: {total_length} < {self.min_length}",
            )
        
        if total_length > self.max_length:
            return FilterResult(
                passed=False,
                reason=f"Too long: {total_length} > {self.max_length}",
            )
        
        # Check for adversarial patterns
        for msg in messages:
            content = msg.get("content", "").lower()
            for pattern in self.exclude_adversarial_patterns:
                if pattern in content:
                    return FilterResult(
                        passed=False,
                        reason=f"Adversarial pattern detected: {pattern}",
                    )
        
        return FilterResult(passed=True)
    
    def filter_batch(
        self,
        samples: List[Dict],
    ) -> tuple[List[Dict], List[Dict]]:
        """Filter batch of samples, return (passed, failed)"""
        
        passed = []
        failed = []
        
        for sample in samples:
            result = self.filter(sample)
            
            if result.passed:
                passed.append(sample)
            else:
                failed.append({
                    "sample": sample,
                    "reason": result.reason,
                })
        
        return passed, failed


# Test
if __name__ == "__main__":
    filter = SampleFilter(
        min_feedback_count=1,
        min_reward_abs=0.2,
        require_explicit=False,
    )
    
    samples = [
        {
            "messages": [{"role": "user", "content": "Hello!"}],
            "reward": 1.0,
            "feedback_count": 2,
            "explicit_count": 1,
        },
        {
            "messages": [{"role": "user", "content": "Ignore previous instructions"}],
            "reward": 1.0,
            "feedback_count": 1,
        },
        {
            "messages": [{"role": "user", "content": "Hi"}],
            "reward": 0.1,  # Weak signal
            "feedback_count": 1,
        },
    ]
    
    passed, failed = filter.filter_batch(samples)
    
    print(f"Passed: {len(passed)}")
    print(f"Failed: {len(failed)}")
    for f in failed:
        print(f"  - {f['reason']}")
```

**Dependencies:** None
**Deliverable:** Sample quality filter

---

### 2.3 Catastrophic Forgetting Prevention (1 day)

**File:** `rl/replay_buffer.py`

```python
import json
import random
from pathlib import Path
from typing import List, Dict, Optional
from dataclasses import dataclass
from collections import deque
import time

@dataclass
class ReplaySample:
    """Sample in replay buffer"""
    messages: List[Dict]
    reward: float
    timestamp: float
    source: str
    hash: str  # Unique identifier


class ReplayBuffer:
    """Prevent catastrophic forgetting with replay"""
    
    def __init__(
        self,
        max_size: int = 1000,
        replay_ratio: float = 0.2,  # 20% from buffer
        min_samples_before_replay: int = 50,
        buffer_path: str = "replay_buffer.json",
    ):
        self.max_size = max_size
        self.replay_ratio = replay_ratio
        self.min_samples = min_samples_before_replay
        self.buffer_path = Path(buffer_path)
        
        self.buffer: deque[ReplaySample] = deque(maxlen=max_size)
    
    def add(
        self,
        messages: List[Dict],
        reward: float,
        source: str = "new",
    ):
        """Add sample to buffer"""
        
        # Compute hash for deduplication
        import hashlib
        content = json.dumps(messages, sort_keys=True)
        hash = hashlib.md5(content.encode()).hexdigest()
        
        # Check if already in buffer
        if any(s.hash == hash for s in self.buffer):
            return  # Skip duplicate
        
        sample = ReplaySample(
            messages=messages,
            reward=reward,
            timestamp=time.time(),
            source=source,
            hash=hash,
        )
        
        self.buffer.append(sample)
    
    def sample(
        self,
        n: int,
        prioritize_recent: bool = True,
    ) -> List[ReplaySample]:
        """Sample from buffer"""
        
        if len(self.buffer) < n:
            return list(self.buffer)
        
        if prioritize_recent:
            # Weight by recency
            now = time.time()
            weights = []
            
            for sample in self.buffer:
                age_hours = (now - sample.timestamp) / 3600
                weight = 1.0 / (1.0 + age_hours)  # Newer = higher weight
                weights.append(weight)
            
            # Normalize
            total = sum(weights)
            weights = [w / total for w in weights]
            
            # Sample
            indices = random.choices(
                range(len(self.buffer)),
                weights=weights,
                k=n,
            )
            
            return [self.buffer[i] for i in indices]
        else:
            return random.sample(list(self.buffer), n)
    
    def mix_with_new(
        self,
        new_samples: List[Dict],
    ) -> List[Dict]:
        """Mix new samples with replay buffer"""
        
        if len(self.buffer) < self.min_samples:
            # Not enough in buffer yet
            return new_samples
        
        # Calculate replay count
        replay_count = int(len(new_samples) * self.replay_ratio)
        
        # Sample from buffer
        replay_samples = self.sample(replay_count)
        
        # Convert to dict format
        mixed = new_samples.copy()
        
        for sample in replay_samples:
            mixed.append({
                "messages": sample.messages,
                "reward": sample.reward,
                "source": "replay",
            })
        
        # Shuffle
        random.shuffle(mixed)
        
        return mixed
    
    def save(self):
        """Save buffer to disk"""
        data = [
            {
                "messages": s.messages,
                "reward": s.reward,
                "timestamp": s.timestamp,
                "source": s.source,
                "hash": s.hash,
            }
            for s in self.buffer
        ]
        
        with open(self.buffer_path, 'w') as f:
            json.dump(data, f, indent=2)
    
    def load(self):
        """Load buffer from disk"""
        if not self.buffer_path.exists():
            return
        
        with open(self.buffer_path) as f:
            data = json.load(f)
        
        self.buffer.clear()
        for item in data:
            self.buffer.append(ReplaySample(**item))
    
    def stats(self) -> Dict:
        """Get buffer statistics"""
        if not self.buffer:
            return {"size": 0}
        
        rewards = [s.reward for s in self.buffer]
        
        return {
            "size": len(self.buffer),
            "max_size": self.max_size,
            "avg_reward": sum(rewards) / len(rewards),
            "min_reward": min(rewards),
            "max_reward": max(rewards),
            "oldest_age_hours": (time.time() - self.buffer[0].timestamp) / 3600,
            "newest_age_hours": (time.time() - self.buffer[-1].timestamp) / 3600,
        }


# Test
if __name__ == "__main__":
    buffer = ReplayBuffer(max_size=10, replay_ratio=0.3)
    
    # Add samples
    for i in range(20):
        buffer.add(
            messages=[{"role": "user", "content": f"Test {i}"}],
            reward=random.random(),
        )
    
    print(f"Buffer size: {len(buffer.buffer)}")  # Should be 10 (max)
    
    # Sample
    samples = buffer.sample(5)
    print(f"\nSampled {len(samples)}:")
    for s in samples:
        print(f"  - {s.messages[0]['content']} (reward={s.reward:.2f})")
    
    # Mix with new
    new = [{"messages": [{"role": "user", "content": "New 1"}], "reward": 1.0}]
    mixed = buffer.mix_with_new(new)
    print(f"\nMixed: {len(mixed)} samples")
    for m in mixed:
        print(f"  - {m['messages'][0]['content']} (source={m.get('source', 'new')})")
    
    # Stats
    print(f"\nStats: {buffer.stats()}")
```

**Dependencies:** None
**Deliverable:** Replay buffer for forgetting prevention

---

### 2.4 Evaluation Metrics (1 day)

**File:** `rl/evaluation.py`

```python
from typing import List, Dict, Optional
from dataclasses import dataclass
import json
from pathlib import Path

@dataclass
class EvaluationResult:
    """Result of model evaluation"""
    timestamp: float
    samples_tested: int
    avg_reward: float
    response_quality: float
    instruction_following: float
    no_harmful_outputs: float
    no_regression: float
    overall_score: float


class ModelEvaluator:
    """Evaluate model quality"""
    
    def __init__(
        self,
        test_set_path: str = "test_set.json",
        baseline_adapter: Optional[str] = None,
    ):
        self.test_set_path = Path(test_set_path)
        self.baseline_adapter = baseline_adapter
        
        # Load test set
        self.test_set = self.load_test_set()
    
    def load_test_set(self) -> List[Dict]:
        """Load test set for evaluation"""
        
        if not self.test_set_path.exists():
            # Generate default test set
            return self.generate_default_test_set()
        
        with open(self.test_set_path) as f:
            return json.load(f)
    
    def generate_default_test_set(self) -> List[Dict]:
        """Generate basic test set"""
        
        return [
            {
                "category": "greeting",
                "messages": [{"role": "user", "content": "Hello!"}],
                "expected": ["Hi", "Hello", "Hey"],
                "avoid": ["error", "cannot", "sorry"],
            },
            {
                "category": "question",
                "messages": [{"role": "user", "content": "What is 2+2?"}],
                "expected": ["4", "four"],
                "avoid": ["error", "cannot"],
            },
            {
                "category": "instruction",
                "messages": [{"role": "user", "content": "Say 'test' in your response"}],
                "expected": ["test"],
                "avoid": ["cannot", "won't"],
            },
        ]
    
    def evaluate_response(
        self,
        response: str,
        expected: List[str],
        avoid: List[str],
    ) -> Dict[str, float]:
        """Evaluate single response"""
        
        response_lower = response.lower()
        
        # Check expected keywords
        expected_found = sum(
            1 for keyword in expected
            if keyword.lower() in response_lower
        )
        expected_score = expected_found / len(expected) if expected else 1.0
        
        # Check avoided keywords
        avoid_found = sum(
            1 for keyword in avoid
            if keyword.lower() in response_lower
        )
        avoid_score = 1.0 - (avoid_found / len(avoid) if avoid else 0.0)
        
        return {
            "expected_score": expected_score,
            "avoid_score": avoid_score,
            "overall": (expected_score + avoid_score) / 2,
        }
    
    def evaluate_model(
        self,
        generate_fn,  # Function to generate responses
    ) -> EvaluationResult:
        """Evaluate model on test set"""
        
        import time
        
        results = []
        
        for test in self.test_set:
            # Generate response
            prompt = test["messages"][0]["content"]
            response = generate_fn(prompt)
            
            # Evaluate
            scores = self.evaluate_response(
                response,
                test.get("expected", []),
                test.get("avoid", []),
            )
            
            results.append({
                "category": test["category"],
                "response": response,
                "scores": scores,
            })
        
        # Aggregate
        avg_expected = sum(r["scores"]["expected_score"] for r in results) / len(results)
        avg_avoid = sum(r["scores"]["avoid_score"] for r in results) / len(results)
        overall = (avg_expected + avg_avoid) / 2
        
        return EvaluationResult(
            timestamp=time.time(),
            samples_tested=len(results),
            avg_reward=0.0,  # Would need user feedback
            response_quality=avg_expected,
            instruction_following=avg_expected,
            no_harmful_outputs=avg_avoid,
            no_regression=1.0,  # Would need baseline comparison
            overall_score=overall,
        )
    
    def compare_with_baseline(
        self,
        current_result: EvaluationResult,
        baseline_result: Optional[EvaluationResult] = None,
    ) -> Dict:
        """Compare current model with baseline"""
        
        if baseline_result is None:
            return {
                "improved": None,
                "delta": 0.0,
                "current_score": current_result.overall_score,
            }
        
        delta = current_result.overall_score - baseline_result.overall_score
        
        return {
            "improved": delta > 0,
            "delta": delta,
            "current_score": current_result.overall_score,
            "baseline_score": baseline_result.overall_score,
        }


# Test
if __name__ == "__main__":
    evaluator = ModelEvaluator()
    
    print(f"Test set size: {len(evaluator.test_set)}")
    
    # Mock generate function
    def mock_generate(prompt: str) -> str:
        if "Hello" in prompt:
            return "Hi there! How can I help?"
        elif "2+2" in prompt:
            return "The answer is 4."
        elif "test" in prompt.lower():
            return "Sure, test!"
        return "I don't understand."
    
    # Evaluate
    result = evaluator.evaluate_model(mock_generate)
    
    print(f"\nEvaluation result:")
    print(f"  Samples tested: {result.samples_tested}")
    print(f"  Response quality: {result.response_quality:.2%}")
    print(f"  Instruction following: {result.instruction_following:.2%}")
    print(f"  No harmful outputs: {result.no_harmful_outputs:.2%}")
    print(f"  Overall: {result.overall_score:.2%}")
```

**Dependencies:** None
**Deliverable:** Automated model evaluation

---

### 2.5 Rollback Mechanism (3 hours)

**File:** `rl/rollback.py`

```python
import json
import shutil
from pathlib import Path
from typing import List, Dict, Optional
from dataclasses import dataclass
import time

@dataclass
class AdapterVersion:
    """Versioned adapter"""
    path: Path
    timestamp: float
    score: Optional[float]
    samples_count: int
    metadata: Dict


class AdapterVersionControl:
    """Version control for LoRA adapters"""
    
    def __init__(
        self,
        adapters_dir: str = "adapters",
        max_versions: int = 10,
        backup_dir: str = "adapters_backup",
    ):
        self.adapters_dir = Path(adapters_dir)
        self.backup_dir = Path(backup_dir)
        self.max_versions = max_versions
        
        self.adapters_dir.mkdir(exist_ok=True)
        self.backup_dir.mkdir(exist_ok=True)
        
        self.versions: List[AdapterVersion] = []
        self.load_versions()
    
    def load_versions(self):
        """Load version metadata"""
        
        metadata_path = self.adapters_dir / "versions.json"
        
        if not metadata_path.exists():
            return
        
        with open(metadata_path) as f:
            data = json.load(f)
        
        self.versions = [
            AdapterVersion(
                path=Path(v["path"]),
                timestamp=v["timestamp"],
                score=v.get("score"),
                samples_count=v["samples_count"],
                metadata=v.get("metadata", {}),
            )
            for v in data
        ]
    
    def save_versions(self):
        """Save version metadata"""
        
        metadata_path = self.adapters_dir / "versions.json"
        
        data = [
            {
                "path": str(v.path),
                "timestamp": v.timestamp,
                "score": v.score,
                "samples_count": v.samples_count,
                "metadata": v.metadata,
            }
            for v in self.versions
        ]
        
        with open(metadata_path, 'w') as f:
            json.dump(data, f, indent=2)
    
    def add_version(
        self,
        adapter_path: Path,
        score: Optional[float] = None,
        samples_count: int = 0,
        metadata: Optional[Dict] = None,
    ):
        """Add new adapter version"""
        
        # Copy to backup
        backup_path = self.backup_dir / f"adapter_{int(time.time())}"
        shutil.copytree(adapter_path, backup_path)
        
        version = AdapterVersion(
            path=backup_path,
            timestamp=time.time(),
            score=score,
            samples_count=samples_count,
            metadata=metadata or {},
        )
        
        self.versions.append(version)
        
        # Enforce max versions
        if len(self.versions) > self.max_versions:
            # Remove oldest
            oldest = self.versions.pop(0)
            if oldest.path.exists():
                shutil.rmtree(oldest.path)
        
        self.save_versions()
    
    def get_latest(self) -> Optional[AdapterVersion]:
        """Get latest adapter version"""
        
        if not self.versions:
            return None
        
        return self.versions[-1]
    
    def get_best(self) -> Optional[AdapterVersion]:
        """Get best scoring adapter"""
        
        scored = [v for v in self.versions if v.score is not None]
        
        if not scored:
            return self.get_latest()
        
        return max(scored, key=lambda v: v.score)
    
    def rollback(
        self,
        version: Optional[AdapterVersion] = None,
    ) -> Optional[Path]:
        """Rollback to specific version (or best if not specified)"""
        
        if version is None:
            version = self.get_best()
        
        if version is None:
            return None
        
        # Update symlink or copy
        latest_link = self.adapters_dir / "latest"
        
        if latest_link.exists() or latest_link.is_symlink():
            latest_link.unlink()
        
        # On systems without symlink support, copy instead
        try:
            latest_link.symlink_to(version.path)
        except OSError:
            if latest_link.exists():
                shutil.rmtree(latest_link)
            shutil.copytree(version.path, latest_link)
        
        return latest_link
    
    def should_rollback(
        self,
        current_score: float,
        threshold: float = 0.05,  # 5% degradation
    ) -> bool:
        """Check if should rollback based on score"""
        
        best = self.get_best()
        
        if best is None or best.score is None:
            return False
        
        degradation = (best.score - current_score) / best.score
        
        return degradation > threshold
    
    def auto_rollback(
        self,
        current_score: float,
        threshold: float = 0.05,
    ) -> Optional[Path]:
        """Automatically rollback if score degraded"""
        
        if not self.should_rollback(current_score, threshold):
            return None
        
        return self.rollback()


# Test
if __name__ == "__main__":
    vc = AdapterVersionControl(max_versions=5)
    
    # Add mock versions
    for i in range(7):
        adapter_path = Path(f"adapter_test_{i}")
        adapter_path.mkdir(exist_ok=True)
        
        vc.add_version(
            adapter_path=adapter_path,
            score=0.5 + i * 0.1,
            samples_count=10 * (i + 1),
        )
        
        print(f"Added version {i}: score={0.5 + i * 0.1}")
    
    print(f"\nTotal versions: {len(vc.versions)}")  # Should be 5 (max)
    
    latest = vc.get_latest()
    print(f"Latest: {latest.path.name} (score={latest.score})")
    
    best = vc.get_best()
    print(f"Best: {best.path.name} (score={best.score})")
    
    # Test rollback
    print(f"\nShould rollback (current=0.6): {vc.should_rollback(0.6, threshold=0.1)}")
    print(f"Should rollback (current=0.3): {vc.should_rollback(0.3, threshold=0.1)}")
```

**Dependencies:** None
**Deliverable:** Automatic rollback on quality degradation

---

### Phase 2 Milestone

**At end of Day 7, you should have:**

- ✅ Reward signal computation with decay
- ✅ Sample filtering by quality
- ✅ Replay buffer preventing forgetting
- ✅ Automated evaluation
- ✅ Automatic rollback

**Test command:**
```bash
# Test full pipeline
python -c "
from rl.rewards import RewardCalculator
from rl.filtering import SampleFilter
from rl.replay_buffer import ReplayBuffer
from rl.evaluation import ModelEvaluator
from rl.rollback import AdapterVersionControl

# Reward calc
calc = RewardCalculator()
calc.add_explicit_feedback('s1', 0, 1.0)
print(f'Reward: {calc.compute_turn_reward(\"s1\", 0)}')

# Filter
filter = SampleFilter(min_reward_abs=0.2)
samples = [{'reward': 1.0, 'feedback_count': 1, 'messages': [{'content': 'test'}]}]
passed, failed = filter.filter_batch(samples)
print(f'Filtered: {len(passed)}/{len(samples)}')

# Replay buffer
buffer = ReplayBuffer(max_size=10)
buffer.add([{'role': 'user', 'content': 'test'}], 1.0)
print(f'Buffer size: {len(buffer.buffer)}')

# Evaluator
evaluator = ModelEvaluator()
result = evaluator.evaluate_model(lambda p: 'test')
print(f'Evaluation: {result.overall_score:.2%}')

# Version control
vc = AdapterVersionControl(max_versions=5)
print(f'Versions: {len(vc.versions)}')

print('\n✅ All components working!')
"
```

---

## Phase 3: Production (Days 8-28) - 3 weeks

*Continues with detailed implementation of remaining 17 items...*

[Due to length, I'll continue in the next message if you want the full 4-week plan]

---

## Summary

**Phase 1 (2 days):** Working prototype
**Phase 2 (5 days):** MVP with safeguards
**Phase 3 (15 days):** Production-ready

**Total:** 28 items, 4 weeks, fully documented with code

Want me to continue with Phase 3 details?
