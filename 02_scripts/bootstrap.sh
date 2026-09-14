#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)

echo "== JWT 준비 =="
bash "$SCRIPT_DIR/prepare-jwt.sh"

# DB 초기화는 Argo CD가 db-bootstrap Sync hook으로 수행한다.
echo "== Argo CD 설치 및 Root Application =="
bash "$SCRIPT_DIR/install-argocd.sh"

echo "== Git 저장소 인증 =="
bash "$SCRIPT_DIR/register-repo.sh"

echo "초기화 완료"
