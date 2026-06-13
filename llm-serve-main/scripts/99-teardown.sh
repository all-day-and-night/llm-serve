#!/usr/bin/env bash
# 전체 리소스 삭제 (순서 중요)
# 사용법: ./scripts/99-teardown.sh [all|k8s|nodegroup|cluster]
#
# 경고: all 옵션은 EKS 클러스터 전체를 삭제합니다. 되돌릴 수 없습니다.
set -euo pipefail

SCOPE="${1:-k8s}"
CLUSTER_NAME="${CLUSTER_NAME:-ai-serving-gpu2-eks}"
AWS_REGION="${AWS_REGION:-ap-northeast-2}"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(dirname "${SCRIPT_DIR}")"
NS="llm-serve"

_delete_k8s() {
  echo "=== K8s 리소스 삭제 ==="
  for dir in vllm trtllm triton stable-diffusion; do
    kubectl delete -f "${ROOT_DIR}/k8s/${dir}/" --ignore-not-found 2>/dev/null || true
  done
  kubectl delete -f "${ROOT_DIR}/k8s/common/" --ignore-not-found 2>/dev/null || true
  kubectl delete namespace "${NS}" --ignore-not-found
  echo "  NVIDIA Device Plugin 제거"
  helm uninstall nvdp -n nvidia-device-plugin 2>/dev/null || true
  kubectl delete namespace nvidia-device-plugin --ignore-not-found
  echo "✓ K8s 리소스 삭제 완료"
}

_delete_nodegroup() {
  echo "=== GPU NodeGroup 삭제 (약 5분) ==="
  eksctl delete nodegroup \
    -f "${ROOT_DIR}/eks/nodegroup/gpu-nodegroup.yaml" \
    --approve \
    --disable-eviction
  echo "✓ NodeGroup 삭제 완료"
}

_delete_cluster() {
  echo "=== EKS 클러스터 삭제 (약 10~15분) ==="
  eksctl delete cluster \
    -f "${ROOT_DIR}/eks/cluster/cluster.yaml" \
    --wait
  echo "✓ 클러스터 삭제 완료"
}

case "${SCOPE}" in
  k8s)
    _delete_k8s
    ;;

  nodegroup)
    _delete_nodegroup
    ;;

  cluster)
    _delete_cluster
    ;;

  all)
    echo "================================================================"
    echo " 경고: EKS 클러스터 전체를 삭제합니다. 되돌릴 수 없습니다."
    echo " 클러스터: ${CLUSTER_NAME} / 리전: ${AWS_REGION}"
    echo "================================================================"
    read -r -p "계속하려면 클러스터 이름을 입력하세요: " CONFIRM
    if [[ "${CONFIRM}" != "${CLUSTER_NAME}" ]]; then
      echo "취소되었습니다."
      exit 0
    fi
    _delete_k8s
    _delete_nodegroup
    _delete_cluster
    echo ""
    echo "✓ 전체 삭제 완료"
    ;;

  *)
    echo "사용법: $0 [k8s|nodegroup|cluster|all]"
    echo ""
    echo "  k8s        : K8s 리소스만 삭제 (namespace, helm, deployments)"
    echo "  nodegroup  : GPU NodeGroup만 삭제 (비용 절감)"
    echo "  cluster    : EKS 클러스터 삭제"
    echo "  all        : 전체 삭제 (k8s → nodegroup → cluster)"
    exit 1
    ;;
esac
