#!/usr/bin/env bash
set -Eeuo pipefail

SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
VALUES_FILE="$SCRIPT_DIR/../01_bootstrap/argocd-values.yaml"

# ⭐ 지금 어느 클러스터에 설치하는지 확인 — 엉뚱한 클러스터 사고 방지
kubectl config current-context

# HARD-CODED: Helm chart version 10.4.0은 검증된 팀 버전이다.
# Argo CD 자체는 bootstrap 소유다. 애플리케이션 리소스는 Root Application부터
# Argo CD가 소유하므로 이 스크립트에서 workload를 kubectl apply 하지 않는다.
helm repo add argo https://argoproj.github.io/argo-helm --force-update
helm repo update argo

# ArgoCD 설치 (없으면 설치, 있으면 업그레이드 / 실패 시 --atomic으로 자동 롤백)
helm upgrade --install argocd argo/argo-cd -n argocd --create-namespace \
  --version 10.4.0 \
  --values "$VALUES_FILE" \
  --atomic --timeout 10m

# argocd-server 파드가 Ready 될 때까지 대기
kubectl -n argocd rollout status deployment/argocd-server --timeout=10m
kubectl -n argocd get pods
