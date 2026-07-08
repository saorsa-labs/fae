# Third-Party Licenses & Acknowledgements

This file collects the third-party notices Fae is required to carry for the
software and model artifacts it distributes. Fae itself is licensed under the
GNU AGPL v3 (see `LICENSE`); this file covers the *additional* obligations of
its dependencies and model weights.

---

## Parakeet ASR — NVIDIA parakeet-tdt-0.6b-v2

Fae's optional dedicated ASR engine (`asr.engine = "parakeet"`) uses the
**NVIDIA parakeet-tdt-0.6b-v2** English speech-recognition model, licensed under
**Creative Commons Attribution 4.0 International (CC-BY-4.0)**:

- Model: <https://huggingface.co/nvidia/parakeet-tdt-0.6b-v2>
- License: <https://creativecommons.org/licenses/by/4.0/legalcode.en>
- Licensor: NVIDIA.

**CC-BY-4.0 obligations Fae satisfies here:**

1. **Attribution** — Fae attributes NVIDIA as the licensor and names the model
   (`parakeet-tdt-0.6b-v2`) with a link to the CC-BY-4.0 license, in this file
   and in every `models.lock` artifact entry that ships the weights
   (`license = "cc-by-4.0 …"`).
2. **Indicate changes** — Fae does **not** distribute NVIDIA's original
   PyTorch/NeMo checkpoint. It distributes an **Int8 ONNX export** produced by
   Fangjun Kuang (`csukuangfj`) at
   <https://huggingface.co/csukuangfj/sherpa-onnx-nemo-parakeet-tdt-0.6b-v2-int8>,
   which is a derived/adapted form (ONNX export + Int8 dynamic quantization) of
   the original model. This is the "indicate changes" notice required by
   CC-BY-4.0 §3(b): the model was adapted (format-converted to ONNX and
   Int8-quantized) by `csukuangfj`, and Fae uses that adaptation unmodified.
3. **No additional restrictions** — CC-BY-4.0 has no share-alike clause, so
   Fae's AGPL-3.0 distribution is not affected.

The four artifact files (`encoder.int8.onnx`, `decoder.int8.onnx`,
`joiner.int8.onnx`, `tokens.txt`, ~661 MB total) are pinned in `models.lock`
under the `sherpa-onnx` loader and fail-closed verified by SHA-256 before load.

### Upgrade path

English-only **parakeet-tdt-0.6b-v2** is the chosen model: Fae's fallback ASR is
English, and v2 has the most mature ONNX tooling and the smallest footprint.
When multilingual ASR is required, the drop-in successor is
[**nvidia/parakeet-tdt-0.6b-v3**](https://huggingface.co/nvidia/parakeet-tdt-0.6b-v3)
(25 European languages) — same `sherpa-onnx` transducer config
(`model_config.transducer`), different artifact set. Swap the four `models.lock`
entries and the pinned repo/revision to enable it.

---

## sherpa-onnx — speech-recognition runtime

The native inference runtime for Parakeet is the
[**sherpa-onnx**](https://github.com/k2-fsa/sherpa-onnx) Rust crate
([crates.io](https://crates.io/crates/sherpa-onnx)), pinned at `1.13.4`:

- License: **Apache License 2.0** — <https://www.apache.org/licenses/LICENSE-2.0>
- Copyright: the k2-fsa / next-gen Kaldi authors and Xiaomi Corporation.

sherpa-onnx bundles ONNX Runtime and a C++ core; its build script links prebuilt
static libraries for macOS arm64/x86_64 and Linux x86_64/aarch64. The pinned
crate version (`1.13.4`) is the runtime-integrity boundary for the *native*
libraries; `models.lock` covers the *model* artifacts (see the runtime-integrity
note in `.pi-subagents/deliverables/builder-integration.md`).

On Apple Silicon, onnxruntime's CoreML execution provider falls back to CPU for
Parakeet's FastConformer-transducer operators (k2-fsa/sherpa-onnx issue #152), so
Parakeet runs CPU-bound — correct, but without Apple-GPU acceleration. Linux may
use the CUDA execution provider.
