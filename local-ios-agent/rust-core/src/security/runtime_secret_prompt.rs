use std::fmt;

use crate::security::{CredentialPurpose, OperationDescriptor, ResolvedSecret};

pub struct RuntimeSecretPrompt {
    operation: OperationDescriptor,
    purpose: CredentialPurpose,
    active_secret: Option<ResolvedSecret>,
}

impl RuntimeSecretPrompt {
    pub fn new(operation: OperationDescriptor, purpose: CredentialPurpose) -> Self {
        Self {
            operation,
            purpose,
            active_secret: None,
        }
    }

    pub fn submit_secret(&mut self, value: impl Into<String>) {
        self.active_secret = Some(ResolvedSecret::new(value));
    }

    pub fn secret_for(
        &self,
        operation: &OperationDescriptor,
        purpose: CredentialPurpose,
    ) -> Option<&ResolvedSecret> {
        if &self.operation == operation && self.purpose == purpose {
            self.active_secret.as_ref()
        } else {
            None
        }
    }

    pub fn finish_operation(&mut self) {
        self.active_secret = None;
    }

    pub fn operation(&self) -> &OperationDescriptor {
        &self.operation
    }

    pub fn purpose(&self) -> CredentialPurpose {
        self.purpose
    }
}

impl fmt::Debug for RuntimeSecretPrompt {
    fn fmt(&self, formatter: &mut fmt::Formatter<'_>) -> fmt::Result {
        formatter
            .debug_struct("RuntimeSecretPrompt")
            .field("operation", &self.operation)
            .field("purpose", &self.purpose)
            .field("has_active_secret", &self.active_secret.is_some())
            .finish()
    }
}
