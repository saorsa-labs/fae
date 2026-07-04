# Shared llama.cpp Runtime

Fae, Pi, and Llama.app should prefer one running `llama-server` when practical, and only keep separate sidecars when isolation is required.

## Recommended local router

Use Llama.app / `llama serve` as the shared router on loopback:

```bash
llama serve --port 8081
```

Current Llama.app config lives at:

```text
~/Library/Application Support/Llama/models.ini
```

On this machine it points model files at the Hugging Face cache:

```text
~/.cache/huggingface/hub/...
```

## Pi

The Hugging Face Pi extension is installed as:

```text
git:github.com/huggingface/pi-llama
```

It reads `LLAMA_BASE_URL` and defaults to `http://localhost:8080/v1`, so point it at the shared router:

```bash
export LLAMA_BASE_URL=http://127.0.0.1:8081/v1
pi
```

The older `npm:pi-llama-cpp` extension is also installed. It uses `llamaServerUrl` / `LLAMA_SERVER_URL` instead. Avoid enabling both against the same server unless duplicate Pi providers are desired.

## Fae

Fae's default production behavior is still safest: it starts a Fae-owned `llama-server` sidecar on port `18080`, with fail-closed runtime/model checks and cache storage under:

```text
~/Library/Application Support/fae/models/llamacpp
```

To opt into a shared server, set:

```bash
export FAE_LLAMA_SHARED_SERVER_URL=http://127.0.0.1:8081
```

Fae probes `/health` and `/v1/models`. If the shared server is healthy, Fae attaches to it. If it is not healthy, Fae falls back to its owned sidecar.

If the shared router advertises a model ID different from Fae's default alias, Fae selects the first advertised model. To pin one explicitly:

```bash
export FAE_MODEL_ID='gemma-4-e4b-it:Q4_K_M'
```

Attached shared-server mode cannot perform daemon-managed model reloads or personal LoRA hot swaps; those require the Fae-owned sidecar.

## Disk hygiene

Do not blindly delete models. Current likely roots are:

```text
~/.cache/huggingface/hub/                         # Llama.app / HF tooling
~/Library/Application Support/fae/models/llamacpp # Fae-owned sidecar cache
~/llama-spike/gguf/                               # scratch validation artifacts
```

Choose one canonical long-term GGUF root, then symlink or re-point configs. Treat `~/llama-spike/gguf` as scratch unless a model exists only there.
