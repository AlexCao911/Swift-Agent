use std::io::{BufRead, BufReader, Read, Write};
use std::net::TcpStream;
use std::time::Duration;

use crate::context::{PromptFrame, TokenizerAdapter};
use crate::core::{
    build_openai_chat_request, parse_openai_chat_response, AgentError, CancellationToken,
    ModelProvider, ModelProviderOutput, ProviderBundle, ProviderKind, ProviderProfile,
    ProviderRegistry,
};

pub trait DesktopMiniCPMTransport: Send + Sync {
    fn chat_completion(
        &self,
        request_json: String,
        cancellation: CancellationToken,
    ) -> Result<String, AgentError>;
}

pub struct DesktopMiniCPMProvider {
    model: String,
    transport: Box<dyn DesktopMiniCPMTransport>,
}

#[derive(Clone, Debug, Eq, PartialEq)]
pub struct DesktopMiniCPMSettings {
    pub endpoint: String,
    pub model: String,
    pub max_context_tokens: usize,
}

#[derive(Clone, Debug, Eq, PartialEq)]
pub struct DesktopMiniCPMTokenizer {
    max_context_tokens: usize,
}

#[derive(Clone, Debug, Eq, PartialEq)]
pub struct LocalhostHttpTransport {
    host: String,
    port: u16,
    path: String,
}

pub fn register_desktop_minicpm_provider(
    registry: &mut ProviderRegistry,
    settings: DesktopMiniCPMSettings,
) -> Result<(), AgentError> {
    let transport = LocalhostHttpTransport::new(&settings.endpoint)?;
    let model = settings.model.clone();
    let max_context_tokens = settings.max_context_tokens;

    registry.register_factory(
        ProviderProfile {
            id: "desktop_minicpm".into(),
            display_name: "Desktop MiniCPM".into(),
            kind: ProviderKind::DesktopMiniCpm,
            max_context_tokens,
        },
        move || ProviderBundle {
            provider: Box::new(DesktopMiniCPMProvider::new(
                model.clone(),
                Box::new(transport.clone()),
            )),
            tokenizer: Box::new(DesktopMiniCPMTokenizer::new(max_context_tokens)),
        },
    )
}

impl DesktopMiniCPMTokenizer {
    pub fn new(max_context_tokens: usize) -> Self {
        Self { max_context_tokens }
    }
}

impl TokenizerAdapter for DesktopMiniCPMTokenizer {
    fn provider_id(&self) -> &str {
        "desktop_minicpm"
    }

    fn max_context_tokens(&self) -> usize {
        self.max_context_tokens
    }

    fn safety_margin_tokens(&self) -> usize {
        let scaled = self.max_context_tokens / 16;
        scaled.max(32).min(512).min(self.max_context_tokens / 2)
    }

    fn count_text(&self, text: &str) -> usize {
        let mut tokens = 0;
        let mut ascii_run_bytes = 0;
        for character in text.chars() {
            if character.is_ascii_whitespace() {
                tokens += ascii_token_estimate(ascii_run_bytes);
                ascii_run_bytes = 0;
            } else if character.is_ascii() {
                ascii_run_bytes += character.len_utf8();
            } else {
                tokens += ascii_token_estimate(ascii_run_bytes);
                ascii_run_bytes = 0;
                tokens += character.len_utf8().max(1);
            }
        }
        tokens + ascii_token_estimate(ascii_run_bytes)
    }

    fn count_prompt_frame(&self, frame: &PromptFrame) -> usize {
        let mut count = self.count_text(&frame.system_prompt);
        count += self.count_text(&frame.runtime_policy);
        count += frame
            .tool_schemas
            .iter()
            .map(|tool| self.count_text(tool))
            .sum::<usize>();
        count += frame
            .messages
            .iter()
            .map(|message| self.count_text(message.content()))
            .sum::<usize>();
        count
    }

    fn boxed_clone(&self) -> Box<dyn TokenizerAdapter> {
        Box::new(self.clone())
    }
}

impl LocalhostHttpTransport {
    pub fn new(endpoint: impl AsRef<str>) -> Result<Self, AgentError> {
        let endpoint = endpoint.as_ref();
        let rest = endpoint.strip_prefix("http://").ok_or_else(|| {
            AgentError::Provider("desktop MiniCPM endpoint must use http://".into())
        })?;
        let (authority, path) = match rest.split_once('/') {
            Some((authority, path)) => (authority, format!("/{path}")),
            None => (rest, "/".to_string()),
        };
        let (host, port) = parse_authority(authority)?;
        if !is_loopback_host(&host) {
            return Err(AgentError::Provider(format!(
                "desktop MiniCPM endpoint must be localhost: {host}"
            )));
        }

        Ok(Self { host, port, path })
    }
}

impl DesktopMiniCPMTransport for LocalhostHttpTransport {
    fn chat_completion(
        &self,
        request_json: String,
        cancellation: CancellationToken,
    ) -> Result<String, AgentError> {
        if cancellation.is_cancelled() {
            return Err(AgentError::Cancelled("desktop MiniCPM cancelled".into()));
        }

        let connect_host = self.host.trim_start_matches('[').trim_end_matches(']');
        let mut stream = TcpStream::connect((connect_host, self.port)).map_err(|error| {
            AgentError::Provider(format!(
                "failed to connect desktop MiniCPM endpoint: {error}"
            ))
        })?;
        stream
            .set_read_timeout(Some(Duration::from_secs(5)))
            .map_err(|error| {
                AgentError::Provider(format!("failed to set read timeout: {error}"))
            })?;
        stream
            .set_write_timeout(Some(Duration::from_secs(5)))
            .map_err(|error| {
                AgentError::Provider(format!("failed to set write timeout: {error}"))
            })?;

        let request = format!(
            "POST {} HTTP/1.1\r\nHost: {}:{}\r\nContent-Type: application/json\r\nContent-Length: {}\r\nConnection: close\r\n\r\n{}",
            self.path,
            self.host,
            self.port,
            request_json.len(),
            request_json
        );
        stream.write_all(request.as_bytes()).map_err(|error| {
            AgentError::Provider(format!("failed to write desktop MiniCPM request: {error}"))
        })?;
        stream.flush().map_err(|error| {
            AgentError::Provider(format!("failed to flush desktop MiniCPM request: {error}"))
        })?;

        if cancellation.is_cancelled() {
            return Err(AgentError::Cancelled("desktop MiniCPM cancelled".into()));
        }

        read_http_response_body(stream, cancellation)
    }
}

impl DesktopMiniCPMProvider {
    pub fn new(model: impl Into<String>, transport: Box<dyn DesktopMiniCPMTransport>) -> Self {
        Self {
            model: model.into(),
            transport,
        }
    }
}

impl ModelProvider for DesktopMiniCPMProvider {
    fn id(&self) -> &str {
        "desktop_minicpm"
    }

    fn stream_chat(
        &self,
        frame: &PromptFrame,
        cancellation: CancellationToken,
    ) -> Result<Vec<ModelProviderOutput>, AgentError> {
        if cancellation.is_cancelled() {
            return Err(AgentError::Cancelled("desktop MiniCPM cancelled".into()));
        }

        let request = build_openai_chat_request(&self.model, frame);
        let response = self
            .transport
            .chat_completion(request.to_string(), cancellation.clone())?;

        if cancellation.is_cancelled() {
            return Err(AgentError::Cancelled("desktop MiniCPM cancelled".into()));
        }

        parse_openai_chat_response(&response)
    }
}

fn parse_authority(authority: &str) -> Result<(String, u16), AgentError> {
    let (host, port) = authority.rsplit_once(':').ok_or_else(|| {
        AgentError::Provider("desktop MiniCPM endpoint must include a port".into())
    })?;
    let port = port
        .parse::<u16>()
        .map_err(|error| AgentError::Provider(format!("invalid MiniCPM endpoint port: {error}")))?;
    Ok((host.to_string(), port))
}

fn is_loopback_host(host: &str) -> bool {
    matches!(host, "localhost" | "127.0.0.1" | "::1" | "[::1]")
}

fn ascii_token_estimate(bytes: usize) -> usize {
    if bytes == 0 {
        0
    } else {
        (bytes + 3) / 4
    }
}

fn read_http_response_body(
    stream: TcpStream,
    cancellation: CancellationToken,
) -> Result<String, AgentError> {
    let mut reader = BufReader::new(stream);
    let mut status_line = String::new();
    reader
        .read_line(&mut status_line)
        .map_err(|error| AgentError::Provider(format!("failed to read HTTP status: {error}")))?;
    if !status_line.starts_with("HTTP/1.1 200") && !status_line.starts_with("HTTP/1.0 200") {
        return Err(AgentError::Provider(format!(
            "desktop MiniCPM HTTP error: {}",
            status_line.trim()
        )));
    }

    let mut content_length = None;
    loop {
        if cancellation.is_cancelled() {
            return Err(AgentError::Cancelled("desktop MiniCPM cancelled".into()));
        }

        let mut line = String::new();
        let read = reader.read_line(&mut line).map_err(|error| {
            AgentError::Provider(format!("failed to read HTTP response headers: {error}"))
        })?;
        if read == 0 {
            return Err(AgentError::Provider(
                "desktop MiniCPM response ended before headers completed".into(),
            ));
        }
        if line == "\r\n" {
            break;
        }
        if let Some(value) = line.to_ascii_lowercase().strip_prefix("content-length:") {
            content_length = Some(value.trim().parse::<usize>().map_err(|error| {
                AgentError::Provider(format!("invalid desktop MiniCPM Content-Length: {error}"))
            })?);
        }
    }

    let content_length = content_length.ok_or_else(|| {
        AgentError::Provider("desktop MiniCPM response missing Content-Length".into())
    })?;
    let mut body = vec![0; content_length];
    reader.read_exact(&mut body).map_err(|error| {
        AgentError::Provider(format!("failed to read HTTP response body: {error}"))
    })?;
    if cancellation.is_cancelled() {
        return Err(AgentError::Cancelled("desktop MiniCPM cancelled".into()));
    }

    String::from_utf8(body).map_err(|error| {
        AgentError::Provider(format!("desktop MiniCPM response is not UTF-8: {error}"))
    })
}
