#!/usr/bin/env bash
# Triton + TensorRT-LLM 배포 관리
# 사용법: ./scripts/30-deploy-triton.sh [apply|status|logs|delete]
#
# 주의: Triton은 model-repository가 준비된 후 기동해야 합니다.
# PVC 마운트 후 /models 경로에 config.pbtxt + engine 파일을 올려야 합니다.
# 상세 구조: k8s/triton/deployment.yaml 주석 참조
set -euo pipefail

ACTION="${1:-apply}"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(dirname "${SCRIPT_DIR}")"
NS="llm-serve"

case "${ACTION}" in
  apply)
    echo "=== Triton PVC 생성 ==="
    kubectl apply -f "${ROOT_DIR}/k8s/triton/pvc.yaml"
    kubectl get pvc triton-model-repository-pvc -n "${NS}"
    echo ""
    echo "=== Triton Deployment + Service 생성 ==="
    kubectl apply -f "${ROOT_DIR}/k8s/triton/deployment.yaml"
    kubectl apply -f "${ROOT_DIR}/k8s/triton/service.yaml"
    echo ""
    echo "=== Rollout 대기 ==="
    kubectl rollout status deployment/triton-trtllm -n "${NS}" --timeout=600s
    echo ""
    kubectl get pods -n "${NS}" -l app=triton-trtllm
    echo ""
    echo "✓ Triton 배포 완료. API 테스트: scripts/40-port-forward.sh triton"
    ;;

  status)
    kubectl get pods -n "${NS}" -l app=triton-trtllm -o wide
    echo ""
    POD=$(kubectl get pod -n "${NS}" -l app=triton-trtllm -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || echo "")
    if [[ -n "${POD}" ]]; then
      kubectl exec -n "${NS}" "${POD}" -- nvidia-smi
    fi
    ;;

  logs)
    kubectl logs -n "${NS}" -l app=triton-trtllm -f --tail=100
    ;;

  delete)
    kubectl delete -f "${ROOT_DIR}/k8s/triton/" --ignore-not-found
    echo "  PVC는 데이터 보호를 위해 삭제하지 않았습니다."
    echo "  PVC 삭제: kubectl delete pvc triton-model-repository-pvc -n ${NS}"
    echo "✓ Triton 삭제 완료"
    ;;

  *)
    echo "사용법: $0 [apply|status|logs|delete]"
    exit 1
    ;;
esac
