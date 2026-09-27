#!/usr/bin/env bash
# 목적: 지정한 플랫폼의 Argo CD Application 동기화 결과를 검증한다.
# 입력: 첫 번째 인자 aws 또는 gcp.
# 결과: Root 1개와 Child 4개가 Synced/Healthy이며 플랫폼 배포 상태가 확인된다.
set -Eeuo pipefail

PLATFORM=${1:-}
NAMESPACE=bank-of-anthos
DEPLOYMENTS=(userservice contacts balancereader ledgerwriter transactionhistory frontend)

case "$PLATFORM" in
  aws) ROOT=boa-eks-root; CONTEXT=boa-eks ;;
  gcp) ROOT=boa-gke-root; CONTEXT=boa-gke ;;
  *) echo "Usage: $0 <aws|gcp>" >&2; exit 2 ;;
esac

command -v kubectl >/dev/null || { echo "ERROR: 필수 명령 없음: kubectl" >&2; exit 1; }

# 다른 플랫폼을 검사하지 않도록 현재 context를 확인한다.
CURRENT_CONTEXT=$(kubectl config current-context)
[[ "$CURRENT_CONTEXT" == *"$CONTEXT"* ]] || {
  echo "ERROR: $PLATFORM context가 아닙니다: $CURRENT_CONTEXT" >&2
  exit 1
}

# Root가 Git을 동기화하고 모든 Application이 정상 상태가 될 때까지 기다린다.
kubectl -n argocd wait "application/$ROOT" \
  --for=jsonpath='{.status.sync.status}'=Synced --timeout=15m
kubectl -n argocd wait applications --all \
  --for=jsonpath='{.status.sync.status}'=Synced --timeout=15m
kubectl -n argocd wait applications --all \
  --for=jsonpath='{.status.health.status}'=Healthy --timeout=15m

# Root 1개와 Child 4개가 생성됐는지 확인한다.
APPLICATION_COUNT=$(kubectl -n argocd get applications --no-headers | wc -l)
[[ "$APPLICATION_COUNT" -eq 5 ]] || {
  echo "ERROR: Application 수가 5개가 아닙니다: $APPLICATION_COUNT" >&2
  exit 1
}
kubectl -n argocd get applications

if [[ "$PLATFORM" == aws ]]; then
  # AWS 서비스 6개가 실제 Ready 상태인지 확인한다.
  for deployment in "${DEPLOYMENTS[@]}"; do
    kubectl -n "$NAMESPACE" rollout status "deployment/$deployment" --timeout=10m
  done
else
  # GCP 서비스 6개가 replicas=1이고 HPA가 없는지 확인한다.
  for deployment in "${DEPLOYMENTS[@]}"; do
    [[ $(kubectl -n "$NAMESPACE" get deployment "$deployment" -o jsonpath='{.spec.replicas}') == 1 ]] || {
      echo "ERROR: $deployment replicas가 1이 아닙니다." >&2
      exit 1
    }
  done
  [[ -z $(kubectl -n "$NAMESPACE" get hpa -o name) ]] || {
    echo "ERROR: GCP standby에 HPA가 존재합니다." >&2
    exit 1
  }
fi

echo "완료: $PLATFORM Argo CD 배포가 정상입니다."
