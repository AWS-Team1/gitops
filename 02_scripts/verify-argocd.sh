#!/usr/bin/env bash
set -Eeuo pipefail

expected_apps=6
bad=0

kubectl -n argocd get applications \
  -o custom-columns=NAME:.metadata.name,SYNC:.status.sync.status,HEALTH:.status.health.status,REVISION:.status.sync.revision

app_count=$(kubectl -n argocd get applications --no-headers | wc -l)
[[ "$app_count" -eq "$expected_apps" ]] || {
  echo "ERROR: Application 수가 $expected_apps 개가 아닙니다: $app_count" >&2
  bad=1
}

while read -r sync health; do
  [[ "$sync" == Synced && "$health" == Healthy ]] || bad=1
done < <(kubectl -n argocd get applications \
  -o jsonpath='{range .items[*]}{.status.sync.status}{" "}{.status.health.status}{"\n"}{end}')

kubectl -n bank-of-anthos get deployments,pods,jobs
kubectl -n argocd get targetgroupbinding argocd-server

[[ "$bad" -eq 0 ]] || {
  echo "ERROR: 아직 Synced/Healthy가 아닌 Application이 있습니다." >&2
  exit 1
}
echo "검증 성공: 모든 Argo CD Application이 Synced/Healthy입니다."
