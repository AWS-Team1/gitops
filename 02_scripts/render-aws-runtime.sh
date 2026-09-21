#!/usr/bin/env bash
# Terraform output으로 AWS 런타임 값을 갱신한다. 기본은 수동 배포 YAML만 대상이다.
set -Eeuo pipefail

usage() { echo "Usage: $0 --infra-root /absolute/path/to/Infra [--gitops]"; }
INFRA_ROOT=""
# 명시적으로 전달된 Infra 저장소만 읽어 다른 Terraform 상태를 참조하지 않게 한다.
RENDER_GITOPS=false
while [[ $# -gt 0 ]]; do
  case "$1" in
    --infra-root) INFRA_ROOT=${2:?경로가 필요합니다}; shift 2 ;;
    --gitops) RENDER_GITOPS=true; shift ;;
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
GITOPS_SECRETS_FILE="$REPO_ROOT/03_manifests/eks/shared/secrets.yaml"

[[ -d "$OPS_ROOT" && -d "$DB_ROOT" ]] || { echo "ERROR: Infra root 경로가 올바르지 않습니다: $INFRA_ROOT" >&2; exit 1; }

# Terraform state에서 Argo CD ALB와 RDS Secret의 현재 런타임 값을 읽는다.
target_group_arn=$(terraform -chdir="$OPS_ROOT" output -raw argocd_target_group_arn)
alb_security_group_id=$(terraform -chdir="$OPS_ROOT" output -raw ops_alb_security_group_id)
rds_master_secret_arn=$(terraform -chdir="$DB_ROOT" output -raw rds_master_secret_arn)

# 계정과 리소스 형식을 검증해 잘못된 state 값이 매니페스트에 들어가는 것을 막는다.
[[ "$target_group_arn" == arn:aws:elasticloadbalancing:*:"$EXPECTED_ACCOUNT":targetgroup/* ]]
[[ "$alb_security_group_id" =~ ^sg-[0-9a-f]+$ ]]
[[ "$rds_master_secret_arn" == arn:aws:secretsmanager:*:"$EXPECTED_ACCOUNT":secret:rds\!db-* ]]

# 치환 대상이 정확히 하나씩 있는지 확인해 중복 또는 누락된 YAML을 수정하지 않는다.
[[ $(grep -Ec '^[[:space:]]*targetGroupARN:' "$TGB_FILE") -eq 1 ]]
[[ $(grep -Ec '^[[:space:]]*groupID:' "$TGB_FILE") -eq 1 ]]
[[ $(grep -Ec 'objectName: "arn:aws:secretsmanager:.*:secret:rds!db-' "$SECRETS_FILE") -eq 1 ]]

# 최초 수동 배포용 매니페스트를 갱신하고, 요청된 경우 GitOps 선언값도 함께 갱신한다.
sed -i -E "s|^([[:space:]]*targetGroupARN:).*|\1 $target_group_arn # render-aws-runtime.sh로 갱신|" "$TGB_FILE"
sed -i -E "s|^([[:space:]]*groupID:).*|\1 $alb_security_group_id # render-aws-runtime.sh로 갱신|" "$TGB_FILE"
sed -i -E "s|^([[:space:]]*- objectName:) \"arn:aws:secretsmanager:.*:secret:rds!db-[^\"]+\".*|\1 \"$rds_master_secret_arn\" # render-aws-runtime.sh로 갱신|" "$SECRETS_FILE"

if [[ "$RENDER_GITOPS" == true ]]; then
  [[ $(grep -Ec 'objectName: "arn:aws:secretsmanager:.*:secret:rds!db-' "$GITOPS_SECRETS_FILE") -eq 1 ]]
  sed -i -E "s|^([[:space:]]*- objectName:) \"arn:aws:secretsmanager:.*:secret:rds!db-[^\"]+\".*|\1 \"$rds_master_secret_arn\" # render-aws-runtime.sh로 갱신|" "$GITOPS_SECRETS_FILE"
fi

echo "AWS 런타임 값 갱신 완료:"
echo "  $TGB_FILE"
echo "  $SECRETS_FILE"
[[ "$RENDER_GITOPS" == true ]] && echo "  $GITOPS_SECRETS_FILE"
