#!/usr/bin/env bash
# KServe vLLM InferenceService 배포 관리
# 사용법: ./scripts/60-deploy-kserve-vllm.sh [apply|status|logs|delete]
set -euo pipefail

ACTION="${1:-apply}"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(dirname "${SCRIPT_DIR}")"
NS="llm-serve"
ISVC="vllm-qwen"

case "${ACTION}" in
  apply)
    echo "=== KServe ClusterServingRuntime 등록 ==="
    kubectl apply -f "${ROOT_DIR}/k8s/kserve/cluster-serving-runtime-vllm.yaml"

    echo ""
    echo "=== KServe vLLM InferenceService 배포 ==="
    kubectl apply -f "${ROOT_DIR}/k8s/kserve/vllm-inferenceservice.yaml"

    echo ""
    echo "=== InferenceService 준비 대기 (storage init + 모델 로드, 10~20분 소요) ==="
    kubectl wait inferenceservice/"${ISVC}" \
      -n "${NS}" \
      --for=condition=Ready \
      --timeout=1200s

    echo ""
    echo "=== InferenceService 상태 ==="
    kubectl get inferenceservice "${ISVC}" -n "${NS}"

    echo ""
    echo "=== 생성된 Deployment/Service 확인 ==="
    kubectl get deploy,svc -n "${NS}" -l serving.kserve.io/inferenceservice="${ISVC}"

    echo ""
    echo "✓ KServe vLLM 배포 완료. API 테스트: scripts/50-test-api.sh"
    ;;

  status)
    echo "=== InferenceService 상태 ==="
    kubectl get inferenceservice "${ISVC}" -n "${NS}"

    echo ""
    echo "=== Pod 상태 ==="
    kubectl get pods -n "${NS}" \
      -l serving.kserve.io/inferenceservice="${ISVC}" -o wide

    echo ""
    echo "=== GPU 사용 확인 ==="
    POD=$(kubectl get pod -n "${NS}" \
      -l serving.kserve.io/inferenceservice="${ISVC}" \
      -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || echo "")
    if [[ -n "${POD}" ]]; then
      kubectl exec -n "${NS}" "${POD}" -c kserve-container -- nvidia-smi
    fi
    ;;

  logs)
    echo "=== storage initializer 로그 (모델 다운로드 확인) ==="
    POD=$(kubectl get pod -n "${NS}" \
      -l serving.kserve.io/inferenceservice="${ISVC}" \
      -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || echo "")
    if [[ -n "${POD}" ]]; then
      kubectl logs -n "${NS}" "${POD}" -c storage-initializer --tail=50 2>/dev/null || true
    fi

    echo ""
    echo "=== vLLM 컨테이너 로그 ==="
    kubectl logs -n "${NS}" \
      -l serving.kserve.io/inferenceservice="${ISVC}" \
      -c kserve-container -f --tail=100
    ;;

  delete)
    echo "=== KServe vLLM 리소스 삭제 ==="
    kubectl delete -f "${ROOT_DIR}/k8s/kserve/vllm-inferenceservice.yaml" --ignore-not-found
    kubectl delete -f "${ROOT_DIR}/k8s/kserve/cluster-serving-runtime-vllm.yaml" --ignore-not-found
    echo "✓ KServe vLLM 삭제 완료"
    ;;

  *)
    echo "사용법: $0 [apply|status|logs|delete]"
    exit 1
    ;;
esac
