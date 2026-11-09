# 为什么把 llama.cpp 接入 llm-d？

[English](article.md) | 中文

开发 AI 应用时，通常会先在自己的电脑或工作站上部署模型，确认现有硬件能够运行，再把模型接入应用。这一阶段，部署是否方便、调用接口是否易用，是最直接的考虑。

等到模型需要供同事或其他应用使用，问题就不只是模型本身了。应用应该访问哪个地址？模型换到另一台机器后，是否需要逐个修改应用配置？如果有多台服务器，又该如何分配请求？这些需求会随着服务的使用范围扩大而逐渐出现。

llama.cpp 和 llm-d 可以衔接这两个阶段：先用 llama.cpp 在现有硬件上部署模型，再接入 llm-d 的请求路由。下面从这条路径出发，介绍两者如何配合，以及这种组合适合哪些场景。

## 用 llama.cpp 部署模型

[llama.cpp](https://github.com/ggml-org/llama.cpp) 是一个主要用 C/C++ 编写的开源项目，可以在 CPU 和多种 GPU 上运行大语言模型。它读取模型文件，根据输入生成回答。本文使用的是 GGUF 格式的模型文件。

项目自带的 llama-server 将这项能力封装成 HTTP 服务。应用向它发送请求，就能获得模型的回答，无需直接调用底层代码。本文接入 llm-d 的正是这个服务程序。

llama.cpp 的一个优点是部署比较简单。在受支持的系统上，准备好兼容的 llama-server 程序和模型文件，一条命令就能开始运行 CPU 模型服务，也可以使用容器镜像。使用 GPU 时，仍需准备匹配的程序、驱动和运行依赖，模型可以继续部署在工作站上。

llama-server 提供兼容 OpenAI 格式的聊天接口，便于已经使用这类接口的应用接入。对于一个应用调用一个模型的情况，直接访问 llama-server 就已足够。需要统一管理访问入口，或在多台模型服务器之间分配请求时，再引入 llm-d 更有意义。

## llm-d 如何将请求送到模型

[llm-d](https://github.com/llm-d/llm-d) 为模型服务提供请求路由等基础设施。理解 llama-server 如何接入，需要先看 llm-d 中 Envoy 和 EPP 的分工：Envoy 负责接收和转发请求，EPP 负责选择处理请求的模型服务器。

在这里介绍的 llm-d 路由架构中，应用首先访问 Envoy。Envoy 在转发请求前，会向 EPP 查询目标服务器。EPP 的全称是 Endpoint Picker，它根据可用服务器列表和配置的策略作出选择，例如参考各台服务器的排队请求数。

确定目标后，Envoy 将请求发送给对应的 llama-server。模型生成的回答再经 Envoy 返回应用。EPP 参与服务器选择，回答本身由 Envoy 转发。

因此，接入 llama.cpp 的关键，是让 llm-d 能够找到 llama-server、识别它提供的模型，并读取它的运行状态。模型仍由 llama-server 加载和运行。

这也说明了为什么可以从小模型开始学习 llm-d。检查服务器是否被发现、请求是否正确转发，并不需要大模型或昂贵的 GPU。一个能返回真实响应的 CPU 模型，就足以用于这些基础检查。配套脚本采用的就是这种方式。

模型和路由组件也可以部署在不同机器上。例如，在装有 RX 7800 XT 的 Windows 工作站上运行 llama-server，在 Linux 机器上运行 Envoy 和 EPP。应用向 Linux 机器发送请求，Envoy 根据 EPP 的选择将请求转发到工作站，再把模型生成的回答返回应用。这样就能让 Windows 工作站上的模型接入 llm-d，而无需把模型迁移到 Linux。

多台服务器运行同一模型时，可以根据各自的排队情况分配请求。本文的验证范围限于单台模型服务器，未验证多服务器之间的分配效果。

## 接入配置

先让每个 llama-server 进程加载一个模型，并设置供应用使用的名称：

```sh
llama-server --model /models/model.gguf --alias llmd-demo --metrics --host 0.0.0.0 --port 8000
```

这里的别名 **llmd-demo** 需要与应用请求和路由配置中的模型名称保持一致。一个进程先运行一个模型，也便于明确各项请求统计对应的是哪个模型。模型切换可以在后续扩展。

除了服务器地址，llm-d 还需要知道模型是否就绪，以及服务器当前有多少请求。llama-server 的 **/health** 在模型加载期间返回 503，就绪后返回 200。启动时加上 **--metrics**，就能通过 **/metrics** 获取排队请求数、正在处理的请求数等指标。[^api]

下面的配置指定 EPP 应读取哪些指标：

```yaml
engineConfigs:
  - name: llamacpp
    queuedRequestsSpec: "llamacpp:requests_deferred"
    runningRequestsSpec: "llamacpp:requests_processing"
```

**llamacpp:requests_deferred** 表示在 llama-server 内部等待的请求数，**llamacpp:requests_processing** 表示正在处理的请求数。示例采用基于排队情况的评分策略。[^router]这两个指标无法说明模型缓存占用了多少内存，因此没有启用需要缓存用量的策略。

服务器列表可以由 Kubernetes 提供，也可以保存在文件中。[kind 配置](evidence/kind-model.yaml)是验证时使用的模型部署文件；配套脚本则使用文件保存服务器列表，可以在没有 Kubernetes 集群的环境中运行。

## 运行配套示例

配套示例使用一个小型 CPU 模型验证请求转发，不用于评估模型的回答质量或服务性能。在 Linux Docker 主机上，从本仓库根目录依次执行以下命令，即可启动服务、检查请求并清理容器：

```sh
bash ai-inference/llama-cpp-llm-d/example/run.sh up
bash ai-inference/llama-cpp-llm-d/example/run.sh check
bash ai-inference/llama-cpp-llm-d/example/run.sh down
```

脚本从 Hugging Face 下载模型并检查文件完整性，运行时生成的配置、响应和指标保存在 **.local/llama-llmd**。[使用说明](example/README.md)列出了端口、镜像设置和使用本地 GGUF 模型的方法。

脚本的启动、请求检查和容器清理已在 Linux Docker 上测试通过。该次测试使用缓存镜像和已验证完整性的模型文件，没有重复执行下载。[^script]kind 环境中也进行了两个并发请求的检查，均返回 200，响应中的模型名称与请求一致。[^kind]

Windows 上的 llama-server 同样通过 Linux 上的路由组件返回了成功响应。下面摘录了响应摘要中的几个字段，本机模型路径已移除：[^windows]

```json
{
  "http_status": 200,
  "route": "Linux Envoy -> Linux EPP -> Windows llama-server",
  "model_file": "Qwen3VL-8B-Instruct-Q4_K_M.gguf",
  "finish_reason": "stop"
}
```

这些结果说明基础单模型请求路径可以工作。流式响应、请求取消、超时处理和多服务器选择不在本次验证范围内。配置和测试结果见[配套资料](evidence/README.md)。

## 使用限制与常见错误

接入 llm-d 不会改变模型的上下文长度限制。请求中的文本过长时，llama-server 仍可能返回以下错误：[^context]

```json
{
  "error": {
    "code": 500,
    "message": "Context size has been exceeded.",
    "type": "server_error"
  }
}
```

初次检查连接时，宜先使用较短的提示词，并限制回答长度。如果 **/metrics** 返回 501，提示需要 **--metrics**，应先检查启动参数，启用指标接口后再排查监控配置。[^metrics]

监控图表中的排队请求数为零，不一定意味着指标有问题。较短的请求可能在两次采集之间就已完成。图表完全没有数据时，则需要检查监控工具能否访问服务器，以及指标名称是否正确。

在同一服务中切换模型还需要单独处理。llama-server 管理多个模型时，**/metrics** 要求携带 **model** 参数，以便获取对应模型的指标。上述配置尚未自动处理这一点。跨机器共享模型缓存，或将生成回答的不同阶段分开运行，也超出了本文已验证的范围。

本文方案仅用于开发、学习和功能验证，不作为生产部署方案。该接入方式属于独立尝试，不代表 llm-d 已官方支持 llama.cpp。

[^api]: [llama-server 接口文档](https://github.com/ggml-org/llama.cpp/blob/master/tools/server/README.md)，包含健康检查、聊天接口和 Prometheus 指标说明。
[^router]: [路由配置](evidence/kind-router-values.yaml)，包含请求数映射和评分策略。
[^script]: [测试结果](evidence/results.json)的 **script** 部分，记录脚本检查结果与镜像 ID。
[^kind]: [测试结果](evidence/results.json)的 **kind** 部分，记录并发请求响应和指标采样。
[^windows]: [测试结果](evidence/results.json)的 **windows** 部分。正文片段取自脱敏后的摘要，省略了 token 用量。
[^context]: [错误响应](evidence/errors.json)的 **context_limit** 部分，正文保留完整响应体，仅调整排版。
[^metrics]: [错误响应](evidence/errors.json)的 **metrics_disabled** 部分。
