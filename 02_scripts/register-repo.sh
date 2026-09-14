#!/usr/bin/env bash
#
# register-repo-credentials.sh
#
# private GitOps 저장소를 Argo CD 에 등록한다.
# GitHub PAT 는 입력받아 Kubernetes Secret 으로만 전달하며, 화면·파일·Git 에
# 남기지 않는다.
#
# 저장소 URL 은 origin remote 에서 유도한다(하드코딩 없음).
# Root Application 을 적용하기 전에 한 번 실행한다.

set -Eeuo pipefail

usage() { echo "Usage: $0 [--repo-url URL] [--namespace argocd]"; }

REPO_URL=${GITOPS_REPO_URL:-}
ARGOCD_NAMESPACE=argocd

while [[ $# -gt 0 ]]; do
  case "$1" in
    --repo-url)  REPO_URL=${2:?--repo-url 값이 필요합니다};  shift 2 ;;
    --namespace) ARGOCD_NAMESPACE=${2:?--namespace 값이 필요합니다}; shift 2 ;;
    -h|--help)   usage; exit 0 ;;
    *) usage >&2; echo "알 수 없는 인자: $1" >&2; exit 1 ;;
  esac
done

command -v kubectl >/dev/null 2>&1 || { echo "kubectl 이 필요합니다." >&2; exit 1; }

if [[ -z "$REPO_URL" ]]; then
  repo_root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
  origin=$(git -C "$repo_root" remote get-url origin) \
    || { echo "origin remote 를 찾을 수 없습니다. --repo-url 로 지정하세요." >&2; exit 1; }
  case "$origin" in
    git@*:*)     REPO_URL="https://${origin#git@}"; REPO_URL=${REPO_URL/:/\/} ;;
    ssh://git@*) REPO_URL="https://${origin#ssh://git@}" ;;
    *)           REPO_URL="$origin" ;;
  esac
  [[ "$REPO_URL" == *.git ]] || REPO_URL="${REPO_URL}.git"
fi

echo "저장소: ${REPO_URL}"
echo "GitHub PAT 를 입력하세요. 입력 내용은 화면에 표시되지 않습니다."
read -rsp "GitHub PAT: " github_pat
echo

[[ -n "$github_pat" ]] || { echo "PAT 가 입력되지 않았습니다." >&2; exit 1; }

kubectl create namespace "$ARGOCD_NAMESPACE" --dry-run=client -o yaml | kubectl apply -f - >/dev/null

kubectl apply -f - >/dev/null <<YAML
apiVersion: v1
kind: Secret
metadata:
  name: gitops-repository
  namespace: ${ARGOCD_NAMESPACE}
  labels:
    argocd.argoproj.io/secret-type: repository
type: Opaque
stringData:
  type: git
  url: ${REPO_URL}
  username: x-access-token
  password: "${github_pat}"
YAML

unset github_pat
echo "등록 완료. 다음: 01_bootstrap/root-application-eks.yaml 을 적용하세요."
echo "       (전체 초기화는 02_scripts/bootstrap.sh 가 JWT → Argo CD → 저장소 인증 → Root Application 순으로 실행)"
