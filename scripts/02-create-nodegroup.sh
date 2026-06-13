#!/usr/bin/env bash
# GPU NodeGroup 생성 (g5.12xlarge: A10G × 4)
# 소요 시간: 약 5~10분
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(dirname "${SCRIPT_DIR}")"

echo "=== GPU NodeGroup 생성 ==="
echo "  인스턴스: g5.12xlarge (A10G × 4, 96GB VRAM)"
echo "  비용: ~\$16/hr on-demand. 실습 후 즉시 삭제 권장."
echo ""

eksctl create nodegroup -f "${ROOT_DIR}/eks/nodegroup/gpu-nodegroup.yaml"

echo ""
echo "=== 노드 레이블 확인 ==="
kubectl get nodes -L accelerator,gpu-node

echo ""
echo "✓ NodeGroup 생성 완료. 다음 단계: scripts/03-install-addons.sh"
