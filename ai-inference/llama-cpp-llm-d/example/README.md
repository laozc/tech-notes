# Run llama-server with llm-d

This Bash entry point starts a small CPU model, the llm-d Endpoint Picker, and Envoy on a Linux
Docker host for development, learning, and functional testing. It uses file discovery and runs
without Kubernetes. Install Bash, Docker,
curl, realpath, and sha256sum, and ensure your user can access Docker.

From the repository root:

```sh
bash ai-inference/llama-cpp-llm-d/example/run.sh up
bash ai-inference/llama-cpp-llm-d/example/run.sh check
bash ai-inference/llama-cpp-llm-d/example/run.sh down
```

**up** downloads the tiny **stories260K.gguf** model through **https://huggingface.co**, checks its
SHA-256, starts three dedicated containers, and sends a completion through Envoy and EPP. **check**
repeats the readiness and request checks and saves responses and metrics. **down** removes
containers carrying this script's ownership label and retains the downloaded model and captured
output. The default runtime directory is **.local/llama-llmd**, excluded from Git.

The script reserves local ports **28080** for llama-server, **28081** for Envoy requests, **29000**
for Envoy admin, **29002** and **29003** for EPP gRPC services, and **29090** for EPP metrics. It
uses Linux host networking and binds the public request listener and model endpoint to loopback.
This script has been designed for Linux Docker; native Windows and Podman execution have not been
validated.

Override **HF_ENDPOINT** to choose another mirror, **MODEL_FILE** to use a local GGUF, or
**STATE_DIR** to choose another output directory. A custom model must support the completion
endpoint and fit available CPU memory. Override **LLAMA_IMAGE**, **EPP_IMAGE**, and **ENVOY_IMAGE**
to select specific image references, preferably digests. The defaults use the llama.cpp **server**
tag, EPP **main**, and Envoy **distroless-v1.33.2**. These tags can change; each successful startup
saves the actual image references and local image IDs in **images.txt**.

The Envoy configuration is adapted from the no-Kubernetes routing example in the
[llm-d repository](https://github.com/llm-d/llm-d), using the local source snapshot
**dcf367cc40e8b36e2b3fb6b95aa561add0378de2** and dedicated loopback ports. The snapshot identifier
records provenance; this example includes the configuration it needs. Kubernetes configuration and
selected responses are kept as [supporting evidence](../evidence/README.md). A successful completion
checks the basic request path. Evaluating queue-based choices requires multiple model servers and
a suitable workload.
