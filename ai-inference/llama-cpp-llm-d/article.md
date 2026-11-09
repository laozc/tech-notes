# Why use llama.cpp with llm-d?

English | [中文](article.zh-CN.md)

For an AI application developer, an existing computer or GPU workstation is often the starting point
for trying a local model. The immediate concerns are whether the model fits the available hardware,
how easily it can be deployed, and how the application can call it.

As colleagues or other applications begin to use the model, maintaining the service brings
additional concerns: providing a stable address, checking whether the server can accept requests,
and reducing the effect of moving to another machine. These responsibilities become part of the
service as its use grows.

llama.cpp and llm-d address needs that arise at these stages. The former runs the model locally; the
latter provides components for request routing and related serving tasks. Starting with a model that
is easy to deploy provides a practical way to understand how they work together and when an
additional routing layer is useful.

## Deploying the model with llama.cpp

[llama.cpp](https://github.com/ggml-org/llama.cpp) is an open source project written primarily in
C/C++ for running large language models on CPUs and supported GPUs. It loads a model file and
generates responses from the supplied input. The examples here use model files in GGUF format.

llama-server is the HTTP server included in the project. It accepts application requests and returns
model output, making a locally running model available to other programs. It is the component
connected to llm-d in this article.

Simple deployment is one reason to choose it. On a supported system, a compatible llama-server
executable and a GGUF model file are sufficient to begin setting up a CPU service. A single command
loads the model and exposes its HTTP API. Container images provide another deployment option.

Hardware flexibility is another advantage. A small model can run on a CPU, while supported GPUs can
serve larger workloads. GPU deployment still requires a compatible build, drivers, and libraries. An
existing workstation can remain the model host while other service components run elsewhere.

llama-server provides an OpenAI-compatible chat interface, which simplifies integration with
applications already using that interface. Direct access is often sufficient for a single
application and model. llm-d becomes relevant when several clients need a common address, or when
requests need to be assigned to different model servers.

## How llm-d routes requests to the model

[llm-d](https://github.com/llm-d/llm-d) provides infrastructure for model serving, including request
routing. Understanding how llama-server connects to it starts with the roles of Envoy and EPP: Envoy
receives and forwards requests, while EPP selects the model server that handles them.

In the llm-d routing architecture described here, an application first connects to Envoy. Before
forwarding the request, Envoy asks EPP for a destination. EPP stands for Endpoint Picker and is part
of [llm-d Router](https://github.com/llm-d/llm-d-router). It chooses from available servers
according to configured policies, which can consider the number of requests waiting at each server.

Once a destination is selected, Envoy sends the request to that llama-server. The generated answer
returns through Envoy. EPP participates in server selection; Envoy forwards the answer.

Connecting llama.cpp therefore means making llama-server discoverable to llm-d, identifying the
model it serves, and exposing its operating state. llama-server continues to load and run the model.

For development and learning, a tiny CPU model provides a low-cost way to test llm-d configuration.
It can return real responses while server discovery and request forwarding are checked. Model
quality is secondary in this setting; the purpose is to observe how requests pass through the
service. The accompanying script provides this setup.

The model and routing components can also run on different machines. For example, llama-server can
run on a Windows workstation with an RX 7800 XT, while Envoy and EPP run on Linux. Applications send
requests to the Linux machine. Envoy forwards them to the workstation selected by EPP and returns
the generated answers. This connects the Windows model server to llm-d without moving the model to
Linux.

With copies of the same model on multiple servers, the routing layer can use their queue sizes to
assign requests. The tests here used one model server at a time and do not establish how requests
would be distributed across multiple servers.

## Connecting the two

The initial configuration runs one model per llama-server process and assigns it a model name:

```sh
llama-server --model /models/model.gguf --alias llmd-demo --metrics --host 0.0.0.0 --port 8000
```

The alias **llmd-demo** must match the model name in client requests and the router configuration.
One model per process keeps the meaning of the server's request counts clear. Model switching can be
addressed separately.

The routing components need to check whether the model is ready and collect information about its
current workload. llama-server provides **/health**, which returns 503 during loading and 200 when
ready. Enabling **--metrics** exposes **/metrics**, including counts of waiting and active
requests.[^api]

The following configuration maps those counts to EPP's request fields:

```yaml
engineConfigs:
  - name: llamacpp
    queuedRequestsSpec: "llamacpp:requests_deferred"
    runningRequestsSpec: "llamacpp:requests_processing"
```

The first count represents requests waiting inside llama-server; the second represents requests
being processed. The example uses queue size to score servers.[^router] These counts do not measure
model-cache memory use, so policies requiring that information are excluded.

Server addresses can be supplied through Kubernetes or a file. The [kind model
manifest](evidence/kind-model.yaml) records the model deployment used in the Kubernetes test. The
accompanying script supplies the server list through a file and runs without a cluster.

## Running the example

The example uses a tiny CPU model to check request forwarding, rather than answer quality or service
performance. On a Linux Docker host, run the [Bash script](example/README.md) from the repository
root to start the services, check a request, and remove the containers:

```sh
bash ai-inference/llama-cpp-llm-d/example/run.sh up
bash ai-inference/llama-cpp-llm-d/example/run.sh check
bash ai-inference/llama-cpp-llm-d/example/run.sh down
```

The script downloads the model from Hugging Face and verifies the file before use. Generated
configuration, responses, and measurements are saved under **.local/llama-llmd**. The usage notes
describe ports, image selection, and using a local GGUF model.

Startup, repeated request checking, and cleanup passed on Linux Docker using cached images and a
model file with verified integrity.[^script] The download step was not repeated in that run. A
separate kind test sent two concurrent requests; both returned 200 with the expected model
name.[^kind]

The Windows model server also returned a successful response through the Linux routing components.
The following fields are taken from a response summary with the local model path removed:[^windows]

```json
{
  "http_status": 200,
  "route": "Linux Envoy -> Linux EPP -> Windows llama-server",
  "model_file": "Qwen3VL-8B-Instruct-Q4_K_M.gguf",
  "finish_reason": "stop"
}
```

These checks establish the basic single-model request path. Streaming responses, request
cancellation, timeout handling, and selection among multiple servers are outside the scope of these
checks. The [supporting files](evidence/README.md) contain the configurations and results.

## Limits and common errors

Adding a routing layer does not change the amount of text a model can process in one request. A
request that exceeds the context limit can still fail in llama-server:[^context]

```json
{
  "error": {
    "code": 500,
    "message": "Context size has been exceeded.",
    "type": "server_error"
  }
}
```

A short prompt and a limited response length are suitable for initial connectivity checks. If
**/metrics** returns 501 with a message requesting **--metrics**, enable that option before
investigating the monitoring configuration.[^metrics]

A zero waiting-request count can be a valid observation: a short request may finish between
measurements. A graph with no data requires a different check, such as confirming that the
monitoring tool can reach the server and that the metric name is correct.

Model switching requires additional handling. When llama-server manages multiple models,
**/metrics** requires a **model** parameter identifying the model to measure. The configuration
above does not handle this automatically. Sharing model caches across machines and separating the
stages of response generation also remain outside the demonstrated setup.

The setup described here is intended only for development, learning, and functional testing. It is
not a production deployment guide. This is an independent integration and does not represent
official llama.cpp support in llm-d.

[^api]: [llama-server API reference](https://github.com/ggml-org/llama.cpp/blob/master/tools/server/README.md), covering health checks, chat requests, and Prometheus metrics.
[^router]: [Router configuration](evidence/kind-router-values.yaml), including request-count mapping and scoring policies.
[^script]: The **script** section of the [test results](evidence/results.json) records script checks and image IDs.
[^kind]: The **kind** section of the [test results](evidence/results.json) records concurrent responses and sampled metrics.
[^windows]: The **windows** section of the [test results](evidence/results.json). The excerpt uses a sanitized summary and omits token usage.
[^context]: The **context_limit** section of the [error responses](evidence/errors.json). The excerpt preserves the complete response body with formatting added.
[^metrics]: The **metrics_disabled** section of the [error responses](evidence/errors.json).
