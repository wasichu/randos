#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/../.."
# Run sequentially on an otherwise quiet machine; no inference is shared
# between browser processes. Failures are recorded, and later cases still run.
for resource_case in full4_a full1 int8_1 full4_b; do
  echo "Resource case: $resource_case"
  export RESOURCE_PROFILE=1 PROVIDERS=wasm OUTPUT_TAG="$resource_case-"
  export RESULT_PATH="results/resource-$resource_case.json"
  export WASM_THREADS=4
  unset MODEL_GRAPH REFERENCE_FILE
  if [[ "$resource_case" == full1 || "$resource_case" == int8_1 ]]; then export WASM_THREADS=1; fi
  if [[ "$resource_case" == int8_1 ]]; then
    export MODEL_GRAPH=tmp/voice-browser/int8/onnx/tvtsyn_step_100ms.onnx
    export REFERENCE_FILE=int8-native.f32
  fi
  node tools/voice-browser/run.mjs || true
done
