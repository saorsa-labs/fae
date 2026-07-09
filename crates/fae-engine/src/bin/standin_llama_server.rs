//! Test-fixture stand-in for `llama-server`, used ONLY by the #36 reclaim gate
//! test (`tests/orphan_reclaim.rs`). It binds `127.0.0.1:<--port>` and answers
//! the two endpoints `LlamaServerHandle::await_ready` requires — `GET /health`
//! (200) and `GET /v1/models` (200, `data[0].id` == `--alias`) — then stays
//! alive until killed. Stdlib only, so the test is CI-portable with no model/GPU.
//! It ignores every other `llama-server` flag Fae passes (`-m`, `--host`, `-c`…).

use std::io::{Read, Write};
use std::net::TcpListener;

fn main() {
    let mut port = 0u16;
    let mut alias = "standin".to_owned();
    let mut args = std::env::args().skip(1);
    while let Some(arg) = args.next() {
        match arg.as_str() {
            "--port" => port = args.next().and_then(|v| v.parse().ok()).unwrap_or(port),
            "--alias" => alias = args.next().unwrap_or(alias),
            _ => {}
        }
    }
    let listener = match TcpListener::bind(("127.0.0.1", port)) {
        Ok(l) => l,
        Err(error) => {
            eprintln!("standin bind {port} failed: {error}");
            std::process::exit(1);
        }
    };
    eprintln!(
        "standin listening pid={} port={}",
        std::process::id(),
        listener.local_addr().map(|a| a.port()).unwrap_or(port)
    );
    for stream in listener.incoming() {
        let mut stream = match stream {
            Ok(s) => s,
            Err(_) => continue,
        };
        let _ = stream.set_read_timeout(Some(std::time::Duration::from_millis(200)));
        let mut buf = [0u8; 1024];
        let n = stream.read(&mut buf).unwrap_or(0);
        let request = String::from_utf8_lossy(&buf[..n]);
        let path = request
            .lines()
            .next()
            .and_then(|line| line.split_whitespace().nth(1))
            .unwrap_or("/");
        let body = match path {
            "/health" => r#"{"status":"ok"}"#.to_owned(),
            "/v1/models" => {
                format!("{{\"object\":\"list\",\"data\":[{{\"id\":\"{alias}\"}}]}}")
            }
            _ => "{}".to_owned(),
        };
        let response = format!(
            "HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nContent-Length: {}\r\nConnection: close\r\n\r\n{body}",
            body.len()
        );
        let _ = stream.write_all(response.as_bytes());
    }
}
