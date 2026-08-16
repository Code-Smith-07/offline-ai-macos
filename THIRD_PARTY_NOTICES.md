# Third-party notices

Offline AI for macOS combines upstream source, runtime components, and optional model files. This notice is informational; the license texts and notices shipped with each component control.

| Component/resource | Role | License / credit |
| --- | --- | --- |
| [Open WebUI](https://github.com/open-webui/open-webui) | Web interface, backend, RAG, chat, and most application functionality | Open WebUI License; historical portions may retain BSD-3-Clause/MIT terms. See `LICENSE`, `LICENSE_NOTICE`, and `LICENSE_HISTORY`. |
| [Ollama](https://github.com/ollama/ollama) | Local model server and GGUF runtime | MIT |
| [Kokoro-82M](https://huggingface.co/hexgrad/Kokoro-82M) | Text-to-speech model and voice tensors | Apache-2.0; review the model card and repository files for asset-specific notices |
| [Kokoro ONNX](https://huggingface.co/onnx-community/Kokoro-82M-v1.0-ONNX) | Browser-compatible quantized speech model | Apache-2.0/model repository terms |
| [kokoro-js](https://github.com/hexgrad/kokoro) | Kokoro processing and reference implementation | Apache-2.0 |
| [Transformers.js](https://github.com/huggingface/transformers.js) | Browser-side model loading and preprocessing | Apache-2.0 |
| [ONNX Runtime](https://github.com/microsoft/onnxruntime) | WASM inference runtime | MIT |
| [Svelte](https://github.com/sveltejs/svelte) | Frontend framework | MIT |
| [Vite](https://github.com/vitejs/vite) | Frontend build system | MIT |
| [Python](https://www.python.org/) | Bundled backend runtime | Python Software Foundation License |
| Apple Cocoa and WebKit | Native macOS shell | Apple platform SDK terms |
| Hugging Face Hub | Optional source of user-supplied models | Each model has an independent license; Hugging Face hosting does not grant a single blanket model license |

The full dependency graphs in `package-lock.json`, `uv.lock`, and the packaged Python environment contain additional transitive components under their own licenses. Builders and redistributors should generate and retain a software bill of materials appropriate to the exact build.

## Model files

Language-model files under a user's Ollama or Hugging Face directories are not part of this source distribution and are not covered by this project's licenses. The Kokoro build script downloads a pinned set of runtime assets; its Apache-2.0 license is retained at `static/models/kokoro/LICENSE` and is bundled into the application.

## Branding

The Open WebUI icon is reused to identify and credit the upstream interface. It is not offered under the dual license for original Offline AI additions. Open WebUI, Ollama, Hugging Face, Apple, and all other names and logos are trademarks of their respective owners.
