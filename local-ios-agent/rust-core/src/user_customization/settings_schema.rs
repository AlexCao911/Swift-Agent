use serde::Serialize;

#[derive(Clone, Debug, Eq, PartialEq, Serialize)]
pub struct UserSettingsSchema {
    fields: Vec<SettingsFieldDescriptor>,
}

#[derive(Clone, Debug, Eq, PartialEq, Serialize)]
pub struct SettingsFieldDescriptor {
    key: String,
    label: String,
    control: SettingsControlKind,
    range: Option<SettingsValueRange>,
    options: Vec<SettingsOptionDescriptor>,
    default_value: Option<String>,
}

#[derive(Clone, Copy, Debug, Eq, PartialEq, Serialize)]
pub enum SettingsControlKind {
    Slider,
    Picker,
    Toggle,
    Text,
}

#[derive(Clone, Debug, Eq, PartialEq, Serialize)]
pub struct SettingsValueRange {
    min: String,
    max: String,
    step: String,
}

#[derive(Clone, Debug, Eq, PartialEq, Serialize)]
pub struct SettingsOptionDescriptor {
    id: String,
    label: String,
}

impl UserSettingsSchema {
    pub fn new(fields: Vec<SettingsFieldDescriptor>) -> Self {
        Self { fields }
    }

    pub fn fixture_generation_controls() -> Self {
        Self::new(vec![
            SettingsFieldDescriptor::slider(
                "temperature",
                "Temperature",
                SettingsValueRange::decimal("0", "2", "0.1"),
            )
            .with_default("0.7"),
            SettingsFieldDescriptor::picker(
                "model",
                "Model",
                vec![
                    SettingsOptionDescriptor::new("local.default", "Local default"),
                    SettingsOptionDescriptor::new("remote.default", "Remote default"),
                ],
            ),
        ])
    }

    pub fn field(&self, key: &str) -> Option<&SettingsFieldDescriptor> {
        self.fields.iter().find(|field| field.key == key)
    }

    pub fn fields(&self) -> &[SettingsFieldDescriptor] {
        &self.fields
    }

    pub fn serialized_text(&self) -> String {
        serde_json::to_string(self).expect("settings schema serialization should be infallible")
    }
}

impl SettingsFieldDescriptor {
    pub fn slider(
        key: impl Into<String>,
        label: impl Into<String>,
        range: SettingsValueRange,
    ) -> Self {
        Self {
            key: key.into(),
            label: label.into(),
            control: SettingsControlKind::Slider,
            range: Some(range),
            options: Vec::new(),
            default_value: None,
        }
    }

    pub fn picker(
        key: impl Into<String>,
        label: impl Into<String>,
        options: Vec<SettingsOptionDescriptor>,
    ) -> Self {
        Self {
            key: key.into(),
            label: label.into(),
            control: SettingsControlKind::Picker,
            range: None,
            options,
            default_value: None,
        }
    }

    pub fn with_default(mut self, value: impl Into<String>) -> Self {
        self.default_value = Some(value.into());
        self
    }

    pub fn key(&self) -> &str {
        &self.key
    }

    pub fn label(&self) -> &str {
        &self.label
    }

    pub fn control(&self) -> SettingsControlKind {
        self.control
    }

    pub fn range(&self) -> Option<&SettingsValueRange> {
        self.range.as_ref()
    }

    pub fn options(&self) -> &[SettingsOptionDescriptor] {
        &self.options
    }

    pub fn default_value(&self) -> Option<&str> {
        self.default_value.as_deref()
    }
}

impl SettingsValueRange {
    pub fn decimal(
        min: impl Into<String>,
        max: impl Into<String>,
        step: impl Into<String>,
    ) -> Self {
        Self {
            min: min.into(),
            max: max.into(),
            step: step.into(),
        }
    }

    pub fn min(&self) -> &str {
        &self.min
    }

    pub fn max(&self) -> &str {
        &self.max
    }

    pub fn step(&self) -> &str {
        &self.step
    }
}

impl SettingsOptionDescriptor {
    pub fn new(id: impl Into<String>, label: impl Into<String>) -> Self {
        Self {
            id: id.into(),
            label: label.into(),
        }
    }

    pub fn id(&self) -> &str {
        &self.id
    }

    pub fn label(&self) -> &str {
        &self.label
    }
}
