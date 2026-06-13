#!/usr/bin/env bash
# NVIDIA Device Plugin + EBS CSI Driver 설치
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(dirname "${SCRIPT_DIR}")"
CLUSTER_NAME="${CLUSTER_NAME:-ai-serving-gpu2-eks}"
AWS_REGION="${AWS_REGION:-ap-northeast-2}"

echo "=== EBS CSI Driver addon 설치 (PVC 프로비저닝에 필요) ==="
eksctl create addon \
  --name aws-ebs-csi-driver \
  --cluster "${CLUSTER_NAME}" \
  --region "${AWS_REGION}" \
  --force

echo ""
echo "=== gp3 StorageClass 생성 ==="
kubectl apply -f - <<EOF
apiVersion: storage.k8s.io/v1
kind: StorageClass
metadata:
  name: gp3
  annotations:
    storageclass.kubernetes.io/is-default-class: "true"
provisioner: ebs.csi.aws.com
parameters:
  type: gp3
  fsType: ext4
volumeBindingMode: WaitForFirstConsumer
allowVolumeExpansion: true
EOF

echo ""
echo "=== StorageClass 확인 ==="
kubectl get storageclass

echo ""
echo "=== NVIDIA Device Plugin Helm 설치 ==="
helm repo add nvdp https://nvidia.github.io/k8s-device-plugin
helm repo update

helm upgrade --install nvdp nvdp/nvidia-device-plugin \
  --namespace nvidia-device-plugin \
  --create-namespace \
  -f "${ROOT_DIR}/helm/nvidia-device-plugin-values.yaml" \
  --wait

echo ""
echo "=== Device Plugin Pod 상태 ==="
kubectl get pods -n nvidia-device-plugin

echo ""
echo "=== GPU 노드 Capacity 확인 (nvidia.com/gpu 항목 확인) ==="
kubectl describe node -l gpu-node=true | grep -A10 "Capacity:"

echo ""
echo "✓ NVIDIA Device Plugin 설치 완료. 다음 단계: scripts/04-setup-common.sh"
