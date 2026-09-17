#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
REPO_ROOT=$(cd -- "$SCRIPT_DIR/.." && pwd)
MODE=${1:-prepare}

case "$MODE" in
  prepare)
    echo "== DB 애플리케이션 Secret 준비 =="
    SECRET_NAME=/boa/database/app \
    bash "$SCRIPT_DIR/prepare-database-secret.sh"

    SECRET_NAME=/boa/database/accounts \
    bash "$SCRIPT_DIR/prepare-database-secret.sh"

    SECRET_NAME=/boa/database/ledger \
    bash "$SCRIPT_DIR/prepare-database-secret.sh"

    echo "== JWT 준비 =="
    bash "$SCRIPT_DIR/prepare-jwt.sh"

    echo "== Argo CD 설치 =="
    bash "$SCRIPT_DIR/install-argocd.sh"

    echo "== UI 노출용 TargetGroupBinding 수동 적용 =="
    kubectl apply -f "$REPO_ROOT/manual/eks/argocd-exposure/targetgroupbinding.yaml"

    echo "준비 완료. docs/ARGOCD_EKS_RUNBOOK.md의 UI 저장소 연결 단계를 수행하세요."
    ;;
  apply-root)
    repo_count=$(kubectl -n argocd get secrets \
      -l argocd.argoproj.io/secret-type=repository \
      --no-headers 2>/dev/null | wc -l)
    [[ "$repo_count" -ge 1 ]] || {
      echo "ERROR: Argo CD 저장소 Credential이 없습니다. UI 연결을 먼저 완료하세요." >&2
      exit 1
    }

    kubectl apply -f "$REPO_ROOT/01_bootstrap/root-application-eks.yaml"
    kubectl -n argocd get applications.argoproj.io
    ;;
  *)
    echo "Usage: $0 [prepare|apply-root]" >&2
    exit 2
    ;;
esac

