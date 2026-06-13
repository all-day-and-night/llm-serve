#!/usr/bin/env bash
# API 테스트 스크립트 (port-forward 실행 중인 상태에서 사용)
# 사용법: ./scripts/50-test-api.sh [vllm|trtllm|triton|sd]
#
# 전제: scripts/40-port-forward.sh <target>이 별도 터미널에서 실행 중이어야 합니다.
set -euo pipefail

TARGET="${1:-vllm}"
NS="llm-serve"

_check_jq() {
  command -v jq &>/dev/null || { echo "jq가 설치되어 있지 않습니다. brew install jq"; exit 1; }
}

_gpu_check() {
  local label="$1"
  echo ""
  echo "=== GPU 사용 확인 (nvidia-smi) ==="
  POD=$(kubectl get pod -n "${NS}" -l "app=${label}" -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || echo "")
  if [[ -n "${POD}" ]]; then
    kubectl exec -n "${NS}" "${POD}" -- nvidia-smi --query-gpu=index,name,memory.used,memory.free,utilization.gpu \
      --format=csv,noheader,nounits
  fi
}

case "${TARGET}" in
  vllm|trtllm)
    PORT=8000
    _check_jq
    echo "=== 1. 모델 목록 ==="
    curl -s http://localhost:${PORT}/v1/models | jq '.data[].id'

    echo ""
    echo "=== 2. Chat Completions (스트리밍 OFF) ==="
    curl -s http://localhost:${PORT}/v1/chat/completions \
      -H "Content-Type: application/json" \
      -d '{
        "model": "Qwen/Qwen2.5-7B-Instruct",
        "messages": [
          {"role": "user", "content": "GPU 2개로 텐서 패러럴 서빙 중인지 확인해줘. 짧게."}
        ],
        "max_tokens": 128,
        "temperature": 0.1
      }' | jq '.choices[0].message.content'

    echo ""
    echo "=== 3. 스트리밍 테스트 ==="
    curl -s http://localhost:${PORT}/v1/chat/completions \
      -H "Content-Type: application/json" \
      -d '{
        "model": "Qwen/Qwen2.5-7B-Instruct",
        "messages": [{"role": "user", "content": "1부터 5까지 세어줘."}],
        "stream": true,
        "max_tokens": 64
      }'

    _gpu_check "${TARGET}"
    ;;

  triton)
    PORT=8000
    _check_jq
    echo "=== 1. Health Check ==="
    curl -s http://localhost:${PORT}/v2/health/ready
    echo ""

    echo "=== 2. 서버 메타데이터 ==="
    curl -s http://localhost:${PORT}/v2 | jq

    echo "=== 3. 로드된 모델 목록 ==="
    curl -s http://localhost:${PORT}/v2/models | jq

    echo ""
    echo "=== 4. Metrics (Prometheus 형식) ==="
    curl -s http://localhost:8002/metrics | grep -E "^(nv_inference|nv_gpu)" | head -20

    _gpu_check "triton-trtllm"
    ;;

  sd)
    PORT=7860
    _check_jq
    echo "=== 1. 로드된 모델 확인 ==="
    curl -s http://localhost:${PORT}/sdapi/v1/sd-models | jq '.[].title'

    echo ""
    echo "=== 2. txt2img 테스트 ==="
    echo "  프롬프트: a futuristic GPU server rack in space"
    echo "  스케줄러: DPM++ 2M Karras, 20 steps (최적 품질/속도 균형)"
    RESULT=$(curl -s -X POST http://localhost:${PORT}/sdapi/v1/txt2img \
      -H "Content-Type: application/json" \
      -d '{
        "prompt": "a futuristic GPU server rack in space, cinematic, high detail",
        "negative_prompt": "blurry, low quality",
        "steps": 20,
        "sampler_name": "DPM++ 2M Karras",
        "width": 512,
        "height": 512,
        "cfg_scale": 7,
        "seed": 42
      }')

    echo "${RESULT}" | jq -r '.images[0]' | base64 -d > /tmp/output.png
    echo "  이미지 저장: /tmp/output.png"
    echo "  open /tmp/output.png  # macOS에서 확인"

    echo ""
    echo "=== 3. VRAM 사용량 ==="
    curl -s http://localhost:${PORT}/sdapi/v1/memory | jq

    _gpu_check "stable-diffusion"
    ;;

  *)
    echo "사용법: $0 [vllm|trtllm|triton|sd]"
    exit 1
    ;;
esac
