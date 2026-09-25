#!/usr/bin/env bash
# 목적: Terraform output의 AWS 동적 ARN/ID를 GitOps manifest에 렌더링한다.
# 입력: --infra-root /absolute/path/to/Infra.
# 결과: Argo CD TargetGroupBinding과 RDS Secret ARN이 현재 인프라 값으로 갱신된다.
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
MANUAL_SECRETS_FILE="$REPO_ROOT/manual/eks/secrets.yaml"
GITOPS_SECRETS_FILE="$REPO_ROOT/03_manifests/overlays/eks/shared/secrets.yaml"

[[ -d "$OPS_ROOT" && -d "$DB_ROOT" ]] || {
  echo "ERROR: Infra root 경로가 올바르지 않습니다: $INFRA_ROOT" >&2
  exit 1
}

# Terraform state에서 현재 Target Group, Security Group, RDS Secret ARN을 읽는다.
TARGET_GROUP_ARN=$(terraform -chdir="$OPS_ROOT" output -raw argocd_target_group_arn)
ALB_SECURITY_GROUP_ID=$(terraform -chdir="$OPS_ROOT" output -raw ops_alb_security_group_id)
RDS_MASTER_SECRET_ARN=$(terraform -chdir="$DB_ROOT" output -raw rds_master_secret_arn)

# 잘못된 계정이나 형식의 값을 manifest에 쓰지 않도록 검증한다.
[[ "$TARGET_GROUP_ARN" == arn:aws:elasticloadbalancing:*:"$EXPECTED_ACCOUNT":targetgroup/* ]]
[[ "$ALB_SECURITY_GROUP_ID" =~ ^sg-[0-9a-f]+$ ]]
[[ "$RDS_MASTER_SECRET_ARN" == arn:aws:secretsmanager:*:"$EXPECTED_ACCOUNT":secret:rds\!db-* ]]

# 치환 대상이 파일마다 정확히 하나인지 확인한다.
[[ $(grep -Ec '^[[:space:]]*targetGroupARN:' "$TGB_FILE") -eq 1 ]]
[[ $(grep -Ec '^[[:space:]]*groupID:' "$TGB_FILE") -eq 1 ]]
for file in "$MANUAL_SECRETS_FILE" "$GITOPS_SECRETS_FILE"; do
  [[ $(grep -Ec 'objectName: "arn:aws:secretsmanager:.*:secret:rds!db-' "$file") -eq 1 ]]
done

# AWS 런타임 값만 치환하고 다른 manifest 내용은 건드리지 않는다.
sed -i -E "s|^([[:space:]]*targetGroupARN:).*|\1 $TARGET_GROUP_ARN # aws-render-runtime.sh로 갱신|" "$TGB_FILE"
sed -i -E "s|^([[:space:]]*groupID:).*|\1 $ALB_SECURITY_GROUP_ID # aws-render-runtime.sh로 갱신|" "$TGB_FILE"
for file in "$MANUAL_SECRETS_FILE" "$GITOPS_SECRETS_FILE"; do
  sed -i -E "s|^([[:space:]]*- objectName:) \"arn:aws:secretsmanager:.*:secret:rds!db-[^\"]+\".*|\1 \"$RDS_MASTER_SECRET_ARN\" # aws-render-runtime.sh로 갱신|" "$file"
done

echo "완료: AWS 런타임 값이 갱신되었습니다."
printf '  %s\n' "$TGB_FILE" "$MANUAL_SECRETS_FILE" "$GITOPS_SECRETS_FILE"
