#!/usr/bin/env bash
# 공통 K8s 리소스 생성: namespace, HF token secret
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(dirname "${SCRIPT_DIR}")"

echo "=== Namespace 생성 ==="
kubectl apply -f "${ROOT_DIR}/k8s/common/namespace.yaml"

echo ""
echo "=== HuggingFace Token Secret ==="
echo "  Qwen2.5-7B는 HF 토큰이 불필요하지만 구조 확보를 위해 생성합니다."
echo "  Llama 등 gated 모델 사용 시 실제 토큰을 입력하세요."

HF_TOKEN="${HF_TOKEN:-dummy-token-for-public-models}"

kubectl create secret generic hf-token \
  --namespace llm-serve \
  --from-literal=HF_TOKEN="${HF_TOKEN}" \
  --dry-run=client -o yaml | kubectl apply -f -

echo ""
echo "=== 리소스 확인 ==="
kubectl get namespace llm-serve
kubectl get secret hf-token -n llm-serve

echo ""
echo "✓ 공통 리소스 생성 완료. 다음 단계: scripts/05-gpu-test.sh"
