#!/usr/bin/env bash
# 목적: Argo CD에 비공개 GitOps 저장소 자격 증명을 등록한다.
# 입력: 첫 번째 인자 aws 또는 gcp, GitHub 사용자명/PAT 환경변수.
# 결과: argocd/gitops-repo repository Secret이 생성 또는 갱신된다.
set -Eeuo pipefail

PLATFORM=${1:-}
REPO_URL=${ARGOCD_REPO_URL:-https://github.com/AWS-Team1/gitops.git}
: "${ARGOCD_REPO_USERNAME:?set ARGOCD_REPO_USERNAME}"
: "${ARGOCD_REPO_PASSWORD:?set ARGOCD_REPO_PASSWORD}"

case "$PLATFORM" in
  aws) CONTEXT=boa-eks ;;
  gcp) CONTEXT=boa-gke ;;
  *) echo "Usage: $0 <aws|gcp>" >&2; exit 2 ;;
esac

command -v kubectl >/dev/null || { echo "ERROR: 필수 명령 없음: kubectl" >&2; exit 1; }

# 자격 증명을 다른 클러스터에 등록하지 않도록 현재 context를 확인한다.
CURRENT_CONTEXT=$(kubectl config current-context)
[[ "$CURRENT_CONTEXT" == *"$CONTEXT"* ]] || {
  echo "ERROR: $PLATFORM context가 아닙니다: $CURRENT_CONTEXT" >&2
  exit 1
}

# 입력받은 자격 증명으로 Secret manifest를 만들고 클러스터에 적용한다.
kubectl -n argocd create secret generic gitops-repo \
  --from-literal=type=git \
  --from-literal=url="$REPO_URL" \
  --from-literal=username="$ARGOCD_REPO_USERNAME" \
  --from-literal=password="$ARGOCD_REPO_PASSWORD" \
  --dry-run=client -o yaml | kubectl apply -f -

# Argo CD가 일반 Secret을 repository credential로 인식하게 한다.
kubectl -n argocd label secret gitops-repo \
  argocd.argoproj.io/secret-type=repository --overwrite
kubectl -n argocd get secret gitops-repo
echo "완료: Argo CD GitOps 저장소가 등록되었습니다."
