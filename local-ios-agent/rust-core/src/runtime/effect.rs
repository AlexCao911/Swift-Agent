use std::fmt;
use std::sync::{Arc, Mutex};

pub trait EffectDriver: Send + Sync {
    fn drive(
        &self,
        effect: &Effect,
        idempotency_key: &IdempotencyKey,
        trace_span: &TraceSpan,
    ) -> EffectDriverResult;
}

pub type EffectDriverResult = Result<EffectResult, EffectFailure>;

#[derive(Clone, Debug, Eq, PartialEq)]
pub struct Effect {
    effect_id: String,
    kind: EffectKind,
}

#[derive(Clone, Debug, Eq, PartialEq)]
pub enum EffectKind {
    ToolInvoke,
    InferenceGenerate,
    ApprovalRequest,
    MemoryWrite,
}

#[derive(Clone, Debug, Eq, PartialEq)]
pub struct IdempotencyKey(String);

#[derive(Clone, Debug, Eq, PartialEq)]
pub struct TraceSpan {
    operation: String,
}

#[derive(Clone, Debug, Eq, PartialEq)]
pub struct EffectResult;

#[derive(Clone, Debug, Eq, PartialEq)]
pub struct EffectFailure {
    code: String,
    message: String,
}

#[derive(Clone, Debug, Eq, PartialEq)]
pub struct RecordedEffectCall {
    effect_id: String,
    kind: EffectKind,
    idempotency_key: IdempotencyKey,
    trace_span: TraceSpan,
}

#[derive(Clone, Debug, Default)]
pub struct RecordingEffectDriver {
    inner: Arc<Mutex<RecordingEffectDriverInner>>,
}

#[derive(Clone, Debug, Default)]
struct RecordingEffectDriverInner {
    calls: Vec<RecordedEffectCall>,
    failure_code: Option<String>,
}

impl Effect {
    pub fn tool_invoke(effect_id: impl Into<String>) -> Self {
        Self {
            effect_id: effect_id.into(),
            kind: EffectKind::ToolInvoke,
        }
    }

    pub fn inference_generate(effect_id: impl Into<String>) -> Self {
        Self {
            effect_id: effect_id.into(),
            kind: EffectKind::InferenceGenerate,
        }
    }

    pub fn approval_request(effect_id: impl Into<String>) -> Self {
        Self {
            effect_id: effect_id.into(),
            kind: EffectKind::ApprovalRequest,
        }
    }

    pub fn memory_write(effect_id: impl Into<String>) -> Self {
        Self {
            effect_id: effect_id.into(),
            kind: EffectKind::MemoryWrite,
        }
    }

    pub fn effect_id(&self) -> &str {
        &self.effect_id
    }

    pub fn kind(&self) -> &EffectKind {
        &self.kind
    }
}

impl EffectKind {
    pub fn operation(&self) -> &'static str {
        match self {
            Self::ToolInvoke => "tool.invoke",
            Self::InferenceGenerate => "inference.generate",
            Self::ApprovalRequest => "approval.request",
            Self::MemoryWrite => "memory.write",
        }
    }
}

impl IdempotencyKey {
    pub fn new(value: impl Into<String>) -> Self {
        Self(value.into())
    }

    pub fn as_str(&self) -> &str {
        &self.0
    }
}

impl TraceSpan {
    pub fn new(operation: impl Into<String>) -> Self {
        Self {
            operation: operation.into(),
        }
    }

    pub fn operation(&self) -> &str {
        &self.operation
    }
}

impl EffectFailure {
    pub fn new(code: impl Into<String>, message: impl Into<String>) -> Self {
        Self {
            code: code.into(),
            message: message.into(),
        }
    }

    pub fn code(&self) -> &str {
        &self.code
    }
}

impl fmt::Display for EffectFailure {
    fn fmt(&self, formatter: &mut fmt::Formatter<'_>) -> fmt::Result {
        formatter.write_str(&self.message)
    }
}

impl std::error::Error for EffectFailure {}

impl RecordedEffectCall {
    pub fn effect_id(&self) -> &str {
        &self.effect_id
    }

    pub fn kind(&self) -> &EffectKind {
        &self.kind
    }

    pub fn idempotency_key(&self) -> &IdempotencyKey {
        &self.idempotency_key
    }

    pub fn trace_span(&self) -> &TraceSpan {
        &self.trace_span
    }
}

impl RecordingEffectDriver {
    pub fn failing_with_code(code: impl Into<String>) -> Self {
        let driver = Self::default();
        driver
            .inner
            .lock()
            .expect("recording effect driver mutex poisoned")
            .failure_code = Some(code.into());
        driver
    }

    pub fn recorded_calls(&self) -> Vec<RecordedEffectCall> {
        self.inner
            .lock()
            .expect("recording effect driver mutex poisoned")
            .calls
            .clone()
    }
}

impl EffectDriver for RecordingEffectDriver {
    fn drive(
        &self,
        effect: &Effect,
        idempotency_key: &IdempotencyKey,
        trace_span: &TraceSpan,
    ) -> EffectDriverResult {
        let mut inner = self
            .inner
            .lock()
            .expect("recording effect driver mutex poisoned");
        inner.calls.push(RecordedEffectCall {
            effect_id: effect.effect_id().to_string(),
            kind: effect.kind().clone(),
            idempotency_key: idempotency_key.clone(),
            trace_span: trace_span.clone(),
        });

        if let Some(code) = &inner.failure_code {
            return Err(EffectFailure::new(code.clone(), "recorded effect failure"));
        }

        Ok(EffectResult)
    }
}
