use std::io::{BufRead, BufReader, Read, Write};
use std::net::TcpListener;
use std::thread;
use std::time::{Duration, Instant};

use local_ios_agent_runtime::core::{
    CancellationToken, DesktopMiniCPMTransport, LocalhostHttpTransport,
};

#[test]
fn localhost_transport_rejects_non_localhost_http_endpoints() {
    assert!(LocalhostHttpTransport::new("https://127.0.0.1:8000/v1/chat/completions").is_err());
    assert!(LocalhostHttpTransport::new("http://example.com:8000/v1/chat/completions").is_err());
    assert!(LocalhostHttpTransport::new("http://127.0.0.1:8000/v1/chat/completions").is_ok());
    assert!(LocalhostHttpTransport::new("http://localhost:8000/v1/chat/completions").is_ok());
}

#[test]
fn localhost_transport_uses_content_length_and_does_not_wait_for_eof() {
    let listener = TcpListener::bind("127.0.0.1:0").unwrap();
    let address = listener.local_addr().unwrap();
    let server = thread::spawn(move || {
        let (stream, _) = listener.accept().unwrap();
        let mut reader = BufReader::new(stream);
        let mut headers = Vec::new();
        loop {
            let mut line = String::new();
            reader.read_line(&mut line).unwrap();
            if line == "\r\n" {
                break;
            }
            headers.push(line);
        }

        let content_length = headers
            .iter()
            .find_map(|line| {
                line.to_ascii_lowercase()
                    .strip_prefix("content-length:")
                    .map(|value| value.trim().parse::<usize>().unwrap())
            })
            .unwrap();
        let mut body = vec![0; content_length];
        reader.read_exact(&mut body).unwrap();
        assert_eq!(String::from_utf8(body).unwrap(), r#"{"hello":"world"}"#);

        let response_body = r#"{"choices":[{"message":{"content":"ok"}}]}"#;
        let response = format!(
            "HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nContent-Length: {}\r\n\r\n{}",
            response_body.len(),
            response_body
        );
        let stream = reader.get_mut();
        stream.write_all(response.as_bytes()).unwrap();
        stream.flush().unwrap();
        thread::sleep(Duration::from_millis(250));
    });

    let transport =
        LocalhostHttpTransport::new(format!("http://{address}/v1/chat/completions")).unwrap();
    let started = Instant::now();
    let response = transport
        .chat_completion(r#"{"hello":"world"}"#.into(), CancellationToken::default())
        .unwrap();

    assert!(started.elapsed() < Duration::from_millis(200));
    assert_eq!(response, r#"{"choices":[{"message":{"content":"ok"}}]}"#);
    server.join().unwrap();
}
