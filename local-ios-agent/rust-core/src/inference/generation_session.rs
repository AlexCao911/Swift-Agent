use std::collections::{BTreeMap, VecDeque};
use std::sync::{Arc, Mutex};

use crate::inference::{BackendFailure, BackendFailureKind, InferenceResult, UsageReport};
use crate::model::ResolvedModelBinding;
use crate::security::{ApprovalGrant, ApprovalRequirement, DataEgressDecision};

#[derive(Clone, Debug, Eq, PartialEq)]
pub struct GenerationRequest {
    pub model_id: String,
    pub input_messages: Vec<String>,
    pub egress_decision: Option<DataEgressDecision>,
    pub approval_grant: Option<ApprovalGrant>,
}

impl GenerationRequest {
    pub fn local(model_id: impl Into<String>) -> Self {
        Self {
            model_id: model_id.into(),
            input_messages: Vec::new(),
            egress_decision: None,
            approval_grant: None,
        }
    }

    pub fn remote(
        model_id: impl Into<String>,
        egress_decision: DataEgressDecision,
        approval_grant: Option<ApprovalGrant>,
    ) -> Self {
        Self {
            model_id: model_id.into(),
            input_messages: Vec::new(),
            egress_decision: Some(egress_decision),
            approval_grant,
        }
    }

    pub fn fixture_remote_without_egress() -> Self {
        Self {
            model_id: "remote-model".to_string(),
            input_messages: Vec::new(),
            egress_decision: None,
            approval_grant: None,
        }
    }

    pub fn from_resolved_model_binding(binding: &ResolvedModelBinding) -> Self {
        Self {
            model_id: binding.model().id.clone(),
            input_messages: Vec::new(),
            egress_decision: binding.egress_decision().cloned(),
            approval_grant: binding.approval_grant().cloned(),
        }
    }

    pub fn with_input_messages<I, S>(mut self, input_messages: I) -> Self
    where
        I: IntoIterator<Item = S>,
        S: Into<String>,
    {
        self.input_messages = input_messages.into_iter().map(Into::into).collect();
        self
    }
}

#[derive(Debug)]
pub struct GenerationSession {
    model_id: String,
    cancelled: bool,
    tokens: VecDeque<String>,
    usage: Option<UsageReport>,
    _lease: Option<SessionLease>,
}

impl GenerationSession {
    pub fn new(model_id: impl Into<String>) -> Self {
        Self {
            model_id: model_id.into(),
            cancelled: false,
            tokens: VecDeque::new(),
            usage: None,
            _lease: None,
        }
    }

    pub fn with_tokens<I, S>(mut self, tokens: I) -> Self
    where
        I: IntoIterator<Item = S>,
        S: Into<String>,
    {
        self.tokens = tokens.into_iter().map(Into::into).collect();
        self
    }

    pub fn with_usage(mut self, usage: UsageReport) -> Self {
        self.usage = Some(usage);
        self
    }

    pub(crate) fn with_session_lease(mut self, active_sessions: ActiveSessionCounts) -> Self {
        self._lease = Some(SessionLease {
            model_id: self.model_id.clone(),
            active_sessions,
        });
        self
    }

    pub fn model_id(&self) -> &str {
        &self.model_id
    }

    pub fn cancel(&mut self) {
        self.cancelled = true;
    }

    pub fn next_token(&mut self) -> InferenceResult<Option<String>> {
        if self.cancelled {
            return Err(BackendFailure::new(
                BackendFailureKind::GenerationCancelled,
                "generation session was cancelled",
            ));
        }
        Ok(self.tokens.pop_front())
    }

    pub fn usage(&self) -> Option<&UsageReport> {
        self.usage.as_ref()
    }

    pub fn is_cancelled(&self) -> bool {
        self.cancelled
    }
}

pub(crate) type ActiveSessionCounts = Arc<Mutex<BTreeMap<String, usize>>>;

#[derive(Debug)]
pub(crate) struct SessionLease {
    model_id: String,
    active_sessions: ActiveSessionCounts,
}

impl Drop for SessionLease {
    fn drop(&mut self) {
        let mut active_sessions = self
            .active_sessions
            .lock()
            .expect("active session counts poisoned");
        if let Some(count) = active_sessions.get_mut(&self.model_id) {
            *count = count.saturating_sub(1);
            if *count == 0 {
                active_sessions.remove(&self.model_id);
            }
        }
    }
}

pub(crate) fn egress_requires_approval(decision: &DataEgressDecision) -> bool {
    decision.approval_requirement() == ApprovalRequirement::Required
}
