#!/usr/bin/env bash
set -e   # 명령 하나라도 실패하면 즉시 중단 (반쯤 성공한 상태로 계속 안 감)

# ⭐ 지금 어느 클러스터에 설치하는지 확인 — 엉뚱한 클러스터 사고 방지
kubectl config current-context

# ArgoCD helm 차트 저장소 등록 + 최신화
helm repo add argo https://argoproj.github.io/argo-helm --force-update
helm repo update argo

# ArgoCD 설치 (없으면 설치, 있으면 업그레이드 / 실패 시 --atomic으로 자동 롤백)
helm upgrade --install argocd argo/argo-cd -n argocd --create-namespace \
  --version 10.4.0 --atomic --timeout 10m

# argocd-server 파드가 Ready 될 때까지 대기
kubectl -n argocd rollout status deployment/argocd-server --timeout=10m

# root Application 적용 (App-of-Apps 진입점)
# ※ private repo면 실제 sync 전에 register-repo.sh로 자격증명부터 등록할 것.
#    root app은 automated:false라 여기선 객체만 생기고, 수동 sync는 나중에.
kubectl apply -f 01_bootstrap/root-application.yaml