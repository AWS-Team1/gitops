#!/usr/bin/env bash
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
if [[ "$PLATFORM" == gke ]]; then
  "$SCRIPT_DIR/prepare-jwt-gcp.sh"
  kubectl wait --for=condition=Established \
    crd/secretsyncs.secret-sync.gke.io --timeout=5m
else
  kubectl -n kube-system rollout status deployment/aws-load-balancer-controller --timeout=5m
fi

if [[ "$PLATFORM" == gke ]]; then
  ARGOCD_PLATFORM_VALUES_FILE="$SCRIPT_DIR/../01_bootstrap/argocd-values-gke.yaml" \
    "$SCRIPT_DIR/install-argocd.sh"
  kubectl apply -f "$SCRIPT_DIR/../01_bootstrap/argocd-exposure-gke.yaml"
else
  "$SCRIPT_DIR/install-argocd.sh"
fi

# A private repository needs one durable credential. Re-runs reuse the same Secret.
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
