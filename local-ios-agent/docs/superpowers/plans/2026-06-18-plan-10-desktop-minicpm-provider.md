# Plan 10: Desktop MiniCPM Provider + Provider Selection Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add provider selection and a Desktop MiniCPM provider that can call a Mac-local OpenAI-compatible HTTP endpoint from simulator-oriented development builds.

**Architecture:** Rust owns model provider selection through provider profiles and a registry. Desktop MiniCPM is implemented as a `ModelProvider` backed by a small injectable HTTP transport so request/response behavior can be tested without a live model server.

**Tech Stack:** Rust 2021, existing `ModelProvider`, existing `PromptFrame`, standard library HTTP-over-localhost transport, `serde_json`, `cargo test`, TDD.

---

## Current Code Audit

Checked current code with:

```bash
sed -n '1,180p' local-ios-agent/rust-core/src/core/provider.rs
sed -n '1,180p' local-ios-agent/rust-core/src/context/prompt_frame.rs
sed -n '1,120p' local-ios-agent/rust-core/src/memory/provider_settings.rs
```

Observed:

- `ModelProvider` currently exposes `id()` and `stream_chat(&PromptFrame)`.
- `MockStreamingProvider` is deterministic and already used by runtime tests.
- `TokenizerAdapter` exists separately in `context`.
- `ProviderSetting` exists in memory but no provider registry or active provider
  selector exists.
- There is no Desktop MiniCPM provider and no OpenAI-compatible request adapter.

Assigned to this plan:

- Add provider profile/config types.
- Add provider registry and active selection logic.
- Add OpenAI-compatible chat request and response adapter.
- Add `DesktopMiniCPMProvider` using an injectable transport.
- Add a minimal local HTTP transport for `http://127.0.0.1` endpoints.
- Add runbook docs for serving MiniCPM locally.

Deferred:

- Multimodal image payloads.
- True streaming token-by-token SSE integration.
- On-device C++ backend.
- Swift settings UI.

## File Structure

Create:

```text
local-ios-agent/rust-core/src/core/provider_profile.rs
local-ios-agent/rust-core/src/core/provider_registry.rs
local-ios-agent/rust-core/src/core/openai_chat.rs
local-ios-agent/rust-core/src/core/desktop_minicpm.rs
local-ios-agent/rust-core/tests/provider_registry.rs
local-ios-agent/rust-core/tests/openai_chat_adapter.rs
local-ios-agent/rust-core/tests/desktop_minicpm_provider.rs
local-ios-agent/docs/model-providers/desktop-minicpm.md
```

Modify:

```text
local-ios-agent/rust-core/src/core/mod.rs
```

## Task 1: Add Provider Profile and Registry

**Files:**
- Create: `local-ios-agent/rust-core/src/core/provider_profile.rs`
- Create: `local-ios-agent/rust-core/src/core/provider_registry.rs`
- Create: `local-ios-agent/rust-core/tests/provider_registry.rs`
- Modify: `local-ios-agent/rust-core/src/core/mod.rs`

- [ ] **Step 1: Write failing provider registry tests**

Create `local-ios-agent/rust-core/tests/provider_registry.rs`:

```rust
use local_ios_agent_runtime::core::{ProviderKind, ProviderProfile, ProviderRegistry};

#[test]
fn provider_registry_selects_active_profile() {
    let mut registry = ProviderRegistry::new();
    registry.register(ProviderProfile {
        id: "mock".into(),
        display_name: "Mock".into(),
        kind: ProviderKind::Mock,
        model_id: "mock".into(),
        endpoint: None,
        max_context_tokens: 2048,
    }).unwrap();
    registry.register(ProviderProfile {
        id: "desktop-minicpm".into(),
        display_name: "Desktop MiniCPM".into(),
        kind: ProviderKind::DesktopMiniCPM,
        model_id: "MiniCPM-V-4.6".into(),
        endpoint: Some("http://127.0.0.1:8000/v1/chat/completions".into()),
        max_context_tokens: 8192,
    }).unwrap();

    registry.select("desktop-minicpm").unwrap();

    assert_eq!(registry.active().unwrap().id, "desktop-minicpm");
    assert_eq!(registry.profiles().len(), 2);
}

#[test]
fn provider_registry_rejects_duplicate_ids() {
    let mut registry = ProviderRegistry::new();
    let profile = ProviderProfile {
        id: "mock".into(),
        display_name: "Mock".into(),
        kind: ProviderKind::Mock,
        model_id: "mock".into(),
        endpoint: None,
        max_context_tokens: 2048,
    };

    registry.register(profile.clone()).unwrap();
    assert!(registry.register(profile).is_err());
}
```

- [ ] **Step 2: Run test to verify it fails**

Run:

```bash
cd /Users/alexandercou/Projects/Alex-agent/local-ios-agent/rust-core
cargo test --test provider_registry
```

Expected: FAIL because provider registry types do not exist.

- [ ] **Step 3: Implement provider profile and registry**

Create `local-ios-agent/rust-core/src/core/provider_profile.rs`:

```rust
#[derive(Clone, Debug, Eq, PartialEq)]
pub enum ProviderKind {
    Mock,
    DesktopMiniCPM,
    OnDeviceMiniCPM,
}

#[derive(Clone, Debug, Eq, PartialEq)]
pub struct ProviderProfile {
    pub id: String,
    pub display_name: String,
    pub kind: ProviderKind,
    pub model_id: String,
    pub endpoint: Option<String>,
    pub max_context_tokens: usize,
}
```

Create `local-ios-agent/rust-core/src/core/provider_registry.rs`:

```rust
use std::collections::HashMap;

use crate::core::{AgentError, ProviderProfile};

#[derive(Clone, Debug, Default)]
pub struct ProviderRegistry {
    profiles: HashMap<String, ProviderProfile>,
    active_id: Option<String>,
}

impl ProviderRegistry {
    pub fn new() -> Self {
        Self::default()
    }

    pub fn register(&mut self, profile: ProviderProfile) -> Result<(), AgentError> {
        if self.profiles.contains_key(&profile.id) {
            return Err(AgentError::Provider(format!(
                "provider already registered: {}",
                profile.id
            )));
        }
        if self.active_id.is_none() {
            self.active_id = Some(profile.id.clone());
        }
        self.profiles.insert(profile.id.clone(), profile);
        Ok(())
    }

    pub fn select(&mut self, id: &str) -> Result<(), AgentError> {
        if !self.profiles.contains_key(id) {
            return Err(AgentError::Provider(format!("unknown provider: {id}")));
        }
        self.active_id = Some(id.to_string());
        Ok(())
    }

    pub fn active(&self) -> Option<&ProviderProfile> {
        self.active_id
            .as_ref()
            .and_then(|id| self.profiles.get(id))
    }

    pub fn profiles(&self) -> Vec<ProviderProfile> {
        let mut profiles: Vec<_> = self.profiles.values().cloned().collect();
        profiles.sort_by(|left, right| left.id.cmp(&right.id));
        profiles
    }
}
```

Modify `local-ios-agent/rust-core/src/core/mod.rs`:

```rust
pub mod provider_profile;
pub mod provider_registry;

pub use provider_profile::{ProviderKind, ProviderProfile};
pub use provider_registry::ProviderRegistry;
```

- [ ] **Step 4: Run tests to verify pass**

Run:

```bash
cd /Users/alexandercou/Projects/Alex-agent/local-ios-agent/rust-core
cargo fmt
cargo test --test provider_registry
```

Expected: PASS.

- [ ] **Step 5: Commit**

```bash
cd /Users/alexandercou/Projects/Alex-agent
git add local-ios-agent/rust-core/src/core/provider_profile.rs local-ios-agent/rust-core/src/core/provider_registry.rs local-ios-agent/rust-core/src/core/mod.rs local-ios-agent/rust-core/tests/provider_registry.rs
git commit -m "feat: add provider registry"
```

## Task 2: Add OpenAI-Compatible Chat Adapter

**Files:**
- Create: `local-ios-agent/rust-core/src/core/openai_chat.rs`
- Create: `local-ios-agent/rust-core/tests/openai_chat_adapter.rs`
- Modify: `local-ios-agent/rust-core/src/core/mod.rs`

- [ ] **Step 1: Write failing adapter tests**

Create `local-ios-agent/rust-core/tests/openai_chat_adapter.rs`:

```rust
use local_ios_agent_runtime::context::{PromptFrame, PromptMessage};
use local_ios_agent_runtime::core::{openai_chat_request_json, parse_openai_chat_response};

#[test]
fn openai_chat_request_includes_messages_and_model() {
    let frame = PromptFrame {
        system_prompt: "system".into(),
        runtime_policy: "policy".into(),
        tool_schemas: vec!["debug.echo".into()],
        messages: vec![PromptMessage::User("hello".into())],
    };

    let request = openai_chat_request_json("MiniCPM-V-4.6", &frame).unwrap();

    assert!(request.contains(r#""model":"MiniCPM-V-4.6""#));
    assert!(request.contains(r#""role":"system""#));
    assert!(request.contains(r#""role":"user""#));
}

#[test]
fn openai_chat_response_parses_text_completion() {
    let response = r#"{"choices":[{"message":{"content":"hello from model"}}]}"#;

    let text = parse_openai_chat_response(response).unwrap();

    assert_eq!(text, "hello from model");
}
```

- [ ] **Step 2: Run test to verify it fails**

Run:

```bash
cd /Users/alexandercou/Projects/Alex-agent/local-ios-agent/rust-core
cargo test --test openai_chat_adapter
```

Expected: FAIL because adapter functions do not exist.

- [ ] **Step 3: Implement adapter**

Create `local-ios-agent/rust-core/src/core/openai_chat.rs`:

```rust
use serde_json::{json, Value};

use crate::context::{PromptFrame, PromptMessage};
use crate::core::AgentError;

pub fn openai_chat_request_json(model_id: &str, frame: &PromptFrame) -> Result<String, AgentError> {
    let mut messages = Vec::new();
    messages.push(json!({
        "role": "system",
        "content": format!("{}\n\n{}", frame.system_prompt, frame.runtime_policy)
    }));

    if !frame.tool_schemas.is_empty() {
        messages.push(json!({
            "role": "system",
            "content": format!("Available tools:\n{}", frame.tool_schemas.join("\n"))
        }));
    }

    for message in &frame.messages {
        match message {
            PromptMessage::User(content) => messages.push(json!({ "role": "user", "content": content })),
            PromptMessage::Assistant(content) => messages.push(json!({ "role": "assistant", "content": content })),
            PromptMessage::ToolResult(content) => messages.push(json!({ "role": "tool", "content": content })),
        }
    }

    Ok(json!({
        "model": model_id,
        "messages": messages,
        "stream": false
    }).to_string())
}

pub fn parse_openai_chat_response(response: &str) -> Result<String, AgentError> {
    let value: Value = serde_json::from_str(response)
        .map_err(|error| AgentError::Provider(format!("invalid chat response json: {error}")))?;
    value
        .get("choices")
        .and_then(Value::as_array)
        .and_then(|choices| choices.first())
        .and_then(|choice| choice.get("message"))
        .and_then(|message| message.get("content"))
        .and_then(Value::as_str)
        .map(str::to_string)
        .ok_or_else(|| AgentError::Provider("chat response missing choices[0].message.content".into()))
}
```

Modify `local-ios-agent/rust-core/src/core/mod.rs`:

```rust
pub mod openai_chat;
pub use openai_chat::{openai_chat_request_json, parse_openai_chat_response};
```

- [ ] **Step 4: Run tests to verify pass**

Run:

```bash
cd /Users/alexandercou/Projects/Alex-agent/local-ios-agent/rust-core
cargo fmt
cargo test --test openai_chat_adapter
```

Expected: PASS.

- [ ] **Step 5: Commit**

```bash
cd /Users/alexandercou/Projects/Alex-agent
git add local-ios-agent/rust-core/src/core/openai_chat.rs local-ios-agent/rust-core/src/core/mod.rs local-ios-agent/rust-core/tests/openai_chat_adapter.rs
git commit -m "feat: add OpenAI chat adapter"
```

## Task 3: Add Desktop MiniCPM Provider with Injectable Transport

**Files:**
- Create: `local-ios-agent/rust-core/src/core/desktop_minicpm.rs`
- Create: `local-ios-agent/rust-core/tests/desktop_minicpm_provider.rs`
- Modify: `local-ios-agent/rust-core/src/core/mod.rs`

- [ ] **Step 1: Write failing provider test**

Create `local-ios-agent/rust-core/tests/desktop_minicpm_provider.rs`:

```rust
use std::sync::{Arc, Mutex};

use local_ios_agent_runtime::context::{PromptFrame, PromptMessage};
use local_ios_agent_runtime::core::{
    DesktopMiniCPMProvider, HttpChatTransport, ModelProvider, ModelProviderOutput,
};

#[derive(Clone, Default)]
struct CaptureTransport {
    requests: Arc<Mutex<Vec<String>>>,
}

impl HttpChatTransport for CaptureTransport {
    fn post_json(&self, _endpoint: &str, body: &str) -> Result<String, local_ios_agent_runtime::core::AgentError> {
        self.requests.lock().unwrap().push(body.to_string());
        Ok(r#"{"choices":[{"message":{"content":"desktop response"}}]}"#.into())
    }
}

#[test]
fn desktop_minicpm_provider_maps_response_to_provider_outputs() {
    let transport = CaptureTransport::default();
    let provider = DesktopMiniCPMProvider::new(
        "desktop-minicpm",
        "MiniCPM-V-4.6",
        "http://127.0.0.1:8000/v1/chat/completions",
        transport.clone(),
    );
    let frame = PromptFrame {
        system_prompt: "system".into(),
        runtime_policy: "policy".into(),
        tool_schemas: Vec::new(),
        messages: vec![PromptMessage::User("hello".into())],
    };

    let outputs = provider.stream_chat(&frame).unwrap();

    assert_eq!(provider.id(), "desktop-minicpm");
    assert_eq!(transport.requests.lock().unwrap().len(), 1);
    assert_eq!(outputs, vec![
        ModelProviderOutput::TextDelta("desktop response".into()),
        ModelProviderOutput::Completed("desktop response".into())
    ]);
}
```

- [ ] **Step 2: Run test to verify it fails**

Run:

```bash
cd /Users/alexandercou/Projects/Alex-agent/local-ios-agent/rust-core
cargo test --test desktop_minicpm_provider
```

Expected: FAIL because `DesktopMiniCPMProvider` does not exist.

- [ ] **Step 3: Implement provider**

Create `local-ios-agent/rust-core/src/core/desktop_minicpm.rs`:

```rust
use crate::context::PromptFrame;
use crate::core::{
    openai_chat_request_json, parse_openai_chat_response, AgentError, ModelProvider,
    ModelProviderOutput,
};

pub trait HttpChatTransport: Clone + Send + Sync + 'static {
    fn post_json(&self, endpoint: &str, body: &str) -> Result<String, AgentError>;
}

#[derive(Clone)]
pub struct DesktopMiniCPMProvider<T: HttpChatTransport> {
    id: String,
    model_id: String,
    endpoint: String,
    transport: T,
}

impl<T: HttpChatTransport> DesktopMiniCPMProvider<T> {
    pub fn new(
        id: impl Into<String>,
        model_id: impl Into<String>,
        endpoint: impl Into<String>,
        transport: T,
    ) -> Self {
        Self {
            id: id.into(),
            model_id: model_id.into(),
            endpoint: endpoint.into(),
            transport,
        }
    }
}

impl<T: HttpChatTransport> ModelProvider for DesktopMiniCPMProvider<T> {
    fn id(&self) -> &str {
        &self.id
    }

    fn stream_chat(&self, frame: &PromptFrame) -> Result<Vec<ModelProviderOutput>, AgentError> {
        let request = openai_chat_request_json(&self.model_id, frame)?;
        let response = self.transport.post_json(&self.endpoint, &request)?;
        let text = parse_openai_chat_response(&response)?;
        Ok(vec![
            ModelProviderOutput::TextDelta(text.clone()),
            ModelProviderOutput::Completed(text),
        ])
    }
}
```

Modify `local-ios-agent/rust-core/src/core/mod.rs`:

```rust
pub mod desktop_minicpm;
pub use desktop_minicpm::{DesktopMiniCPMProvider, HttpChatTransport};
```

- [ ] **Step 4: Run tests to verify pass**

Run:

```bash
cd /Users/alexandercou/Projects/Alex-agent/local-ios-agent/rust-core
cargo fmt
cargo test --test desktop_minicpm_provider
```

Expected: PASS.

- [ ] **Step 5: Commit**

```bash
cd /Users/alexandercou/Projects/Alex-agent
git add local-ios-agent/rust-core/src/core/desktop_minicpm.rs local-ios-agent/rust-core/src/core/mod.rs local-ios-agent/rust-core/tests/desktop_minicpm_provider.rs
git commit -m "feat: add Desktop MiniCPM provider"
```

## Task 4: Add Localhost HTTP Transport and Runbook

**Files:**
- Modify: `local-ios-agent/rust-core/src/core/desktop_minicpm.rs`
- Modify: `local-ios-agent/rust-core/tests/desktop_minicpm_provider.rs`
- Create: `local-ios-agent/docs/model-providers/desktop-minicpm.md`

- [ ] **Step 1: Add failing localhost transport test**

Append to `local-ios-agent/rust-core/tests/desktop_minicpm_provider.rs`:

```rust
use std::io::{Read, Write};
use std::net::TcpListener;
use std::thread;

use local_ios_agent_runtime::core::LocalhostHttpTransport;

#[test]
fn localhost_transport_posts_json_to_local_server() {
    let listener = TcpListener::bind("127.0.0.1:0").unwrap();
    let address = listener.local_addr().unwrap();
    let server = thread::spawn(move || {
        let (mut stream, _) = listener.accept().unwrap();
        let mut request = String::new();
        stream.read_to_string(&mut request).ok();
        let body = r#"{"choices":[{"message":{"content":"ok"}}]}"#;
        let response = format!(
            "HTTP/1.1 200 OK\r\nContent-Length: {}\r\nContent-Type: application/json\r\n\r\n{}",
            body.len(),
            body
        );
        stream.write_all(response.as_bytes()).unwrap();
    });

    let transport = LocalhostHttpTransport;
    let response = transport
        .post_json(
            &format!("http://{}/v1/chat/completions", address),
            r#"{"model":"MiniCPM-V-4.6","messages":[]}"#,
        )
        .unwrap();

    server.join().unwrap();
    assert!(response.contains("ok"));
}
```

- [ ] **Step 2: Run test to verify it fails**

Run:

```bash
cd /Users/alexandercou/Projects/Alex-agent/local-ios-agent/rust-core
cargo test --test desktop_minicpm_provider localhost_transport_posts_json_to_local_server
```

Expected: FAIL because `LocalhostHttpTransport` does not exist.

- [ ] **Step 3: Implement localhost transport**

Append to `local-ios-agent/rust-core/src/core/desktop_minicpm.rs`:

```rust
use std::io::{Read, Write};
use std::net::TcpStream;

#[derive(Clone, Debug, Default)]
pub struct LocalhostHttpTransport;

impl HttpChatTransport for LocalhostHttpTransport {
    fn post_json(&self, endpoint: &str, body: &str) -> Result<String, AgentError> {
        let parsed = LocalHttpEndpoint::parse(endpoint)?;
        let mut stream = TcpStream::connect((parsed.host.as_str(), parsed.port))
            .map_err(|error| AgentError::Provider(format!("connect failed: {error}")))?;
        let request = format!(
            "POST {} HTTP/1.1\r\nHost: {}\r\nContent-Type: application/json\r\nContent-Length: {}\r\nConnection: close\r\n\r\n{}",
            parsed.path,
            parsed.host,
            body.as_bytes().len(),
            body
        );
        stream
            .write_all(request.as_bytes())
            .map_err(|error| AgentError::Provider(format!("write failed: {error}")))?;
        let mut response = String::new();
        stream
            .read_to_string(&mut response)
            .map_err(|error| AgentError::Provider(format!("read failed: {error}")))?;
        response
            .split("\r\n\r\n")
            .nth(1)
            .map(str::to_string)
            .ok_or_else(|| AgentError::Provider("http response missing body".into()))
    }
}

struct LocalHttpEndpoint {
    host: String,
    port: u16,
    path: String,
}

impl LocalHttpEndpoint {
    fn parse(endpoint: &str) -> Result<Self, AgentError> {
        let rest = endpoint
            .strip_prefix("http://")
            .ok_or_else(|| AgentError::Provider("only http:// local endpoints are supported".into()))?;
        let (authority, path) = rest
            .split_once('/')
            .ok_or_else(|| AgentError::Provider("endpoint missing path".into()))?;
        let (host, port) = authority
            .split_once(':')
            .ok_or_else(|| AgentError::Provider("endpoint missing port".into()))?;
        if host != "127.0.0.1" && host != "localhost" {
            return Err(AgentError::Provider("desktop provider only allows localhost endpoints".into()));
        }
        let port = port
            .parse::<u16>()
            .map_err(|error| AgentError::Provider(format!("invalid endpoint port: {error}")))?;
        Ok(Self {
            host: host.to_string(),
            port,
            path: format!("/{path}"),
        })
    }
}
```

Modify `local-ios-agent/rust-core/src/core/mod.rs` export:

```rust
pub use desktop_minicpm::{DesktopMiniCPMProvider, HttpChatTransport, LocalhostHttpTransport};
```

Create `local-ios-agent/docs/model-providers/desktop-minicpm.md`:

```markdown
# Desktop MiniCPM Provider Runbook

The MVP Desktop MiniCPM provider calls a Mac-local OpenAI-compatible endpoint
from simulator-oriented development builds.

Default endpoint:

```text
http://127.0.0.1:8000/v1/chat/completions
```

Required response shape:

```json
{
  "choices": [
    {
      "message": {
        "content": "assistant text"
      }
    }
  ]
}
```

Smoke test:

```bash
curl -sS http://127.0.0.1:8000/v1/chat/completions \
  -H 'Content-Type: application/json' \
  -d '{"model":"MiniCPM-V-4.6","messages":[{"role":"user","content":"hello"}],"stream":false}'
```

The transport intentionally accepts only `http://127.0.0.1` or
`http://localhost` endpoints for MVP development.
```

- [ ] **Step 4: Run tests to verify pass**

Run:

```bash
cd /Users/alexandercou/Projects/Alex-agent/local-ios-agent/rust-core
cargo fmt
cargo test --test desktop_minicpm_provider
cargo test
```

Expected: PASS.

- [ ] **Step 5: Commit**

```bash
cd /Users/alexandercou/Projects/Alex-agent
git add local-ios-agent/rust-core/src/core/desktop_minicpm.rs local-ios-agent/rust-core/src/core/mod.rs local-ios-agent/rust-core/tests/desktop_minicpm_provider.rs local-ios-agent/docs/model-providers/desktop-minicpm.md
git commit -m "feat: add local MiniCPM HTTP transport"
```

## Self-Review

Spec coverage:

- Provider registry supports active provider selection.
- Desktop MiniCPM provider is a `ModelProvider`.
- OpenAI-compatible text response path is covered by tests.
- Local endpoint runbook is documented.

Placeholder scan:

- No placeholder terms are used as implementation instructions.

Type consistency:

- `ProviderProfile.kind` values match the provider types planned for MVP.
- `DesktopMiniCPMProvider` returns existing `ModelProviderOutput` variants.
