#!/usr/bin/env bash
# 로컬 → K8s Service port-forward
# 사용법: ./scripts/40-port-forward.sh [vllm|trtllm|triton|sd]
set -euo pipefail

TARGET="${1:-vllm}"
NS="llm-serve"

case "${TARGET}" in
  vllm)
    echo "=== vLLM port-forward: http://localhost:8000 ==="
    echo "  /v1/models, /v1/chat/completions (OpenAI 호환)"
    kubectl port-forward svc/vllm -n "${NS}" 8000:8000
    ;;

  trtllm)
    echo "=== TensorRT-LLM port-forward: http://localhost:8000 ==="
    echo "  /v1/models, /v1/chat/completions (OpenAI 호환)"
    kubectl port-forward svc/trtllm -n "${NS}" 8000:8000
    ;;

  triton)
    echo "=== Triton port-forward: http=8000, gRPC=8001, metrics=8002 ==="
    echo "  /v2/health/ready, /v2/models"
    kubectl port-forward svc/triton-trtllm -n "${NS}" 8000:8000 8001:8001 8002:8002
    ;;

  sd)
    echo "=== Stable Diffusion port-forward: http://localhost:7860 ==="
    echo "  /sdapi/v1/txt2img, /sdapi/v1/img2img"
    kubectl port-forward svc/stable-diffusion -n "${NS}" 7860:7860
    ;;

  *)
    echo "사용법: $0 [vllm|trtllm|triton|sd]"
    echo ""
    echo "  vllm    → localhost:8000 (OpenAI 호환 API)"
    echo "  trtllm  → localhost:8000 (OpenAI 호환 API)"
    echo "  triton  → localhost:8000/8001/8002"
    echo "  sd      → localhost:7860 (A1111 API)"
    exit 1
    ;;
esac
