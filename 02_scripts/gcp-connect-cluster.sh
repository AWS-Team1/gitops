#!/usr/bin/env bash
# 목적: gcloud 자격 증명을 확인하고 kubectl을 GKE 클러스터에 연결한다.
# 입력: GCP_PROJECT_ID, GCP_REGION, GCP_CLUSTER 환경변수(선택).
# 결과: kubeconfig의 현재 context가 대상 GKE를 가리키고 노드 목록이 출력된다.
set -Eeuo pipefail

PROJECT_ID=${GCP_PROJECT_ID:-kdt4-1-506106}
REGION=${GCP_REGION:-asia-northeast2}
CLUSTER=${GCP_CLUSTER:-boa-gke}

for tool in gcloud kubectl; do
  command -v "$tool" >/dev/null || { echo "ERROR: 필수 명령 없음: $tool" >&2; exit 1; }
done

# 활성 계정이 있어야 GKE 인증 정보를 받을 수 있다.
ACCOUNT=$(gcloud auth list --filter=status:ACTIVE --format='value(account)' | head -n 1)
[[ -n "$ACCOUNT" ]] || { echo "ERROR: gcloud 활성 계정이 없습니다." >&2; exit 1; }

# GKE endpoint와 인증 정보를 kubeconfig에 기록한다.
gcloud container clusters get-credentials "$CLUSTER" --region "$REGION" --project "$PROJECT_ID"

# 연결 결과와 현재 노드 상태를 출력한다.
kubectl config current-context
kubectl get nodes -o wide
echo "완료: kubectl이 GKE $CLUSTER에 연결되었습니다."
