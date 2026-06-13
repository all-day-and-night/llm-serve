#!/usr/bin/env bash
# Stable Diffusion (AUTOMATIC1111 --api 모드) 배포 관리
# 사용법: ./scripts/35-deploy-sd.sh [apply|status|logs|delete]
#
# 이미지 생성 최적화 기법 상세: docs/sd-optimization.md
# GPU 전략: nvidia.com/gpu: 1 per Pod (replicas: 2로 늘리면 2 GPU 동시 활용)
set -euo pipefail

ACTION="${1:-apply}"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(dirname "${SCRIPT_DIR}")"
NS="llm-serve"

case "${ACTION}" in
  apply)
    echo "=== Stable Diffusion PVC 생성 (모델 캐시) ==="
    kubectl apply -f "${ROOT_DIR}/k8s/stable-diffusion/pvc.yaml"
    kubectl get pvc sd-model-cache-pvc -n "${NS}"
    echo ""
    echo "=== Stable Diffusion Deployment + Service 생성 ==="
    echo "  이미지: ghcr.io/ai-dock/stable-diffusion-webui"
    echo "  최적화: xFormers + Flash Attention + FP16 (기본 활성화)"
    echo "  모델 다운로드로 첫 기동은 5~10분 소요됩니다."
    kubectl apply -f "${ROOT_DIR}/k8s/stable-diffusion/deployment.yaml"
    kubectl apply -f "${ROOT_DIR}/k8s/stable-diffusion/service.yaml"
    echo ""
    echo "=== Rollout 대기 ==="
    kubectl rollout status deployment/stable-diffusion -n "${NS}" --timeout=900s
    echo ""
    kubectl get pods -n "${NS}" -l app=stable-diffusion
    echo ""
    echo "✓ Stable Diffusion 배포 완료. API 테스트: scripts/40-port-forward.sh sd"
    ;;

  status)
    kubectl get pods -n "${NS}" -l app=stable-diffusion -o wide
    echo ""
    POD=$(kubectl get pod -n "${NS}" -l app=stable-diffusion -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || echo "")
    if [[ -n "${POD}" ]]; then
      echo "=== GPU 사용 현황 ==="
      kubectl exec -n "${NS}" "${POD}" -- nvidia-smi
    fi
    ;;

  logs)
    kubectl logs -n "${NS}" -l app=stable-diffusion -f --tail=100
    ;;

  scale)
    # replicas 2로 확장 시 GPU 2개 동시 활용 (EFS PVC 전환 필요)
    REPLICAS="${2:-2}"
    echo "=== Stable Diffusion replica ${REPLICAS}개로 스케일 ==="
    echo "  주의: ReadWriteOnce PVC는 동일 노드에서만 멀티 마운트 가능합니다."
    echo "  다른 노드로 확장하려면 EFS(ReadWriteMany) PVC로 교체하세요."
    kubectl scale deployment/stable-diffusion -n "${NS}" --replicas="${REPLICAS}"
    ;;

  delete)
    kubectl delete -f "${ROOT_DIR}/k8s/stable-diffusion/deployment.yaml" --ignore-not-found
    kubectl delete -f "${ROOT_DIR}/k8s/stable-diffusion/service.yaml" --ignore-not-found
    echo "  PVC는 데이터 보호를 위해 유지합니다."
    echo "  PVC 삭제: kubectl delete pvc sd-model-cache-pvc -n ${NS}"
    echo "✓ Stable Diffusion 삭제 완료"
    ;;

  *)
    echo "사용법: $0 [apply|status|logs|scale <n>|delete]"
    exit 1
    ;;
esac
