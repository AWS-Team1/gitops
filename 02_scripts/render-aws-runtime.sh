#!/usr/bin/env bash
# Terraform output으로 수동 배포용 AWS 런타임 값만 갱신한다.
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
OPS_ROOT="$INFRA_ROOT/aws-ops"
DB_ROOT="$INFRA_ROOT/aws-db-bootstrap"
EXPECTED_ACCOUNT=769413326616
TGB_FILE="$REPO_ROOT/manual/eks/argocd-exposure/targetgroupbinding.yaml"
SECRETS_FILE="$REPO_ROOT/manual/eks/secrets.yaml"

[[ -d "$OPS_ROOT" && -d "$DB_ROOT" ]] || { echo "ERROR: Infra root 경로가 올바르지 않습니다: $INFRA_ROOT" >&2; exit 1; }

target_group_arn=$(terraform -chdir="$OPS_ROOT" output -raw argocd_target_group_arn)
alb_security_group_id=$(terraform -chdir="$OPS_ROOT" output -raw ops_alb_security_group_id)
rds_master_secret_arn=$(terraform -chdir="$DB_ROOT" output -raw rds_master_secret_arn)

[[ "$target_group_arn" == arn:aws:elasticloadbalancing:*:"$EXPECTED_ACCOUNT":targetgroup/* ]]
[[ "$alb_security_group_id" =~ ^sg-[0-9a-f]+$ ]]
[[ "$rds_master_secret_arn" == arn:aws:secretsmanager:*:"$EXPECTED_ACCOUNT":secret:rds\!db-* ]]

[[ $(grep -Ec '^[[:space:]]*targetGroupARN:' "$TGB_FILE") -eq 1 ]]
[[ $(grep -Ec '^[[:space:]]*groupID:' "$TGB_FILE") -eq 1 ]]
[[ $(grep -Ec 'objectName: "arn:aws:secretsmanager:.*:secret:rds!db-' "$SECRETS_FILE") -eq 1 ]]

sed -i -E "s|^([[:space:]]*targetGroupARN:).*|\1 $target_group_arn # render-aws-runtime.sh로 갱신|" "$TGB_FILE"
sed -i -E "s|^([[:space:]]*groupID:).*|\1 $alb_security_group_id # render-aws-runtime.sh로 갱신|" "$TGB_FILE"
sed -i -E "s|^([[:space:]]*- objectName:) \"arn:aws:secretsmanager:.*:secret:rds!db-[^\"]+\".*|\1 \"$rds_master_secret_arn\" # render-aws-runtime.sh로 갱신|" "$SECRETS_FILE"

echo "수동 배포용 AWS 런타임 값 갱신 완료:"
echo "  $TGB_FILE"
echo "  $SECRETS_FILE"
echo "03_manifests 값은 변경하지 않았습니다."
