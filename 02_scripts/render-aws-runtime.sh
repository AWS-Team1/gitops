#!/usr/bin/env bash
# Terraform output으로 AWS가 재생성할 때 바뀔 수 있는 GitOps 런타임 값을 갱신한다.
# 변경이 생기면 반드시 이 브랜치에 commit/push한 뒤 Argo CD를 연결한다.
set -Eeuo pipefail

usage() { echo "Usage: $0 --infra-root /absolute/path/to/Infra"; }
INFRA_ROOT=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --infra-root) INFRA_ROOT=${2:?경로가 필요합니다}; shift 2 ;;
    -h|--help) usage; exit 0 ;;
    *) usage >&2; exit 2 ;;
  esac
done
[[ -n "$INFRA_ROOT" ]] || { usage >&2; exit 2; }

for tool in terraform sed grep; do
  command -v "$tool" >/dev/null || { echo "ERROR: 필수 명령 없음: $tool" >&2; exit 1; }
done

SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
REPO_ROOT=$(cd -- "$SCRIPT_DIR/.." && pwd)
CD_ROOT="$INFRA_ROOT/aws-cd-bootstrap"
TGB_FILE="$REPO_ROOT/manual/eks/argocd-exposure/targetgroupbinding.yaml"
SECRETS_FILE="$REPO_ROOT/03_manifests/eks/shared/secrets.yaml"

[[ -d "$CD_ROOT" ]] || { echo "ERROR: $CD_ROOT 없음" >&2; exit 1; }

target_group_arn=$(terraform -chdir="$CD_ROOT" output -raw argocd_target_group_arn)
alb_security_group_id=$(terraform -chdir="$CD_ROOT" output -raw ops_alb_security_group_id)
rds_master_secret_arn=$(terraform -chdir="$CD_ROOT" output -raw rds_master_secret_arn)

[[ $(grep -c '^[[:space:]]*targetGroupARN:' "$TGB_FILE") -eq 1 ]]
[[ $(grep -c '^[[:space:]]*groupID:' "$TGB_FILE") -eq 1 ]]
[[ $(grep -c 'objectName: "arn:aws:secretsmanager:.*:secret:rds!db-' "$SECRETS_FILE") -eq 1 ]]

sed -i -E "s|^([[:space:]]*targetGroupARN:).*|\1 ${target_group_arn} # HARD-CODED: render-aws-runtime.sh로 갱신|" "$TGB_FILE"
sed -i -E "s|^([[:space:]]*groupID:).*|\1 ${alb_security_group_id} # HARD-CODED: render-aws-runtime.sh로 갱신|" "$TGB_FILE"
sed -i -E "s|^([[:space:]]*- objectName:) \"arn:aws:secretsmanager:.*:secret:rds!db-[^\"]+\".*|\1 \"${rds_master_secret_arn}\" # HARD-CODED: render-aws-runtime.sh로 갱신|" "$SECRETS_FILE"

echo "AWS 런타임 값 갱신 완료:"
echo "  $TGB_FILE"
echo "  $SECRETS_FILE"

