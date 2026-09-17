#!/usr/bin/env bash
# Terraform이 만든 Secret 컨테이너에 애플리케이션 DB 자격 증명을 최초 한 번 주입한다.
# 값은 stdin으로만 전달하고 파일, Git, 명령 인자에 남기지 않는다.
set -Eeuo pipefail
export AWS_PAGER=""

# HARD-CODED: 다른 계정/리전에서는 모두 변경한다.
EXPECTED_ACCOUNT=769413326616
REGION=ap-northeast-2

die() { echo "ERROR: $*" >&2; exit 1; }
for tool in aws openssl jq; do
  command -v "$tool" >/dev/null || die "필수 명령 없음: $tool"
done

account=$(aws sts get-caller-identity --query Account --output text)
[[ "$account" == "$EXPECTED_ACCOUNT" ]] || die "대상 AWS 계정 불일치: $account"

prepare_secret() {
  local secret_name="$1"
  local db_username="$2"

  aws secretsmanager describe-secret --region "$REGION" --secret-id "$secret_name" >/dev/null \
    || die "Secret 컨테이너가 없습니다 ($secret_name). Infra/aws-cd-bootstrap을 먼저 apply하세요."

  local current_count
  current_count=$(aws secretsmanager list-secret-version-ids \
    --region "$REGION" --secret-id "$secret_name" \
    --query "length(Versions[?contains(VersionStages, 'AWSCURRENT')])" --output text)

  if [[ "$current_count" == 0 ]]; then
    local password
    password=$(openssl rand -hex 32)
    trap 'unset password' RETURN
    printf '{"username":"%s","password":"%s"}' "$db_username" "$password" |
      aws secretsmanager put-secret-value \
        --region "$REGION" --secret-id "$secret_name" \
        --secret-string file:///dev/stdin >/dev/null
    unset password
    trap - RETURN
    echo "DB 애플리케이션 Secret 값을 최초 생성했습니다. ($secret_name)"
  else
    aws secretsmanager get-secret-value \
      --region "$REGION" --secret-id "$secret_name" \
      --query SecretString --output text |
      jq -e 'type == "object" and (.username | type == "string" and length > 0) and (.password | type == "string" and length > 0)' >/dev/null \
      || die "기존 Secret 값이 username/password JSON 형식이 아닙니다. ($secret_name)"
    echo "기존 DB 애플리케이션 Secret 값을 재사용합니다. ($secret_name)"
  fi
}

prepare_secret "/boa/database/accounts" "accounts_app"
prepare_secret "/boa/database/ledger" "ledger_app"
