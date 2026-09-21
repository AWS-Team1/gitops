#!/usr/bin/env bash
# 지정한 EKS/GKE에 Argo CD를 설치하고 Root Application과 워크로드 상태를 검증한다.
set -Eeuo pipefail

PLATFORM=${1:-}
SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
REPO_URL=https://github.com/AWS-Team1/gitops.git
NAMESPACE=bank-of-anthos
DEPLOYMENTS=(userservice contacts balancereader ledgerwriter transactionhistory frontend)

case "$PLATFORM" in
  eks) ROOT=boa-eks-root ;;
  gke) ROOT=boa-gke-root ;;
  *) echo "usage: $0 <eks|gke>" >&2; exit 2 ;;
esac

# 잘못된 kubeconfig에서 다른 클러스터를 변경하지 않도록 대상 컨텍스트를 확인한다.
for command in kubectl helm; do
  command -v "$command" >/dev/null || { echo "$command is required" >&2; exit 1; }
done

CONTEXT=$(kubectl config current-context)
[[ "$CONTEXT" == *"boa-$PLATFORM"* ]] || {
  echo "refusing to deploy $PLATFORM from context: $CONTEXT" >&2
  exit 1
}

kubectl wait node --all --for=condition=Ready --timeout=5m
kubectl wait --for=condition=Established \
  crd/secretproviderclasses.secrets-store.csi.x-k8s.io --timeout=5m
# GKE는 Secret Sync CRD와 JWT를, EKS는 Load Balancer Controller를 선행 조건으로 확인한다.
if [[ "$PLATFORM" == gke ]]; then
  "$SCRIPT_DIR/prepare-jwt-gcp.sh"
  kubectl wait --for=condition=Established \
    crd/secretsyncs.secret-sync.gke.io --timeout=5m
else
  kubectl -n kube-system rollout status deployment/aws-load-balancer-controller --timeout=5m
fi

# 플랫폼별 values와 외부 노출 리소스를 적용해 동일한 설치 스크립트를 재사용한다.
if [[ "$PLATFORM" == gke ]]; then
  ARGOCD_PLATFORM_VALUES_FILE="$SCRIPT_DIR/../01_bootstrap/argocd-values-gke.yaml" \
    "$SCRIPT_DIR/install-argocd.sh"
  kubectl apply -f "$SCRIPT_DIR/../01_bootstrap/argocd-exposure-gke.yaml"
else
  "$SCRIPT_DIR/install-argocd.sh"
fi

# 비공개 저장소 인증 Secret은 최초 한 번만 만들고 재실행 시 기존 값을 유지한다.
if ! kubectl -n argocd get secret gitops-repo >/dev/null 2>&1; then
  : "${ARGOCD_REPO_USERNAME:?set ARGOCD_REPO_USERNAME for the private Git repository}"
  : "${ARGOCD_REPO_PASSWORD:?set ARGOCD_REPO_PASSWORD to a PAT or deploy credential}"
  kubectl -n argocd create secret generic gitops-repo \
    --from-literal=type=git \
    --from-literal=url="$REPO_URL" \
    --from-literal=username="$ARGOCD_REPO_USERNAME" \
    --from-literal=password="$ARGOCD_REPO_PASSWORD"
fi
kubectl -n argocd label secret gitops-repo argocd.argoproj.io/secret-type=repository --overwrite

# Root Application이 하위 Application을 모두 동기화할 때까지 기다린다.
kubectl apply -f "$SCRIPT_DIR/../01_bootstrap/root-application-$PLATFORM.yaml"
kubectl -n argocd wait "application/$ROOT" \
  --for=jsonpath='{.status.sync.status}'=Synced --timeout=15m
kubectl -n argocd wait "application/$ROOT" \
  --for=jsonpath='{.status.health.status}'=Healthy --timeout=15m

mapfile -t APPLICATIONS < <(kubectl -n argocd get applications -o \
  jsonpath='{range .items[*]}{.metadata.name}{"|"}{.status.sync.status}{"|"}{.status.health.status}{"\n"}{end}')
[[ ${#APPLICATIONS[@]} -eq 5 ]] || {
  printf 'expected 5 Argo CD Applications, got %s:\n%s\n' "${#APPLICATIONS[@]}" "${APPLICATIONS[*]}" >&2
  exit 1
}
printf '%s\n' "${APPLICATIONS[@]}"

# GKE는 DR 대기 상태, EKS는 실제 서비스 가능 상태가 배포 목표다.
if [[ "$PLATFORM" == gke ]]; then
  for deployment in "${DEPLOYMENTS[@]}"; do
    [[ $(kubectl -n "$NAMESPACE" get deployment "$deployment" -o jsonpath='{.spec.replicas}') == 0 ]] || {
      echo "$deployment is not in standby (replicas must be 0)" >&2
      exit 1
    }
  done
  [[ -z $(kubectl -n "$NAMESPACE" get hpa -o name) ]] || {
    echo "GKE standby must not have an HPA" >&2
    exit 1
  }
  echo "GKE CD ready: six workloads are synchronized in standby (replicas=0)."
else
  for deployment in "${DEPLOYMENTS[@]}"; do
    kubectl -n "$NAMESPACE" rollout status "deployment/$deployment" --timeout=10m
  done
  echo "EKS CD ready: six workloads are synchronized and available."
fi
