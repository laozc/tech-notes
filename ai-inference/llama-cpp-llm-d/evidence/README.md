# Supporting evidence

Selected configuration and response records for the [article](../article.md).
The [runnable example](../example/README.md) contains the startup script and Envoy configuration.

| File | Contents |
| --- | --- |
| [kind-model.yaml](kind-model.yaml) | Model deployment and readiness check |
| [kind-router-values.yaml](kind-router-values.yaml) | Router settings and request-count mapping |
| [results.json](results.json) | Script, kind, and Windows response summaries |
| [errors.json](errors.json) | Context-limit and metrics-disabled response bodies |
| [windows-metrics.txt](windows-metrics.txt) | Windows Prometheus response captured while idle |

The result summaries retain request outcomes, token usage, sampled counts, and recorded image IDs.
The kind summary omits the full list of unrelated EPP metric names.
The Windows summary removes the local model path.

The kind model was **stories260K.gguf**, from **ggml-org/models-moved** revision
**7ae2acaf51ef0706af00804d8fdd6ae9e70829ae**, with SHA-256
**047bf46455a544931cff6fef14d7910154c56afbc23ab1c5e56a72e69912c04b**.
The Windows backend used **Qwen3VL-8B-Instruct-Q4_K_M.gguf** and an RX 7800 XT.
The kind node image was **kindest/node:v1.26.3**; the llama-server base image was
**ghcr.io/ggml-org/llama.cpp:server**, and Envoy was **envoyproxy/envoy:distroless-v1.33.2**.
