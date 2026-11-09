#!/usr/bin/env bash
set -euo pipefail

script_dir=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
state_dir=${STATE_DIR:-"$script_dir/../../../.local/llama-llmd"}
mkdir -p "$state_dir"
state_dir=$(cd -- "$state_dir" && pwd)
llama_image=${LLAMA_IMAGE:-ghcr.io/ggml-org/llama.cpp:server}
epp_image=${EPP_IMAGE:-ghcr.io/llm-d/llm-d-router-endpoint-picker:main}
envoy_image=${ENVOY_IMAGE:-envoyproxy/envoy:distroless-v1.33.2}
containers=(tech-notes-llmd-envoy tech-notes-llmd-epp tech-notes-llmd-model)
label=tech-notes.llama-llmd

wait_http() {
    local url=$1
    for ((attempt=0; attempt<90; attempt++)); do
        if curl --noproxy '*' --connect-timeout 2 --max-time 3 -fsS "$url" >/dev/null 2>&1; then return; fi
        sleep 1
    done
    printf 'Timed out waiting for %s; inspect docker logs.\n' "$url" >&2
    return 1
}

check() {
    wait_http http://127.0.0.1:28080/health
    wait_http http://127.0.0.1:29090/metrics
    wait_http http://127.0.0.1:29000/ready
    curl --noproxy '*' --max-time 30 -fsS http://127.0.0.1:28081/v1/completions \
        -H 'Content-Type: application/json' \
        -d '{"model":"llama-demo","prompt":"Once upon a time","max_tokens":16}' \
        > "$state_dir/response.json"
    curl --noproxy '*' --max-time 5 -fsS http://127.0.0.1:28080/metrics > "$state_dir/model-metrics.txt"
    curl --noproxy '*' --max-time 5 -fsS http://127.0.0.1:29090/metrics > "$state_dir/epp-metrics.txt"
    printf 'Request succeeded through Envoy and EPP. Artifacts: %s\n' "$state_dir"
}

case ${1:-help} in
up)
    [[ $(uname -s) == Linux ]] || { echo 'This script requires a Linux Docker host.' >&2; exit 1; }
    command -v docker >/dev/null
    command -v curl >/dev/null
    for name in "${containers[@]}"; do
        if docker container inspect "$name" >/dev/null 2>&1; then
            printf 'Container %s already exists. Inspect it or run this script with down.\n' "$name" >&2
            exit 1
        fi
    done
    for port in 28080 28081 29000 29002 29003 29090; do
        if (echo > /dev/tcp/127.0.0.1/"$port") >/dev/null 2>&1; then
            printf 'Port %s is already in use.\n' "$port" >&2
            exit 1
        fi
    done
    model_file=${MODEL_FILE:-"$state_dir/stories260K.gguf"}
    if [[ ! -f $model_file ]]; then
        [[ -z ${MODEL_FILE:-} ]] || { echo 'MODEL_FILE does not exist.' >&2; exit 1; }
        mirror=${HF_ENDPOINT:-https://huggingface.co}
        curl -fL --retry 2 "${mirror%/}/ggml-org/models-moved/resolve/7ae2acaf51ef0706af00804d8fdd6ae9e70829ae/tinyllamas/stories260K.gguf" -o "$model_file.download"
        mv "$model_file.download" "$model_file"
    fi
    model_file=$(realpath -- "$model_file")
    if [[ -z ${MODEL_FILE:-} ]]; then
        printf '%s  %s\n' 047bf46455a544931cff6fef14d7910154c56afbc23ab1c5e56a72e69912c04b "$model_file" | sha256sum -c -
    fi
    cat > "$state_dir/endpoints.yaml" <<'YAML'
endpoints:
  - name: llama-demo
    address: 127.0.0.1
    port: "28080"
    labels:
      model: llama-demo
      llm-d.ai/engine-type: llamacpp
YAML
    cat > "$state_dir/epp.yaml" <<'YAML'
apiVersion: llm-d.ai/v1
kind: EndpointPickerConfig
plugins:
  - name: file-discovery
    type: file-discovery
    parameters:
      path: /config/endpoints.yaml
      watchFile: true
  - type: queue-scorer
  - name: metrics-source
    type: metrics-data-source
  - name: metrics-extractor
    type: core-metrics-extractor
    parameters:
      defaultEngine: llamacpp
      engineConfigs:
        - name: llamacpp
          queuedRequestsSpec: "llamacpp:requests_deferred"
          runningRequestsSpec: "llamacpp:requests_processing"
schedulingProfiles:
  - name: default
    plugins:
      - pluginRef: queue-scorer
dataLayer:
  injectDefaults: false
  discovery:
    endpoints:
      pluginRef: file-discovery
  sources:
    - pluginRef: metrics-source
      extractors:
        - pluginRef: metrics-extractor
YAML
    created=()
    rollback() {
        for name in "${created[@]}"; do docker rm -f "$name" >/dev/null 2>&1 || true; done
    }
    trap rollback ERR INT TERM
    docker run -d --name tech-notes-llmd-model --label "$label=true" --network host \
        -v "$model_file:/models/model.gguf:ro" "$llama_image" \
        --model /models/model.gguf --alias llama-demo --metrics --host 127.0.0.1 \
        --port 28080 --no-ui --n-gpu-layers 0
    created+=(tech-notes-llmd-model)
    wait_http http://127.0.0.1:28080/health
    docker run -d --name tech-notes-llmd-epp --label "$label=true" --network host \
        -v "$state_dir:/config:ro" "$epp_image" --config-file=/config/epp.yaml \
        --pool-name=llama-demo --pool-namespace=default --grpc-port=29002 \
        --grpc-health-port=29003 --metrics-port=29090 --secure-serving=false --health-checking=true
    created+=(tech-notes-llmd-epp)
    wait_http http://127.0.0.1:29090/metrics
    docker run -d --name tech-notes-llmd-envoy --label "$label=true" --network host \
        -v "$script_dir/envoy.yaml:/etc/envoy/envoy.yaml:ro" "$envoy_image" \
        --base-id 28 --concurrency 2 -c /etc/envoy/envoy.yaml
    created+=(tech-notes-llmd-envoy)
    check
    docker inspect "${containers[@]}" --format '{{.Name}} {{.Config.Image}} {{.Image}}' > "$state_dir/images.txt"
    trap - ERR INT TERM
    ;;
check) check ;;
down)
    for name in "${containers[@]}"; do
        if [[ $(docker inspect --format '{{index .Config.Labels "tech-notes.llama-llmd"}}' "$name" 2>/dev/null || true) == true ]]; then
            docker rm -f "$name"
        fi
    done
    ;;
*) printf 'Usage: %s {up|check|down}\n' "$0" ;;
esac
