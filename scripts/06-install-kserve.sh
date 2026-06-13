#!/usr/bin/env bash
# KServe 설치 (RawDeployment 모드 — Knative 없이 표준 Deployment 사용)
# 소요 시간: 약 3~5분
set -euo pipefail

CERT_MANAGER_VERSION="${CERT_MANAGER_VERSION:-v1.15.3}"
KSERVE_VERSION="${KSERVE_VERSION:-v0.13.0}"
KSERVE_NS="kserve"
APP_NS="${APP_NS:-llm-serve}"

echo "=== KServe 설치: cert-manager ${CERT_MANAGER_VERSION} + KServe ${KSERVE_VERSION} ==="
echo ""

echo "=== 1. cert-manager 설치 (KServe webhook TLS 필요) ==="
kubectl apply -f "https://github.com/cert-manager/cert-manager/releases/download/${CERT_MANAGER_VERSION}/cert-manager.yaml"

echo ""
echo "=== cert-manager 준비 대기 ==="
kubectl wait --for=condition=Available deployment --all \
  -n cert-manager --timeout=300s

echo ""
echo "=== 2. KServe 설치 ==="
kubectl apply -f "https://github.com/kserve/kserve/releases/download/${KSERVE_VERSION}/kserve.yaml"
kubectl apply -f "https://github.com/kserve/kserve/releases/download/${KSERVE_VERSION}/kserve-cluster-resources.yaml"

echo ""
echo "=== KServe 준비 대기 ==="
kubectl wait --for=condition=Available deployment --all \
  -n "${KSERVE_NS}" --timeout=300s

echo ""
echo "=== 3. RawDeployment 기본 모드 설정 (Knative 불필요) ==="
kubectl patch configmap inferenceservice-config \
  -n "${KSERVE_NS}" \
  --type=merge \
  -p '{"data":{"deploy":"{\"defaultDeploymentMode\":\"RawDeployment\"}"}}'

echo ""
echo "=== 4. llm-serve 네임스페이스 KServe 활성화 ==="
kubectl label namespace "${APP_NS}" \
  serving.kserve.io/inferenceservice=enabled \
  --overwrite

echo ""
echo "=== KServe Pod 상태 ==="
kubectl get pods -n "${KSERVE_NS}"

echo ""
echo "=== 기본 ClusterServingRuntime 목록 ==="
kubectl get clusterservingruntimes

echo ""
echo "✓ KServe 설치 완료. 다음 단계: scripts/60-deploy-kserve-vllm.sh"
