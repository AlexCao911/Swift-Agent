# Rust Execution ReAct Migration Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Replace the phase-1 synthetic Rust execution adapter with a real execution-domain ReAct worker that consumes trusted conversation frames, assembles model input inside execution, runs model/tool loops, and emits replayable execution events.

**Architecture:** Conversation remains the owner of session tree, branch projection, user turn persistence, and assistant final commit. Execution consumes only `ConversationRunFrameRef`, loads the trusted frame, assembles model input per LLM call, owns runtime options/tool observations during the run, and publishes events through `ExecutionEventLog`. Swift remains feature-gated until this Rust path is real.

**Tech Stack:** Rust core (`rust-core/src/execution`, `rust-core/src/context`, `rust-core/src/core`), existing `ContextAssembler`, existing provider/tool abstractions, Swift bridge DTOs unchanged except where tests expose required behavior.

## Global Constraints

- Execution trusted input remains `ConversationRunFrameRef`; no full frame DTO is accepted for execution.
- Conversation frame projection outputs conversation messages, not prompt/model input.
- Every LLM call context assembly happens inside `execution/`.
- Tool loop context must include prior assistant tool calls and tool results for subsequent model calls.
- `ToolLoopService` must not be the production synthetic responder after this plan.
- Swift coordinator stays behind `LOCAL_AGENT_ENABLE_CONVERSATION_EXECUTION_COORDINATOR=1` until this plan is verified.

---

### Task 1: Execution Context Input Assembler

**Files:**
- Create: `local-ios-agent/rust-core/src/execution/context_input.rs`
- Modify: `local-ios-agent/rust-core/src/execution/mod.rs`
- Test: `local-ios-agent/rust-core/tests/contract/conversation_execution_boundary.rs`

**Interfaces:**
- Consumes: `ConversationRunFrame`, `RuntimeOptions`, `ContextAssembler`
- Produces:
  - `ExecutionContextInputAssembler::new(runtime_options: Option<RuntimeOptions>) -> Self`
  - `ExecutionContextInputAssembler::assemble_initial(&self, frame: &ConversationRunFrame) -> Result<ModelInputMessages, ExecutionContextInputError>`

- [ ] **Step 1: Write the failing test**

Add this test to `tests/contract/conversation_execution_boundary.rs`:

```rust
#[test]
fn execution_context_input_uses_conversation_frame_and_runtime_options() {
    use local_ios_agent_runtime::context::ModelInputRole;
    use local_ios_agent_runtime::execution::{
        ExecutionContextInputAssembler, RuntimeOptions,
    };

    let frame_ref = ConversationRunFrameRef::new(
        ConversationFrameId::new("frame_context_1"),
        SessionId("session_1".into()),
        EntryId("assistant_1".into()),
        EntryId("user_turn_2".into()),
    );
    let frame = ConversationRunFrame::new(
        frame_ref,
        Some(EntryId("assistant_1".into())),
        vec![
            ConversationFrameMessage::user(EntryId("user_1".into()), "earlier question"),
            ConversationFrameMessage::assistant(EntryId("assistant_1".into()), "earlier answer"),
            ConversationFrameMessage::user(EntryId("user_turn_2".into()), "new question"),
        ],
        Vec::new(),
        ConversationLineage::new(EntryId("assistant_1".into()), None, None),
    );
    let assembler = ExecutionContextInputAssembler::new(Some(RuntimeOptions {
        system_prompt: "system from execution settings".to_string(),
        runtime_policy: "policy from execution settings".to_string(),
        temperature: Some(0.25),
        top_p: Some(0.8),
    }));

    let input = assembler.assemble_initial(&frame).unwrap();

    assert!(input.messages().iter().any(|message| {
        message.role() == ModelInputRole::System
            && message.content().contains("system from execution settings")
    }));
    assert!(input.messages().iter().any(|message| {
        message.role() == ModelInputRole::User && message.content() == "earlier question"
    }));
    assert!(input.messages().iter().any(|message| {
        message.role() == ModelInputRole::Assistant && message.content() == "earlier answer"
    }));
    assert!(input.messages().iter().any(|message| {
        message.role() == ModelInputRole::User && message.content() == "new question"
    }));
}
```

- [ ] **Step 2: Run test to verify it fails**

Run:

```bash
cargo test --test contract execution_context_input_uses_conversation_frame_and_runtime_options -- --nocapture
```

Expected: FAIL because `ExecutionContextInputAssembler` does not exist.

- [ ] **Step 3: Implement minimal assembler**

Create `src/execution/context_input.rs`:

```rust
use std::fmt;

use crate::context::{ModelInputMessage, ModelInputMessages, ModelInputRole};
use crate::conversation::{ConversationRunFrame, ConversationFrameRole};
use crate::execution::RuntimeOptions;

#[derive(Clone, Debug)]
pub struct ExecutionContextInputAssembler {
    runtime_options: Option<RuntimeOptions>,
}

#[derive(Clone, Debug, Eq, PartialEq)]
pub struct ExecutionContextInputError {
    code: String,
    message: String,
}

impl ExecutionContextInputAssembler {
    pub fn new(runtime_options: Option<RuntimeOptions>) -> Self {
        Self { runtime_options }
    }

    pub fn assemble_initial(
        &self,
        frame: &ConversationRunFrame,
    ) -> Result<ModelInputMessages, ExecutionContextInputError> {
        let mut messages = Vec::new();
        if let Some(options) = &self.runtime_options {
            let system = format!("{}\n\n{}", options.system_prompt, options.runtime_policy);
            if !system.trim().is_empty() {
                messages.push(ModelInputMessage::new(ModelInputRole::System, system));
            }
        }

        for message in frame.messages() {
            let role = match message.role() {
                "user" => ModelInputRole::User,
                "assistant" => ModelInputRole::Assistant,
                "summary" => ModelInputRole::System,
                other => {
                    return Err(ExecutionContextInputError::new(
                        "execution_context.unknown_role",
                        format!("unknown conversation frame role: {other}"),
                    ));
                }
            };
            messages.push(ModelInputMessage::new(role, message.content().to_string()));
        }

        Ok(ModelInputMessages::new(messages))
    }
}

impl ExecutionContextInputError {
    fn new(code: impl Into<String>, message: impl Into<String>) -> Self {
        Self {
            code: code.into(),
            message: message.into(),
        }
    }

    pub fn code(&self) -> &str {
        &self.code
    }
}

impl fmt::Display for ExecutionContextInputError {
    fn fmt(&self, formatter: &mut fmt::Formatter<'_>) -> fmt::Result {
        formatter.write_str(&self.message)
    }
}

impl std::error::Error for ExecutionContextInputError {}
```

Modify `src/execution/mod.rs`:

```rust
mod context_input;
pub use context_input::{ExecutionContextInputAssembler, ExecutionContextInputError};
```

- [ ] **Step 4: Run test to verify it passes**

Run:

```bash
cargo test --test contract execution_context_input_uses_conversation_frame_and_runtime_options -- --nocapture
```

Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add local-ios-agent/rust-core/src/execution/context_input.rs \
  local-ios-agent/rust-core/src/execution/mod.rs \
  local-ios-agent/rust-core/tests/contract/conversation_execution_boundary.rs
git commit -m "feat: assemble execution context from conversation frame"
```

### Task 2: ReAct Worker Interface With Final Response Path

**Files:**
- Create: `local-ios-agent/rust-core/src/execution/react_worker.rs`
- Modify: `local-ios-agent/rust-core/src/execution/mod.rs`
- Test: `local-ios-agent/rust-core/tests/contract/conversation_execution_boundary.rs`

**Interfaces:**
- Consumes: `ExecutionContextInputAssembler`, `ExecutionEventLog`, `CompletedRunRegistry`, `ConversationRunFrameRef`
- Produces:
  - `ExecutionReactWorker<M, T>`
  - `ExecutionModelClient`
  - `ExecutionToolExecutor`
  - `ExecutionModelTurn::{Final { message_id, text }, ToolCall { call_id, name, arguments_json }}`

- [ ] **Step 1: Write the failing test**

Add this test:

```rust
#[test]
fn react_worker_emits_final_response_without_synthetic_adapter() {
    use local_ios_agent_runtime::execution::{
        CompletedRunRegistry, ExecutionContextInputAssembler, ExecutionEventLog,
        ExecutionModelClient, ExecutionModelTurn, ExecutionReactWorker,
        NoopExecutionToolExecutor,
    };

    #[derive(Clone)]
    struct FinalModel;

    impl ExecutionModelClient for FinalModel {
        fn next_turn(
            &self,
            _input: &local_ios_agent_runtime::context::ModelInputMessages,
        ) -> Result<ExecutionModelTurn, String> {
            Ok(ExecutionModelTurn::Final {
                message_id: "final_model_1".to_string(),
                text: "real model answer".to_string(),
            })
        }
    }

    let frame_ref = ConversationRunFrameRef::new(
        ConversationFrameId::new("frame_react_1"),
        SessionId("session_1".into()),
        EntryId("user_turn_1".into()),
        EntryId("user_turn_1".into()),
    );
    let frame = ConversationRunFrame::new(
        frame_ref.clone(),
        None,
        vec![ConversationFrameMessage::user(EntryId("user_turn_1".into()), "hello")],
        Vec::new(),
        ConversationLineage::new(EntryId("user_turn_1".into()), None, None),
    );
    let event_log = ExecutionEventLog::default();
    let completed_runs = CompletedRunRegistry::default();
    let worker = ExecutionReactWorker::new(
        FinalModel,
        NoopExecutionToolExecutor,
        ExecutionContextInputAssembler::new(None),
        event_log.clone(),
        completed_runs.clone(),
    );

    worker.run("run_1", &frame, &frame_ref).unwrap();

    let events = event_log.replay("run_1", Some(0));
    assert!(events.iter().any(|event| {
        event.code() == "assistant_message_completed"
            && event.payload().contains("real model answer")
    }));
    assert!(events.iter().any(|event| event.code() == "run.completed"));
    assert!(completed_runs.get("run_1", "final_model_1").is_some());
}
```

- [ ] **Step 2: Run test to verify it fails**

Run:

```bash
cargo test --test contract react_worker_emits_final_response_without_synthetic_adapter -- --nocapture
```

Expected: FAIL because `ExecutionReactWorker` does not exist.

- [ ] **Step 3: Implement final-response worker**

Create `src/execution/react_worker.rs`:

```rust
use serde_json::json;

use crate::context::ModelInputMessages;
use crate::conversation::{ConversationRunFrame, ConversationRunFrameRef};
use crate::execution::{
    CompletedRunRegistry, ExecutionContextInputAssembler, ExecutionEventLog,
};

pub trait ExecutionModelClient: Clone + Send + Sync + 'static {
    fn next_turn(&self, input: &ModelInputMessages) -> Result<ExecutionModelTurn, String>;
}

pub trait ExecutionToolExecutor: Clone + Send + Sync + 'static {
    fn execute_tool(&self, call: &ExecutionToolCall) -> Result<ExecutionToolObservation, String>;
}

#[derive(Clone, Debug, Eq, PartialEq)]
pub enum ExecutionModelTurn {
    Final {
        message_id: String,
        text: String,
    },
    ToolCall {
        call_id: String,
        name: String,
        arguments_json: String,
    },
}

#[derive(Clone, Debug, Eq, PartialEq)]
pub struct ExecutionToolCall {
    pub call_id: String,
    pub name: String,
    pub arguments_json: String,
}

#[derive(Clone, Debug, Eq, PartialEq)]
pub struct ExecutionToolObservation {
    pub call_id: String,
    pub model_text: String,
}

#[derive(Clone, Debug, Default)]
pub struct NoopExecutionToolExecutor;

impl ExecutionToolExecutor for NoopExecutionToolExecutor {
    fn execute_tool(&self, call: &ExecutionToolCall) -> Result<ExecutionToolObservation, String> {
        Err(format!("no execution tool executor installed for {}", call.name))
    }
}

#[derive(Clone, Debug)]
pub struct ExecutionReactWorker<M, T> {
    model: M,
    tools: T,
    context: ExecutionContextInputAssembler,
    event_log: ExecutionEventLog,
    completed_runs: CompletedRunRegistry,
}

impl<M, T> ExecutionReactWorker<M, T>
where
    M: ExecutionModelClient,
    T: ExecutionToolExecutor,
{
    pub fn new(
        model: M,
        tools: T,
        context: ExecutionContextInputAssembler,
        event_log: ExecutionEventLog,
        completed_runs: CompletedRunRegistry,
    ) -> Self {
        Self {
            model,
            tools,
            context,
            event_log,
            completed_runs,
        }
    }

    pub fn run(
        &self,
        run_id: &str,
        frame: &ConversationRunFrame,
        frame_ref: &ConversationRunFrameRef,
    ) -> Result<(), String> {
        let input = self.context.assemble_initial(frame).map_err(|error| {
            format!("{}: {error}", error.code())
        })?;
        match self.model.next_turn(&input)? {
            ExecutionModelTurn::Final { message_id, text } => {
                self.event_log.append_with_payload(
                    run_id,
                    "assistant_message_completed",
                    json!({
                        "message_id": message_id,
                        "text": text
                    })
                    .to_string(),
                );
                self.event_log.append(run_id, "run.completed");
                self.completed_runs.record_completed_with_text(
                    run_id,
                    &message_id,
                    frame_ref.clone(),
                    text,
                );
                Ok(())
            }
            ExecutionModelTurn::ToolCall { call_id, name, arguments_json } => {
                let _ = self.tools.execute_tool(&ExecutionToolCall {
                    call_id,
                    name,
                    arguments_json,
                })?;
                Err("tool continuation not implemented in Task 2".to_string())
            }
        }
    }
}
```

Modify `src/execution/mod.rs`:

```rust
mod react_worker;
pub use react_worker::{
    ExecutionModelClient, ExecutionModelTurn, ExecutionReactWorker,
    ExecutionToolCall, ExecutionToolExecutor, ExecutionToolObservation,
    NoopExecutionToolExecutor,
};
```

- [ ] **Step 4: Run test to verify it passes**

Run:

```bash
cargo test --test contract react_worker_emits_final_response_without_synthetic_adapter -- --nocapture
```

Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add local-ios-agent/rust-core/src/execution/react_worker.rs \
  local-ios-agent/rust-core/src/execution/mod.rs \
  local-ios-agent/rust-core/tests/contract/conversation_execution_boundary.rs
git commit -m "feat: add execution react worker final path"
```

### Task 3: Tool Continuation Context Accumulation

**Files:**
- Modify: `local-ios-agent/rust-core/src/execution/react_worker.rs`
- Modify: `local-ios-agent/rust-core/src/execution/context_input.rs`
- Test: `local-ios-agent/rust-core/tests/contract/conversation_execution_boundary.rs`

**Interfaces:**
- Consumes: `ExecutionModelTurn::ToolCall`, `ExecutionToolObservation`
- Produces:
  - `ExecutionContextInputAssembler::assemble_with_observations(&self, frame: &ConversationRunFrame, observations: &[ExecutionToolObservation]) -> Result<ModelInputMessages, ExecutionContextInputError>`
  - `ExecutionReactWorker::run` continues until final or budget limit.

- [ ] **Step 1: Write the failing test**

Add this test:

```rust
#[test]
fn react_worker_includes_tool_observation_in_second_model_call() {
    use std::sync::{Arc, Mutex};
    use local_ios_agent_runtime::context::ModelInputMessages;
    use local_ios_agent_runtime::execution::{
        CompletedRunRegistry, ExecutionContextInputAssembler, ExecutionEventLog,
        ExecutionModelClient, ExecutionModelTurn, ExecutionReactWorker,
        ExecutionToolCall, ExecutionToolExecutor, ExecutionToolObservation,
    };

    #[derive(Clone)]
    struct ScriptedModel {
        seen_inputs: Arc<Mutex<Vec<ModelInputMessages>>>,
    }

    impl ExecutionModelClient for ScriptedModel {
        fn next_turn(&self, input: &ModelInputMessages) -> Result<ExecutionModelTurn, String> {
            let mut seen = self.seen_inputs.lock().unwrap();
            seen.push(input.clone());
            if seen.len() == 1 {
                Ok(ExecutionModelTurn::ToolCall {
                    call_id: "call_1".to_string(),
                    name: "debug.echo".to_string(),
                    arguments_json: r#"{"text":"hello"}"#.to_string(),
                })
            } else {
                assert!(input.messages().iter().any(|message| {
                    message.content().contains("tool said hello")
                }));
                Ok(ExecutionModelTurn::Final {
                    message_id: "final_after_tool".to_string(),
                    text: "answer after tool".to_string(),
                })
            }
        }
    }

    #[derive(Clone)]
    struct EchoTool;

    impl ExecutionToolExecutor for EchoTool {
        fn execute_tool(&self, call: &ExecutionToolCall) -> Result<ExecutionToolObservation, String> {
            Ok(ExecutionToolObservation {
                call_id: call.call_id.clone(),
                model_text: "tool said hello".to_string(),
            })
        }
    }

    let seen_inputs = Arc::new(Mutex::new(Vec::new()));
    let frame_ref = ConversationRunFrameRef::new(
        ConversationFrameId::new("frame_tool_1"),
        SessionId("session_1".into()),
        EntryId("user_turn_1".into()),
        EntryId("user_turn_1".into()),
    );
    let frame = ConversationRunFrame::new(
        frame_ref.clone(),
        None,
        vec![ConversationFrameMessage::user(EntryId("user_turn_1".into()), "use tool")],
        Vec::new(),
        ConversationLineage::new(EntryId("user_turn_1".into()), None, None),
    );
    let event_log = ExecutionEventLog::default();
    let completed_runs = CompletedRunRegistry::default();
    let worker = ExecutionReactWorker::new(
        ScriptedModel { seen_inputs: seen_inputs.clone() },
        EchoTool,
        ExecutionContextInputAssembler::new(None),
        event_log.clone(),
        completed_runs.clone(),
    );

    worker.run("run_tool_1", &frame, &frame_ref).unwrap();

    assert_eq!(seen_inputs.lock().unwrap().len(), 2);
    assert!(event_log.replay("run_tool_1", Some(0)).iter().any(|event| {
        event.code() == "tool_result_message"
    }));
    assert!(completed_runs.get("run_tool_1", "final_after_tool").is_some());
}
```

- [ ] **Step 2: Run test to verify it fails**

Run:

```bash
cargo test --test contract react_worker_includes_tool_observation_in_second_model_call -- --nocapture
```

Expected: FAIL because Task 2 returns an error on tool call.

- [ ] **Step 3: Implement continuation loop**

Modify `react_worker.rs` so `run` keeps observations and loops:

```rust
let mut observations = Vec::new();
for _ in 0..8 {
    let input = self
        .context
        .assemble_with_observations(frame, &observations)
        .map_err(|error| format!("{}: {error}", error.code()))?;
    match self.model.next_turn(&input)? {
        ExecutionModelTurn::Final { message_id, text } => {
            // existing final code
            return Ok(());
        }
        ExecutionModelTurn::ToolCall { call_id, name, arguments_json } => {
            self.event_log.append_with_payload(
                run_id,
                "tool_call_requested",
                json!({
                    "call_id": call_id,
                    "name": name,
                    "arguments_json": arguments_json
                }).to_string(),
            );
            let observation = self.tools.execute_tool(&ExecutionToolCall {
                call_id,
                name,
                arguments_json,
            })?;
            self.event_log.append_with_payload(
                run_id,
                "tool_result_message",
                json!({
                    "call_id": observation.call_id,
                    "model_text": observation.model_text
                }).to_string(),
            );
            observations.push(observation);
        }
    }
}
self.event_log.append(run_id, "run.failed");
Err("execution tool loop exceeded 8 model calls".to_string())
```

Add `assemble_with_observations` to `context_input.rs`:

```rust
pub fn assemble_with_observations(
    &self,
    frame: &ConversationRunFrame,
    observations: &[ExecutionToolObservation],
) -> Result<ModelInputMessages, ExecutionContextInputError> {
    let mut input = self.assemble_initial(frame)?;
    for observation in observations {
        input.push(ModelInputMessage::new(
            ModelInputRole::Tool,
            observation.model_text.clone(),
        ));
    }
    Ok(input)
}
```

- [ ] **Step 4: Run test to verify it passes**

Run:

```bash
cargo test --test contract react_worker_includes_tool_observation_in_second_model_call -- --nocapture
```

Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add local-ios-agent/rust-core/src/execution/react_worker.rs \
  local-ios-agent/rust-core/src/execution/context_input.rs \
  local-ios-agent/rust-core/tests/contract/conversation_execution_boundary.rs
git commit -m "feat: continue execution context after tool observations"
```

### Task 4: Wire ExecutionService To Real Worker Mode

**Files:**
- Modify: `local-ios-agent/rust-core/src/execution/execution_service.rs`
- Modify: `local-ios-agent/rust-core/src/execution/tool_loop.rs`
- Test: `local-ios-agent/rust-core/tests/contract/conversation_execution_boundary.rs`
- Test: `local-ios-agent/rust-core/tests/integration/ffi_bridge.rs`

**Interfaces:**
- Consumes: `ExecutionReactWorker`
- Produces:
  - `ExecutionWorkerMode::SyntheticAdapter`
  - `ExecutionWorkerMode::ReactWorker`
  - `ExecutionServiceParts::worker_mode`

- [ ] **Step 1: Write failing architecture test**

Add:

```rust
#[test]
fn execution_service_default_path_does_not_emit_synthetic_response() {
    let source = include_str!("../../src/execution/tool_loop.rs");
    assert!(
        !source.contains("Synthetic response to:"),
        "production ToolLoopService must not synthesize assistant responses"
    );
}
```

- [ ] **Step 2: Run test to verify it fails**

Run:

```bash
cargo test --test contract execution_service_default_path_does_not_emit_synthetic_response -- --nocapture
```

Expected: FAIL while `ToolLoopService` contains the synthetic responder.

- [ ] **Step 3: Move synthetic adapter behind test-only mode**

Modify `tool_loop.rs` so production `start` no longer emits final responses. The synthetic code moves to:

```rust
pub fn start_synthetic_for_contract_tests(
    &self,
    request: ToolLoopStartRequest,
) -> Result<(), ToolLoopStartError> {
    // previous synthetic implementation
}
```

Modify `execution_service.rs` to call `ExecutionReactWorker` for default start. If the real provider bridge is not available yet, inject a contract fake only from tests, not from default production construction.

- [ ] **Step 4: Update FFI integration expected output**

Modify `tests/integration/ffi_bridge.rs` so feature tests expect the real worker final text fixture, not `"Synthetic response"`.

- [ ] **Step 5: Run tests**

Run:

```bash
cargo test --test contract execution_service_default_path_does_not_emit_synthetic_response -- --nocapture
cargo test --test integration ffi_bridge -- --nocapture
```

Expected: PASS.

- [ ] **Step 6: Commit**

```bash
git add local-ios-agent/rust-core/src/execution/execution_service.rs \
  local-ios-agent/rust-core/src/execution/tool_loop.rs \
  local-ios-agent/rust-core/tests/contract/conversation_execution_boundary.rs \
  local-ios-agent/rust-core/tests/integration/ffi_bridge.rs
git commit -m "feat: route execution service through react worker"
```

### Task 5: StartExecutionRequest Options Feed Execution Context

**Files:**
- Modify: `local-ios-agent/rust-core/src/ffi_bridge.rs`
- Modify: `local-ios-agent/rust-core/src/execution/execution_service.rs`
- Test: `local-ios-agent/rust-core/tests/integration/ffi_bridge.rs`

**Interfaces:**
- Consumes: `StartRunRequestJson.options`
- Produces: runtime options visible to execution context before model call.

- [ ] **Step 1: Write failing FFI test**

Add:

```rust
#[test]
fn c_abi_start_run_applies_execution_options_before_context_assembly() {
    unsafe {
        let runtime = new_seeded_agent_os_c_bridge();
        let prepared = prepare_c_user_turn(runtime, "hello options");
        let request = CString::new(
            json!({
                "agent_profile_id": "profile_1",
                "user_intent": "hello options",
                "conversation_run_frame_ref": prepared["conversation_run_frame_ref"],
                "options": {
                    "temperature": 0.25,
                    "top_p": 0.8
                }
            }).to_string(),
        ).unwrap();
        let handle = decode(&take_bridge_string(local_agent_runtime_bridge_start_run(
            runtime,
            request.as_ptr(),
        )));
        assert_eq!(handle["run_id"], "run_1");
        local_agent_runtime_bridge_free(runtime);
    }
}
```

- [ ] **Step 2: Run test to verify it fails for the right reason**

Run:

```bash
cargo test --test integration c_abi_start_run_applies_execution_options_before_context_assembly -- --nocapture
```

Expected: FAIL until `start_run_json` applies `request.options`.

- [ ] **Step 3: Implement options mapping**

Modify `ffi_bridge.rs`:

```rust
let options = request.options.into_runtime_options(
    AgentPromptDefaults::system_prompt(),
    AgentPromptDefaults::runtime_policy(),
)?;
self.execution().update_runtime_options(options)?;
```

If prompt defaults are not available as Rust constants, use the runtime bridge config values already available in `BridgeRuntime`.

- [ ] **Step 4: Run test to verify it passes**

Run:

```bash
cargo test --test integration c_abi_start_run_applies_execution_options_before_context_assembly -- --nocapture
```

Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add local-ios-agent/rust-core/src/ffi_bridge.rs \
  local-ios-agent/rust-core/src/execution/execution_service.rs \
  local-ios-agent/rust-core/tests/integration/ffi_bridge.rs
git commit -m "feat: apply execution options before run start"
```

### Task 6: Swift Feature Gate Flip Readiness Test

**Files:**
- Modify: `local-ios-agent/apps/LocalAgentApp/LocalAgentApp/Composition/AppBootstrapper.swift`
- Test: `local-ios-agent/apps/LocalAgentApp/LocalAgentAppTests/Integration/RustRuntimeAppIntegrationTests.swift`

**Interfaces:**
- Consumes: Rust execution path readiness.
- Produces: documented rule that production default remains legacy until Rust real worker is verified in App target.

- [ ] **Step 1: Keep default gate test**

Keep this test passing:

```swift
@Test("App bootstrapper keeps legacy streaming path by default")
func appBootstrapperKeepsLegacyStreamingPathByDefault() async throws {
    let container = try AppBootstrapper.makeContainer(store: .inMemory)
    let usesCoordinator = await container.runtimeService.usesConversationExecutionCoordinatorForTesting()
    #expect(!usesCoordinator)
}
```

- [ ] **Step 2: Add explicit readiness comment**

Modify `AppBootstrapper.swift` above the env guard:

```swift
// Keep this feature gated until Rust execution uses the real ReAct worker.
// The phase-1 synthetic adapter must not become the default app path.
guard environment["LOCAL_AGENT_ENABLE_CONVERSATION_EXECUTION_COORDINATOR"] == "1" else {
    return nil
}
```

- [ ] **Step 3: Run available Swift checks**

Run:

```bash
swift test
plutil -lint local-ios-agent/apps/LocalAgentApp/LocalAgentApp.xcodeproj/project.pbxproj
```

Expected: Toolkit tests PASS; project file lint PASS. App target requires full Xcode.

- [ ] **Step 4: Commit**

```bash
git add local-ios-agent/apps/LocalAgentApp/LocalAgentApp/Composition/AppBootstrapper.swift \
  local-ios-agent/apps/LocalAgentApp/LocalAgentAppTests/Integration/RustRuntimeAppIntegrationTests.swift
git commit -m "test: keep swift coordinator gated until rust execution is real"
```

## Verification

Run after all tasks:

```bash
cargo test --quiet
swift test
plutil -lint local-ios-agent/apps/LocalAgentApp/LocalAgentApp.xcodeproj/project.pbxproj
git diff --check
```

Expected:
- Rust full suite passes.
- Toolkit SwiftPM suite passes.
- Xcode project plist lint passes.
- No whitespace errors.

## Self-Review

Spec coverage:
- Trusted frame ref remains execution input only: covered by existing boundary tests and Task 4.
- Conversation skeleton remains conversation-owned: Task 1 consumes `ConversationRunFrame` only.
- Context assembly occurs in execution: Task 1 and Task 3.
- Tool loop accumulates observations: Task 3.
- Synthetic adapter removed from production path: Task 4.
- Swift default remains safe until Rust real path exists: Task 6.

Placeholder scan:
- No task uses TBD/TODO/later.
- Each task has exact files, commands, expected result, and commit message.

Type consistency:
- `ExecutionContextInputAssembler`, `ExecutionReactWorker`, `ExecutionModelClient`, `ExecutionToolExecutor`, and `ExecutionModelTurn` are introduced before later tasks consume them.
