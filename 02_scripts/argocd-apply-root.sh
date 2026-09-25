#!/usr/bin/env bash
# 목적: 지정한 플랫폼의 Argo CD Root Application 하나를 적용한다.
# 입력: 첫 번째 인자 aws 또는 gcp.
# 결과: boa-eks-root 또는 boa-gke-root Application이 생성 또는 갱신된다.
set -Eeuo pipefail

PLATFORM=${1:-}
SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)

case "$PLATFORM" in
  aws) FILE="$SCRIPT_DIR/../01_bootstrap/root-application-eks.yaml"; ROOT=boa-eks-root; CONTEXT=boa-eks ;;
  gcp) FILE="$SCRIPT_DIR/../01_bootstrap/root-application-gke.yaml"; ROOT=boa-gke-root; CONTEXT=boa-gke ;;
  *) echo "Usage: $0 <aws|gcp>" >&2; exit 2 ;;
esac

command -v kubectl >/dev/null || { echo "ERROR: 필수 명령 없음: kubectl" >&2; exit 1; }

# 다른 플랫폼에 Root Application을 적용하지 않도록 context를 확인한다.
CURRENT_CONTEXT=$(kubectl config current-context)
[[ "$CURRENT_CONTEXT" == *"$CONTEXT"* ]] || {
  echo "ERROR: $PLATFORM context가 아닙니다: $CURRENT_CONTEXT" >&2
  exit 1
}

# Root Application만 적용하고 동기화 검증은 별도 스크립트에 맡긴다.
kubectl apply -f "$FILE"
kubectl -n argocd get application "$ROOT"
echo "완료: $ROOT Application이 적용되었습니다."
