#!/usr/bin/env bash
# 목적: AWS 자격 증명을 확인하고 kubectl을 EKS 클러스터에 연결한다.
# 입력: REGION, CLUSTER, EXPECTED_ACCOUNT 환경변수(선택).
# 결과: kubeconfig의 현재 context가 대상 EKS를 가리키고 노드 목록이 출력된다.
set -Eeuo pipefail

REGION=${REGION:-ap-northeast-2}
CLUSTER=${CLUSTER:-boa-eks}
EXPECTED_ACCOUNT=${EXPECTED_ACCOUNT:-769413326616}

for tool in aws kubectl; do
  command -v "$tool" >/dev/null || { echo "ERROR: 필수 명령 없음: $tool" >&2; exit 1; }
done

# 다른 AWS 계정에 연결된 상태에서 kubeconfig를 바꾸지 않도록 계정을 확인한다.
ACCOUNT=$(aws sts get-caller-identity --query Account --output text)
[[ "$ACCOUNT" == "$EXPECTED_ACCOUNT" ]] || {
  echo "ERROR: 대상 AWS 계정 불일치: $ACCOUNT" >&2
  exit 1
}

# EKS endpoint와 인증 정보를 kubeconfig에 기록한다.
aws eks update-kubeconfig --name "$CLUSTER" --region "$REGION" --alias "$CLUSTER"

# 연결 결과와 현재 노드 상태를 출력한다.
kubectl config current-context
kubectl get nodes -o wide
echo "완료: kubectl이 EKS $CLUSTER에 연결되었습니다."
