#!/usr/bin/env bash
# 새 EKS/GKE의 기존 bootstrap 흐름을 독립 kubeconfig로 동시에 실행한다.
set -Eeuo pipefail

SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
# 두 플랫폼이 공통으로 참조할 인프라 경로와 비공개 저장소 인증 정보를 먼저 검증한다.
: "${INFRA_ROOT:?set INFRA_ROOT to the Infra repository path}"
: "${ARGOCD_REPO_USERNAME:?set ARGOCD_REPO_USERNAME}"
: "${ARGOCD_REPO_PASSWORD:?set ARGOCD_REPO_PASSWORD}"

for tool in kubectl mktemp; do
  command -v "$tool" >/dev/null || { echo "ERROR: 필수 명령 없음: $tool" >&2; exit 1; }
done

EKS_CONTEXT=${EKS_CONTEXT:-$(kubectl config get-contexts -o name | grep 'boa-eks' | head -n 1 || true)}
GKE_CONTEXT=${GKE_CONTEXT:-$(kubectl config get-contexts -o name | grep 'boa-gke' | head -n 1 || true)}
[[ -n "$EKS_CONTEXT" && -n "$GKE_CONTEXT" ]] || {
  echo "ERROR: boa-eks/boa-gke context를 모두 찾지 못했습니다" >&2
  exit 1
}

TMP_DIR=$(mktemp -d)
trap 'rm -rf -- "$TMP_DIR"' EXIT
# 병렬 실행 중 현재 컨텍스트가 서로 덮어쓰이지 않도록 kubeconfig를 플랫폼별로 분리한다.
kubectl config view --raw >"$TMP_DIR/eks.config"
cp "$TMP_DIR/eks.config" "$TMP_DIR/gke.config"
KUBECONFIG="$TMP_DIR/eks.config" kubectl config use-context "$EKS_CONTEXT" >/dev/null
KUBECONFIG="$TMP_DIR/gke.config" kubectl config use-context "$GKE_CONTEXT" >/dev/null

# 유지 중인 aws-ops/RDS의 값을 기존 AWS bootstrap YAML에 먼저 반영한다.
"$SCRIPT_DIR/render-aws-runtime.sh" --infra-root "$INFRA_ROOT"

echo "AWS/GCP GitOps bootstrap 동시 시작"
# Helm 캐시도 플랫폼별로 나눠 두 bootstrap이 같은 파일을 동시에 수정하지 않게 한다.
(
  export KUBECONFIG="$TMP_DIR/eks.config"
  export HELM_CONFIG_HOME="$TMP_DIR/helm-eks/config"
  export HELM_CACHE_HOME="$TMP_DIR/helm-eks/cache"
  export HELM_DATA_HOME="$TMP_DIR/helm-eks/data"
  "$SCRIPT_DIR/bootstrap.sh" prepare
  "$SCRIPT_DIR/bootstrap-argocd-platform.sh" eks
) &
EKS_PID=$!

(
  export KUBECONFIG="$TMP_DIR/gke.config"
  export HELM_CONFIG_HOME="$TMP_DIR/helm-gke/config"
  export HELM_CACHE_HOME="$TMP_DIR/helm-gke/cache"
  export HELM_DATA_HOME="$TMP_DIR/helm-gke/data"
  "$SCRIPT_DIR/bootstrap-argocd-platform.sh" gke
) &
GKE_PID=$!

set +e
# 한쪽이 먼저 실패해도 두 작업을 모두 회수한 뒤 전체 결과를 판정한다.
wait "$EKS_PID"; EKS_STATUS=$?
wait "$GKE_PID"; GKE_STATUS=$?
set -e

[[ "$EKS_STATUS" -eq 0 && "$GKE_STATUS" -eq 0 ]] || {
  echo "ERROR: bootstrap 실패(eks=$EKS_STATUS, gke=$GKE_STATUS)" >&2
  exit 1
}
echo "AWS/GCP GitOps bootstrap 완료"
