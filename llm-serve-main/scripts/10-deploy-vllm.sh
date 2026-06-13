#!/usr/bin/env bash
# vLLM 배포 관리
# 사용법: ./scripts/10-deploy-vllm.sh [apply|status|logs|delete]
set -euo pipefail

ACTION="${1:-apply}"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(dirname "${SCRIPT_DIR}")"
NS="llm-serve"

case "${ACTION}" in
  apply)
    echo "=== vLLM 배포 (Qwen2.5-7B-Instruct, TP=2) ==="
    kubectl apply -f "${ROOT_DIR}/k8s/vllm/"
    echo ""
    echo "=== Rollout 대기 (모델 다운로드로 5~15분 소요) ==="
    kubectl rollout status deployment/vllm -n "${NS}" --timeout=900s
    echo ""
    echo "=== Pod 상태 ==="
    kubectl get pods -n "${NS}" -l app=vllm
    echo ""
    echo "✓ vLLM 배포 완료. API 테스트: scripts/40-port-forward.sh vllm"
    ;;

  status)
    echo "=== vLLM Pod 상태 ==="
    kubectl get pods -n "${NS}" -l app=vllm -o wide
    echo ""
    echo "=== GPU 사용 확인 ==="
    POD=$(kubectl get pod -n "${NS}" -l app=vllm -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || echo "")
    if [[ -n "${POD}" ]]; then
      kubectl exec -n "${NS}" "${POD}" -- nvidia-smi
    fi
    ;;

  logs)
    echo "=== vLLM 로그 (tensor-parallel 초기화 확인) ==="
    kubectl logs -n "${NS}" -l app=vllm -f --tail=100
    ;;

  delete)
    echo "=== vLLM 리소스 삭제 ==="
    kubectl delete -f "${ROOT_DIR}/k8s/vllm/" --ignore-not-found
    echo "✓ vLLM 삭제 완료"
    ;;

  *)
    echo "사용법: $0 [apply|status|logs|delete]"
    exit 1
    ;;
esac
