#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
REPO_ROOT=$(cd -- "$SCRIPT_DIR/.." && pwd)

echo "== JWT 준비 =="
bash "$SCRIPT_DIR/prepare-jwt.sh"

echo "== Argo CD 설치 =="
bash "$SCRIPT_DIR/install-argocd.sh"

echo "== Git 저장소 인증 =="
bash "$SCRIPT_DIR/register-repo.sh"

echo "== Root Application 적용 =="
kubectl apply -f "$REPO_ROOT/01_bootstrap/root-application-eks.yaml"

echo "== Argo CD 애플리케이션 상태 =="
kubectl -n argocd get applications.argoproj.io
echo "초기화 완료: 모든 Application이 Synced/Healthy가 될 때까지 상태를 확인하세요."
