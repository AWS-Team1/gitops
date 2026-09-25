#!/usr/bin/env bash
# 목적: 지정한 플랫폼에 Argo CD Helm chart만 설치하거나 갱신한다.
# 입력: 첫 번째 인자 aws 또는 gcp, 현재 kubectl context.
# 결과: argocd namespace와 Argo CD 파드가 Ready 상태가 된다.
set -Eeuo pipefail

PLATFORM=${1:-}
SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
VALUES_ARGS=(--values "$SCRIPT_DIR/../01_bootstrap/argocd-values.yaml")

case "$PLATFORM" in
  aws) CONTEXT=boa-eks ;;
  gcp)
    CONTEXT=boa-gke
    VALUES_ARGS+=(--values "$SCRIPT_DIR/../01_bootstrap/argocd-values-gke.yaml")
    ;;
  *) echo "Usage: $0 <aws|gcp>" >&2; exit 2 ;;
esac

for tool in kubectl helm; do
  command -v "$tool" >/dev/null || { echo "ERROR: 필수 명령 없음: $tool" >&2; exit 1; }
done

# 다른 플랫폼에 설치하지 않도록 현재 context를 확인한다.
CURRENT_CONTEXT=$(kubectl config current-context)
[[ "$CURRENT_CONTEXT" == *"$CONTEXT"* ]] || {
  echo "ERROR: $PLATFORM context가 아닙니다: $CURRENT_CONTEXT" >&2
  exit 1
}

# 공식 Helm 저장소에서 팀 검증 버전의 Argo CD만 설치한다.
helm repo add argo https://argoproj.github.io/argo-helm --force-update
helm upgrade --install argocd argo/argo-cd \
  -n argocd --create-namespace \
  --version 10.4.0 \
  "${VALUES_ARGS[@]}" \
  --atomic --timeout 10m

# 서버 Deployment가 준비됐는지 확인하고 설치 결과를 출력한다.
kubectl -n argocd rollout status deployment/argocd-server --timeout=10m
kubectl -n argocd get pods
echo "완료: $PLATFORM Argo CD가 설치되었습니다."
