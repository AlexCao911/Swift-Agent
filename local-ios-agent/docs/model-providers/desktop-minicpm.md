# Desktop MiniCPM Provider

Desktop MiniCPM is a desktop development and validation provider behind the
Plan 10 `ModelProvider` contract. It is not the phone runtime path.

## Boundary

- Use this provider only with a local desktop HTTP server.
- Endpoint URLs must use `http://localhost`, `http://127.0.0.1`, or `http://[::1]`.
- The transport requires `Content-Length` on responses and reads exactly that
  many bytes instead of waiting for EOF.
- Do not add desktop endpoint, port, path, or process assumptions to
  `ProviderRegistry`, `ProviderControllingRuntimeClient`, or the generic
  provider contract.

## Mobile Path

The mobile production path should register `OnDeviceMiniCPMProvider` separately.
That provider should reuse the Plan 10 provider contract and route generation
through the Plan 11 C ABI into the C++ / Metal / Core ML / llama.cpp backend.

```text
Rust Runtime
  -> ProviderRegistry
      -> DesktopMiniCPMProvider   // desktop/dev validation
      -> OnDeviceMiniCPMProvider  // phone runtime path
            -> Plan 11 C ABI
            -> native backend
```

## Expected Desktop Server Shape

The desktop server should expose an OpenAI-compatible chat completions endpoint:

```text
POST /v1/chat/completions
Content-Type: application/json
Content-Length: <bytes>
```

The response must include a non-chunked JSON body:

```text
HTTP/1.1 200 OK
Content-Type: application/json
Content-Length: <bytes>

{"choices":[{"message":{"content":"..."}}]}
```

## Example Registration

```rust
let transport = LocalhostHttpTransport::new(
    "http://127.0.0.1:8000/v1/chat/completions"
)?;
let provider = DesktopMiniCPMProvider::new("minicpm", Box::new(transport));
```
