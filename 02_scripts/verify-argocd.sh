#!/usr/bin/env bash
# Argo CD Application 5개의 동기화/상태와 배포 리소스를 한 번에 점검한다.
set -Eeuo pipefail

expected_apps=5
bad=0

# 사람이 확인할 수 있도록 각 Application의 현재 리비전과 상태를 먼저 출력한다.
kubectl -n argocd get applications \
  -o custom-columns=NAME:.metadata.name,SYNC:.status.sync.status,HEALTH:.status.health.status,REVISION:.status.sync.revision

app_count=$(kubectl -n argocd get applications --no-headers | wc -l)
[[ "$app_count" -eq "$expected_apps" ]] || {
  echo "ERROR: Application 수가 $expected_apps 개가 아닙니다: $app_count" >&2
  bad=1
}

# 하나라도 Synced/Healthy가 아니면 전체 검증을 실패 처리한다.
while read -r sync health; do
  [[ "$sync" == Synced && "$health" == Healthy ]] || bad=1
done < <(kubectl -n argocd get applications \
  -o jsonpath='{range .items[*]}{.status.sync.status}{" "}{.status.health.status}{"\n"}{end}')

# 실패 시 원인 파악에 필요한 워크로드와 Argo CD ALB 연결 상태를 함께 남긴다.
kubectl -n bank-of-anthos get deployments,pods,jobs
kubectl -n argocd get targetgroupbinding argocd-server

[[ "$bad" -eq 0 ]] || {
  echo "ERROR: 아직 Synced/Healthy가 아닌 Application이 있습니다." >&2
  exit 1
}
echo "검증 성공: 모든 Argo CD Application이 Synced/Healthy입니다."
