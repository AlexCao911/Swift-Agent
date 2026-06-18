# Plan 11: C++ On-Device Provider Boundary Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Establish the C++ inference boundary and Rust on-device provider adapter without pulling llama.cpp, Metal resource ownership, or model files into the Rust runtime.

**Architecture:** C++ exposes a small C ABI for model lifecycle and streaming. Rust depends first on a `LocalInferenceBackend` trait and a mock backend, then maps that backend into `ModelProvider` so the agent runtime can select an on-device provider through the same provider boundary as mock and Desktop MiniCPM.

**Tech Stack:** C ABI header, C++17 mock backend, Rust 2021, existing `ModelProvider`, existing `ProviderProfile`, `cargo test`, TDD.

---

## Current Code Audit

Expected after Plan 10:

- `ProviderKind::OnDeviceMiniCPM` exists.
- `ProviderRegistry` exists.
- `ModelProvider` remains the Rust runtime boundary.
- `DesktopMiniCPMProvider` proves provider replacement works without touching
  session, context, tools, memory, or security modules.

Still missing:

- `inference` directory.
- C ABI header.
- C++ backend contract.
- Rust on-device provider adapter.
- Resource lifecycle and cancellation tests.

Assigned to this plan:

- Add `inference/include/local_agent_inference.h`.
- Add mock C++ backend source documenting the real ABI behavior.
- Add Rust `LocalInferenceBackend` trait and `MockLocalInferenceBackend`.
- Add `OnDeviceMiniCPMProvider<B>`.
- Test load, stream, cancel, release lifecycle through Rust backend trait.

Deferred:

- Real llama.cpp linkage.
- Real GGUF loading.
- Metal resource configuration.
- Multimodal image tensor conversion.

## File Structure

Create:

```text
local-ios-agent/inference/include/local_agent_inference.h
local-ios-agent/inference/mock/local_agent_inference_mock.cpp
local-ios-agent/rust-core/src/core/ondevice_minicpm.rs
local-ios-agent/rust-core/tests/ondevice_minicpm_provider.rs
local-ios-agent/docs/model-providers/ondevice-minicpm-boundary.md
```

Modify:

```text
local-ios-agent/rust-core/src/core/mod.rs
```

## Task 1: Add C ABI Header and Mock Backend Source

**Files:**
- Create: `local-ios-agent/inference/include/local_agent_inference.h`
- Create: `local-ios-agent/inference/mock/local_agent_inference_mock.cpp`
- Create: `local-ios-agent/docs/model-providers/ondevice-minicpm-boundary.md`

- [ ] **Step 1: Create C ABI header**

Create `local-ios-agent/inference/include/local_agent_inference.h`:

```c
#ifndef LOCAL_AGENT_INFERENCE_H
#define LOCAL_AGENT_INFERENCE_H

#include <stddef.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

typedef struct LocalAgentBackend LocalAgentBackend;

typedef enum LocalAgentInferenceStatus {
    LOCAL_AGENT_INFERENCE_OK = 0,
    LOCAL_AGENT_INFERENCE_ERROR = 1,
    LOCAL_AGENT_INFERENCE_CANCELLED = 2
} LocalAgentInferenceStatus;

typedef void (*LocalAgentTokenCallback)(const char *token, void *user_data);

LocalAgentBackend *local_agent_backend_init(void);

LocalAgentInferenceStatus local_agent_backend_load_model(
    LocalAgentBackend *backend,
    const char *model_path
);

LocalAgentInferenceStatus local_agent_backend_stream_chat(
    LocalAgentBackend *backend,
    const char *prompt_json,
    LocalAgentTokenCallback callback,
    void *user_data
);

void local_agent_backend_cancel(LocalAgentBackend *backend);

void local_agent_backend_release(LocalAgentBackend *backend);

#ifdef __cplusplus
}
#endif

#endif
```

- [ ] **Step 2: Create mock C++ backend**

Create `local-ios-agent/inference/mock/local_agent_inference_mock.cpp`:

```cpp
#include "../include/local_agent_inference.h"

#include <atomic>
#include <string>

struct LocalAgentBackend {
    std::atomic<bool> cancelled{false};
    bool loaded{false};
    std::string model_path;
};

LocalAgentBackend *local_agent_backend_init(void) {
    return new LocalAgentBackend();
}

LocalAgentInferenceStatus local_agent_backend_load_model(
    LocalAgentBackend *backend,
    const char *model_path
) {
    if (backend == nullptr || model_path == nullptr) {
        return LOCAL_AGENT_INFERENCE_ERROR;
    }
    backend->model_path = model_path;
    backend->loaded = true;
    backend->cancelled = false;
    return LOCAL_AGENT_INFERENCE_OK;
}

LocalAgentInferenceStatus local_agent_backend_stream_chat(
    LocalAgentBackend *backend,
    const char *prompt_json,
    LocalAgentTokenCallback callback,
    void *user_data
) {
    if (backend == nullptr || prompt_json == nullptr || callback == nullptr || !backend->loaded) {
        return LOCAL_AGENT_INFERENCE_ERROR;
    }
    if (backend->cancelled) {
        return LOCAL_AGENT_INFERENCE_CANCELLED;
    }
    callback("mock ", user_data);
    if (backend->cancelled) {
        return LOCAL_AGENT_INFERENCE_CANCELLED;
    }
    callback("on-device response", user_data);
    return LOCAL_AGENT_INFERENCE_OK;
}

void local_agent_backend_cancel(LocalAgentBackend *backend) {
    if (backend != nullptr) {
        backend->cancelled = true;
    }
}

void local_agent_backend_release(LocalAgentBackend *backend) {
    delete backend;
}
```

- [ ] **Step 3: Create boundary docs**

Create `local-ios-agent/docs/model-providers/ondevice-minicpm-boundary.md`:

```markdown
# On-Device MiniCPM Boundary

The on-device provider boundary keeps inference concerns out of Rust runtime
state. C++ owns model loading, tensor preparation, KV cache, Metal resources,
streaming, cancellation, and release.

Rust calls a narrow backend interface:

```text
init
load_model(model_path)
stream_chat(prompt_json, token_callback)
cancel
release
```

The MVP uses a mock backend and a Rust trait adapter. Real llama.cpp / GGUF /
Metal integration must preserve this boundary.
```

- [ ] **Step 4: Verify mock backend compiles**

Run:

```bash
cd /Users/alexandercou/Projects/Alex-agent/local-ios-agent
clang++ -std=c++17 -I inference/include -c inference/mock/local_agent_inference_mock.cpp -o /tmp/local_agent_inference_mock.o
```

Expected: command exits 0.

- [ ] **Step 5: Commit**

```bash
cd /Users/alexandercou/Projects/Alex-agent
git add local-ios-agent/inference/include/local_agent_inference.h local-ios-agent/inference/mock/local_agent_inference_mock.cpp local-ios-agent/docs/model-providers/ondevice-minicpm-boundary.md
git commit -m "feat: add inference C ABI boundary"
```

## Task 2: Add Rust Backend Trait and Mock Backend

**Files:**
- Create: `local-ios-agent/rust-core/src/core/ondevice_minicpm.rs`
- Create: `local-ios-agent/rust-core/tests/ondevice_minicpm_provider.rs`
- Modify: `local-ios-agent/rust-core/src/core/mod.rs`

- [ ] **Step 1: Write failing backend lifecycle test**

Create `local-ios-agent/rust-core/tests/ondevice_minicpm_provider.rs`:

```rust
use local_ios_agent_runtime::core::{LocalInferenceBackend, MockLocalInferenceBackend};

#[test]
fn mock_local_backend_loads_streams_and_cancels() {
    let mut backend = MockLocalInferenceBackend::new();

    backend.load_model("/models/minicpm.gguf").unwrap();
    let first = backend.stream_chat(r#"{"messages":[]}"#).unwrap();
    backend.cancel();
    let cancelled = backend.stream_chat(r#"{"messages":[]}"#);

    assert_eq!(first, vec!["mock ".to_string(), "on-device response".to_string()]);
    assert!(cancelled.is_err());
}
```

- [ ] **Step 2: Run test to verify it fails**

Run:

```bash
cd /Users/alexandercou/Projects/Alex-agent/local-ios-agent/rust-core
cargo test --test ondevice_minicpm_provider mock_local_backend_loads_streams_and_cancels
```

Expected: FAIL because on-device backend types do not exist.

- [ ] **Step 3: Implement trait and mock backend**

Create `local-ios-agent/rust-core/src/core/ondevice_minicpm.rs`:

```rust
use crate::core::AgentError;

pub trait LocalInferenceBackend: Send + Sync {
    fn load_model(&mut self, model_path: &str) -> Result<(), AgentError>;
    fn stream_chat(&mut self, prompt_json: &str) -> Result<Vec<String>, AgentError>;
    fn cancel(&mut self);
}

#[derive(Clone, Debug, Default)]
pub struct MockLocalInferenceBackend {
    loaded_model: Option<String>,
    cancelled: bool,
}

impl MockLocalInferenceBackend {
    pub fn new() -> Self {
        Self::default()
    }
}

impl LocalInferenceBackend for MockLocalInferenceBackend {
    fn load_model(&mut self, model_path: &str) -> Result<(), AgentError> {
        self.loaded_model = Some(model_path.to_string());
        self.cancelled = false;
        Ok(())
    }

    fn stream_chat(&mut self, _prompt_json: &str) -> Result<Vec<String>, AgentError> {
        if self.loaded_model.is_none() {
            return Err(AgentError::Provider("local model is not loaded".into()));
        }
        if self.cancelled {
            return Err(AgentError::Cancelled("local inference cancelled".into()));
        }
        Ok(vec!["mock ".into(), "on-device response".into()])
    }

    fn cancel(&mut self) {
        self.cancelled = true;
    }
}
```

Modify `local-ios-agent/rust-core/src/core/mod.rs`:

```rust
pub mod ondevice_minicpm;
pub use ondevice_minicpm::{LocalInferenceBackend, MockLocalInferenceBackend};
```

- [ ] **Step 4: Run test to verify pass**

Run:

```bash
cd /Users/alexandercou/Projects/Alex-agent/local-ios-agent/rust-core
cargo fmt
cargo test --test ondevice_minicpm_provider mock_local_backend_loads_streams_and_cancels
```

Expected: PASS.

- [ ] **Step 5: Commit**

```bash
cd /Users/alexandercou/Projects/Alex-agent
git add local-ios-agent/rust-core/src/core/ondevice_minicpm.rs local-ios-agent/rust-core/src/core/mod.rs local-ios-agent/rust-core/tests/ondevice_minicpm_provider.rs
git commit -m "feat: add local inference backend trait"
```

## Task 3: Add OnDeviceMiniCPMProvider Adapter

**Files:**
- Modify: `local-ios-agent/rust-core/src/core/ondevice_minicpm.rs`
- Modify: `local-ios-agent/rust-core/tests/ondevice_minicpm_provider.rs`
- Modify: `local-ios-agent/rust-core/src/core/mod.rs`

- [ ] **Step 1: Add failing provider adapter test**

Append to `local-ios-agent/rust-core/tests/ondevice_minicpm_provider.rs`:

```rust
use std::sync::{Arc, Mutex};

use local_ios_agent_runtime::context::{PromptFrame, PromptMessage};
use local_ios_agent_runtime::core::{
    ModelProvider, ModelProviderOutput, OnDeviceMiniCPMProvider,
};

#[test]
fn ondevice_provider_maps_backend_tokens_to_model_outputs() {
    let backend = Arc::new(Mutex::new(MockLocalInferenceBackend::new()));
    backend.lock().unwrap().load_model("/models/minicpm.gguf").unwrap();
    let provider = OnDeviceMiniCPMProvider::new("on-device-minicpm", "MiniCPM-V-4.6", backend);
    let frame = PromptFrame {
        system_prompt: "system".into(),
        runtime_policy: "policy".into(),
        tool_schemas: Vec::new(),
        messages: vec![PromptMessage::User("hello".into())],
    };

    let outputs = provider.stream_chat(&frame).unwrap();

    assert_eq!(provider.id(), "on-device-minicpm");
    assert_eq!(outputs, vec![
        ModelProviderOutput::TextDelta("mock ".into()),
        ModelProviderOutput::TextDelta("on-device response".into()),
        ModelProviderOutput::Completed("mock on-device response".into())
    ]);
}
```

- [ ] **Step 2: Run test to verify it fails**

Run:

```bash
cd /Users/alexandercou/Projects/Alex-agent/local-ios-agent/rust-core
cargo test --test ondevice_minicpm_provider ondevice_provider_maps_backend_tokens_to_model_outputs
```

Expected: FAIL because `OnDeviceMiniCPMProvider` does not exist.

- [ ] **Step 3: Implement provider adapter**

Append to `local-ios-agent/rust-core/src/core/ondevice_minicpm.rs`:

```rust
use std::sync::{Arc, Mutex};

use crate::context::PromptFrame;
use crate::core::{openai_chat_request_json, ModelProvider, ModelProviderOutput};

pub struct OnDeviceMiniCPMProvider<B: LocalInferenceBackend> {
    id: String,
    model_id: String,
    backend: Arc<Mutex<B>>,
}

impl<B: LocalInferenceBackend> OnDeviceMiniCPMProvider<B> {
    pub fn new(id: impl Into<String>, model_id: impl Into<String>, backend: Arc<Mutex<B>>) -> Self {
        Self {
            id: id.into(),
            model_id: model_id.into(),
            backend,
        }
    }
}

impl<B: LocalInferenceBackend> ModelProvider for OnDeviceMiniCPMProvider<B> {
    fn id(&self) -> &str {
        &self.id
    }

    fn stream_chat(&self, frame: &PromptFrame) -> Result<Vec<ModelProviderOutput>, AgentError> {
        let prompt_json = openai_chat_request_json(&self.model_id, frame)?;
        let tokens = self
            .backend
            .lock()
            .map_err(|_| AgentError::Provider("local backend lock poisoned".into()))?
            .stream_chat(&prompt_json)?;
        let mut outputs = tokens
            .iter()
            .cloned()
            .map(ModelProviderOutput::TextDelta)
            .collect::<Vec<_>>();
        outputs.push(ModelProviderOutput::Completed(tokens.join("")));
        Ok(outputs)
    }
}
```

Modify `local-ios-agent/rust-core/src/core/mod.rs` export:

```rust
pub use ondevice_minicpm::{LocalInferenceBackend, MockLocalInferenceBackend, OnDeviceMiniCPMProvider};
```

- [ ] **Step 4: Run tests to verify pass**

Run:

```bash
cd /Users/alexandercou/Projects/Alex-agent/local-ios-agent/rust-core
cargo fmt
cargo test --test ondevice_minicpm_provider
cargo test
```

Expected: PASS.

- [ ] **Step 5: Commit**

```bash
cd /Users/alexandercou/Projects/Alex-agent
git add local-ios-agent/rust-core/src/core/ondevice_minicpm.rs local-ios-agent/rust-core/src/core/mod.rs local-ios-agent/rust-core/tests/ondevice_minicpm_provider.rs
git commit -m "feat: add on-device provider adapter"
```

## Self-Review

Spec coverage:

- C++ boundary is narrow and inference-only.
- Rust provider adapter uses existing `ModelProvider` output types.
- Resource lifecycle is modeled through load, stream, cancel, and release.
- No session, memory, tool, security, or UI logic enters C++.

Placeholder scan:

- No placeholder terms are used as implementation instructions.

Type consistency:

- `OnDeviceMiniCPMProvider` consumes the same prompt adapter used by Desktop
  MiniCPM and emits the same `ModelProviderOutput` variants.
