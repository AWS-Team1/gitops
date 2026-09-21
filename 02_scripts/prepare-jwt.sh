#!/usr/bin/env bash
# JWT 키를 Secrets Manager에 준비한다. 두 Secret에 현재 버전이 없을 때만 새로 생성하고,
# 기존 키가 있으면 쌍이 맞는지 검증만 하고 그대로 재사용한다(기존 토큰 무효화 방지).
set -euo pipefail
export AWS_PAGER=""

# 고정값: 다른 환경에서는 리전, 계정 ID, Secret 이름을 변경한다.
REGION=ap-northeast-2
EXPECTED_ACCOUNT=769413326616        # 팀 계정. 다르면 중단(오배포 방지)
PRIVATE_SECRET=/boa/jwt/private
PUBLIC_SECRET=/boa/jwt/public

die() { echo "ERROR: $*" >&2; exit 1; }

# 필수 도구 확인
for tool in aws openssl; do
  command -v "$tool" >/dev/null || die "필수 명령 없음: $tool"
done

# 계정 가드
ACCOUNT=$(aws sts get-caller-identity --query Account --output text)
[[ "$ACCOUNT" == "$EXPECTED_ACCOUNT" ]] || die "대상 AWS 계정 불일치: $ACCOUNT"

# 해당 Secret에 AWSCURRENT(현재 버전)가 몇 개인지 = 값이 이미 들어있는지 판단
current_version_count() {
  aws secretsmanager list-secret-version-ids \
    --region "$REGION" --secret-id "$1" \
    --query "length(Versions[?contains(VersionStages, 'AWSCURRENT')])" \
    --output text
}

PRIVATE_CURRENT=$(current_version_count "$PRIVATE_SECRET")
PUBLIC_CURRENT=$(current_version_count "$PUBLIC_SECRET")

if [[ "$PRIVATE_CURRENT" == 0 && "$PUBLIC_CURRENT" == 0 ]]; then
  # 둘 다 비었을 때만 새 키 쌍 생성(RSA 4096) 후 Secrets Manager에 저장
  echo "JWT 키 쌍 최초 생성"
  trap 'unset PRIVATE_KEY PUBLIC_KEY' EXIT     # 종료 시 메모리에서 키 제거
  PRIVATE_KEY=$(openssl genrsa 4096 2>/dev/null)
  PUBLIC_KEY=$(printf '%s\n' "$PRIVATE_KEY" | openssl pkey -pubout)

  # 키는 stdin(file:///dev/stdin)으로만 전달 — 명령 인자/파일에 안 남김
  printf '%s\n' "$PRIVATE_KEY" |
    aws secretsmanager put-secret-value \
      --region "$REGION" --secret-id "$PRIVATE_SECRET" \
      --secret-string file:///dev/stdin >/dev/null
  printf '%s\n' "$PUBLIC_KEY" |
    aws secretsmanager put-secret-value \
      --region "$REGION" --secret-id "$PUBLIC_SECRET" \
      --secret-string file:///dev/stdin >/dev/null

  unset PRIVATE_KEY PUBLIC_KEY
elif [[ "$PRIVATE_CURRENT" -ge 1 && "$PUBLIC_CURRENT" -ge 1 ]]; then
  echo "기존 JWT 키 재사용"
else
  # 한쪽만 있는 부분 상태는 자동 처리하지 않고 중단(쌍 불일치 위험)
  die "JWT Secret이 부분 준비 상태임(private=$PRIVATE_CURRENT, public=$PUBLIC_CURRENT)"
fi

# 검증: private에서 유도한 공개키 == 저장된 public 키 (실제로 쌍이 맞는지)
DERIVED_PUBLIC=$(
  aws secretsmanager get-secret-value \
    --region "$REGION" --secret-id "$PRIVATE_SECRET" \
    --query SecretString --output text |
  openssl pkey -pubout 2>/dev/null
)
STORED_PUBLIC=$(
  aws secretsmanager get-secret-value \
    --region "$REGION" --secret-id "$PUBLIC_SECRET" \
    --query SecretString --output text |
  openssl pkey -pubin -pubout 2>/dev/null
)

[[ "$DERIVED_PUBLIC" == "$STORED_PUBLIC" ]] || die "JWT 키 쌍 불일치"
unset DERIVED_PUBLIC STORED_PUBLIC
echo "JWT 키 쌍 검증 성공"
