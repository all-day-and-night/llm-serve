#!/usr/bin/env bash
set -euo pipefail

CLUSTER_NAME="${CLUSTER_NAME:-ai-serving-gpu2-eks}"
AWS_REGION="${AWS_REGION:-ap-northeast-2}"

echo "=== 1. 필수 툴 버전 확인 ==="
MISSING_TOOLS=()
for tool in aws kubectl eksctl helm jq; do
  if command -v "$tool" &>/dev/null; then
    echo "  ✓ $tool: $($tool version --short 2>/dev/null || $tool version 2>/dev/null | head -1)"
  else
    echo "  ✗ $tool: 미설치"
    MISSING_TOOLS+=("$tool")
  fi
done

if [[ ${#MISSING_TOOLS[@]} -gt 0 ]]; then
  echo ""
  echo "  미설치 툴 설치 방법 (macOS):"
  for tool in "${MISSING_TOOLS[@]}"; do
    case "$tool" in
      aws)     echo "    aws:     brew install awscli" ;;
      kubectl) echo "    kubectl: brew install kubectl" ;;
      eksctl)  echo "    eksctl:  brew tap weaveworks/tap && brew install weaveworks/tap/eksctl" ;;
      helm)    echo "    helm:    brew install helm" ;;
      jq)      echo "    jq:      brew install jq" ;;
    esac
  done
  echo ""
  echo "  ✗ 필수 툴이 설치되지 않았습니다. 위 명령어로 설치 후 다시 실행하세요."
  exit 1
fi

echo ""
echo "=== 2. AWS 세션 확인 ==="
if aws sts get-caller-identity --region "${AWS_REGION}" --output json 2>/dev/null; then
  echo "  ✓ AWS 세션 유효"
else
  echo ""
  echo "  ✗ AWS 세션 만료 또는 인증 실패"
  echo "  → MFA 세션 갱신: source .aws/get-ssm.sh <MFA_CODE>"
  echo "  → 기존 세션 재사용: source .aws/.session-env"
  exit 1
fi

echo ""
echo "=== 3. 환경 변수 ==="
echo "  CLUSTER_NAME=${CLUSTER_NAME}"
echo "  AWS_REGION=${AWS_REGION}"
echo ""
echo "  다른 값을 사용하려면:"
echo "  export CLUSTER_NAME=<이름>"
echo "  export AWS_REGION=<리전>"
