#!/usr/bin/env bash
set -Eeuo pipefail

SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
VALUES_FILE="$SCRIPT_DIR/../01_bootstrap/argocd-values.yaml"
VALUES_ARGS=(--values "$VALUES_FILE")
# 플랫폼 전용 values가 전달되면 공통 values 뒤에 덮어쓴다.
if [[ -n ${ARGOCD_PLATFORM_VALUES_FILE:-} ]]; then
  VALUES_ARGS+=(--values "$ARGOCD_PLATFORM_VALUES_FILE")
fi

# 현재 설치 대상 클러스터를 출력해 오배포를 확인할 수 있게 한다.
kubectl config current-context

# 고정값: Helm chart 10.4.0은 팀에서 검증한 버전이다.
# Argo CD 자체는 bootstrap 소유다. 애플리케이션 리소스는 Root Application부터
# Argo CD가 소유하므로 이 스크립트에서 workload를 kubectl apply 하지 않는다.
helm repo add argo https://argoproj.github.io/argo-helm --force-update
helm repo update argo

# Argo CD가 없으면 설치하고, 있으면 업그레이드하며 실패 시 자동 롤백한다.
helm upgrade --install argocd argo/argo-cd -n argocd --create-namespace \
  --version 10.4.0 \
  "${VALUES_ARGS[@]}" \
  --atomic --timeout 10m

# argocd-server가 준비된 뒤 최종 파드 상태를 출력한다.
kubectl -n argocd rollout status deployment/argocd-server --timeout=10m
kubectl -n argocd get pods
