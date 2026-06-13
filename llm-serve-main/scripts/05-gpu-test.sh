#!/usr/bin/env bash
# GPU 테스트 Pod 실행 → nvidia-smi 로그 확인 → 삭제
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(dirname "${SCRIPT_DIR}")"

echo "=== GPU 테스트 Pod 실행 ==="
kubectl apply -f "${ROOT_DIR}/k8s/common/gpu-test.yaml"

echo ""
echo "=== Pod 완료 대기 ==="
kubectl wait pod/gpu-test -n llm-serve \
  --for=condition=Succeeded \
  --timeout=120s 2>/dev/null || \
kubectl wait pod/gpu-test -n llm-serve \
  --for=jsonpath='{.status.phase}'=Failed \
  --timeout=120s || true

echo ""
echo "=== nvidia-smi 출력 ==="
kubectl logs gpu-test -n llm-serve

echo ""
echo "=== 테스트 Pod 삭제 ==="
kubectl delete pod gpu-test -n llm-serve --ignore-not-found

echo ""
echo "✓ GPU 테스트 완료"
echo "  A10G 4개 (g5.12xlarge) 표시 확인 후 다음 단계 진행"
echo "  Option A: scripts/10-deploy-vllm.sh apply"
echo "  Option B: scripts/20-deploy-trtllm.sh apply"
echo "  Option C: scripts/30-deploy-triton.sh apply"
echo "  Option D: scripts/35-deploy-sd.sh apply"
