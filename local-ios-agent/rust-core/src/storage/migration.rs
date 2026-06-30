use super::{StorageError, StorageResult};

#[derive(Clone, Copy, Debug, Eq, Ord, PartialEq, PartialOrd)]
pub struct SchemaVersion(u32);

impl SchemaVersion {
    pub const fn new(value: u32) -> Self {
        Self(value)
    }

    pub const fn as_u32(self) -> u32 {
        self.0
    }
}

#[derive(Clone, Debug, Eq, PartialEq)]
pub struct MigrationStep {
    from: SchemaVersion,
    to: SchemaVersion,
    name: String,
}

impl MigrationStep {
    pub fn new(
        from: SchemaVersion,
        to: SchemaVersion,
        name: impl Into<String>,
    ) -> StorageResult<Self> {
        if to <= from {
            return Err(StorageError::new(
                "storage.migration_not_forward",
                "migration steps must move schema versions forward",
            ));
        }

        Ok(Self {
            from,
            to,
            name: name.into(),
        })
    }

    pub const fn from(&self) -> SchemaVersion {
        self.from
    }

    pub const fn to(&self) -> SchemaVersion {
        self.to
    }

    pub fn name(&self) -> &str {
        &self.name
    }
}

#[derive(Clone, Debug, Eq, PartialEq)]
pub struct MigrationPlan {
    steps: Vec<MigrationStep>,
}

impl MigrationPlan {
    pub fn new(steps: Vec<MigrationStep>) -> StorageResult<Self> {
        Ok(Self { steps })
    }

    pub fn target_version(&self, current: SchemaVersion) -> StorageResult<SchemaVersion> {
        let mut expected = current;

        for step in &self.steps {
            if step.from != expected {
                return Err(StorageError::new(
                    "storage.migration_gap",
                    "migration plan must be contiguous from the current schema version",
                ));
            }
            expected = step.to;
        }

        Ok(expected)
    }

    pub fn steps(&self) -> &[MigrationStep] {
        &self.steps
    }
}
