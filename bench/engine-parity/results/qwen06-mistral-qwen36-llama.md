# Engine Parity Result

- status: `PASS`
- case: `weather-tool-paris`
- primary: `mistral.rs` / `Qwen/Qwen3-0.6B`
- fallback: `llama.cpp` / `qwen-3.6-dense-8bit`
- hardware: `Apple M5 Max`
- OS: `macOS 26.4`
- command: `cargo run --manifest-path bench/engine-parity/Cargo.toml -- run-mistral bench/engine-parity/results/qwen36-llama-probe.json Qwen/Qwen3-0.6B bench/engine-parity/results/qwen06-mistral-qwen36-llama.json`
- fallback source: live `llama-server` on `127.0.0.1:62447`

```json
{
  "case": {
    "id": "weather-tool-paris",
    "prompt": "What is the weather in Paris? Use the get_weather tool.",
    "expected_tool": {
      "name": "get_weather",
      "arguments": {
        "city": "Paris"
      }
    }
  },
  "primary": {
    "provider": "mistral.rs",
    "model": "Qwen/Qwen3-0.6B",
    "text": "\n\n<tool_call>\n{\"name\": \"get_weather\", \"arguments\": {\"city\": \"Paris\"}}\n</tool_call>",
    "tool_call": {
      "name": "get_weather",
      "arguments": {
        "city": "Paris"
      }
    },
    "ttft_ms": 158,
    "decode_tokens_per_second": 21.444740060276093
  },
  "fallback": {
    "provider": "llama.cpp",
    "model": "qwen-3.6-dense-8bit",
    "text": "",
    "tool_call": {
      "name": "get_weather",
      "arguments": {
        "city": "Paris"
      }
    },
    "ttft_ms": 25327,
    "decode_tokens_per_second": 20.836442149530757
  }
}
```

