#!/usr/bin/env bash
# TensorRT-LLM 배포 관리
# 사용법: ./scripts/20-deploy-trtllm.sh [apply|status|logs|delete]
#
# 주의: NGC 로그인 필요
# docker login nvcr.io -u '$oauthtoken' -p <NGC_API_KEY>
# kubectl create secret docker-registry ngc-secret \
#   --docker-server=nvcr.io \
#   --docker-username='$oauthtoken' \
#   --docker-password=<NGC_API_KEY> \
#   -n llm-serve
set -euo pipefail

ACTION="${1:-apply}"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(dirname "${SCRIPT_DIR}")"
NS="llm-serve"

case "${ACTION}" in
  apply)
    echo "=== TensorRT-LLM 배포 (Qwen2.5-7B-Instruct, tp_size=2) ==="
    echo "  이미지: nvcr.io/nvidia/tensorrt-llm/release:0.20.0"
    echo "  첫 실행 시 TRT 엔진 빌드로 10~20분 소요될 수 있습니다."
    kubectl apply -f "${ROOT_DIR}/k8s/trtllm/"
    echo ""
    echo "=== Rollout 대기 ==="
    kubectl rollout status deployment/trtllm -n "${NS}" --timeout=1800s
    echo ""
    kubectl get pods -n "${NS}" -l app=trtllm
    echo ""
    echo "✓ TRT-LLM 배포 완료. API 테스트: scripts/40-port-forward.sh trtllm"
    ;;

  status)
    kubectl get pods -n "${NS}" -l app=trtllm -o wide
    echo ""
    POD=$(kubectl get pod -n "${NS}" -l app=trtllm -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || echo "")
    if [[ -n "${POD}" ]]; then
      kubectl exec -n "${NS}" "${POD}" -- nvidia-smi
    fi
    ;;

  logs)
    kubectl logs -n "${NS}" -l app=trtllm -f --tail=100
    ;;

  delete)
    kubectl delete -f "${ROOT_DIR}/k8s/trtllm/" --ignore-not-found
    echo "✓ TRT-LLM 삭제 완료"
    ;;

  *)
    echo "사용법: $0 [apply|status|logs|delete]"
    exit 1
    ;;
esac
