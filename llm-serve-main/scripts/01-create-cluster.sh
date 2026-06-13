#!/usr/bin/env bash
# EKS 클러스터 생성
# 소요 시간: 약 15~20분
set -euo pipefail

CLUSTER_NAME="${CLUSTER_NAME:-ai-serving-gpu2-eks}"
AWS_REGION="${AWS_REGION:-ap-northeast-2}"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(dirname "${SCRIPT_DIR}")"

echo "=== EKS 클러스터 생성: ${CLUSTER_NAME} (${AWS_REGION}) ==="
eksctl create cluster -f "${ROOT_DIR}/eks/cluster/cluster.yaml"

echo ""
echo "=== kubeconfig 업데이트 ==="
aws eks update-kubeconfig \
  --region "${AWS_REGION}" \
  --name "${CLUSTER_NAME}"

echo ""
echo "=== 클러스터 노드 확인 ==="
kubectl get nodes

echo ""
echo "✓ 클러스터 생성 완료. 다음 단계: scripts/02-create-nodegroup.sh"
