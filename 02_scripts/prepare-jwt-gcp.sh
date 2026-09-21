#!/usr/bin/env bash
# GCP Secret Manager에 JWT 키를 준비한다. 기존 키는 재사용한다.
set -Eeuo pipefail

PROJECT_ID=${GCP_PROJECT_ID:-kdt4-1-506106}
NAMESPACE=bank-of-anthos
SERVICE_ACCOUNT=bank-app-secret-sync
PRIVATE_SECRET=boa-jwt-private
PUBLIC_SECRET=boa-jwt-public

die() { echo "ERROR: $*" >&2; exit 1; }

for tool in gcloud openssl; do
  command -v "$tool" >/dev/null || die "필수 명령 없음: $tool"
done

ACCOUNT=$(gcloud auth list --filter=status:ACTIVE --format='value(account)' | head -n 1)
[[ -n "$ACCOUNT" ]] || die "gcloud 활성 계정이 없습니다"
PROJECT_NUMBER=$(gcloud projects describe "$PROJECT_ID" --format='value(projectNumber)')
[[ -n "$PROJECT_NUMBER" ]] || die "GCP 프로젝트를 찾지 못했습니다: $PROJECT_ID"

for secret in "$PRIVATE_SECRET" "$PUBLIC_SECRET"; do
  gcloud secrets describe "$secret" --project="$PROJECT_ID" >/dev/null 2>&1 ||
    gcloud secrets create "$secret" --project="$PROJECT_ID" --replication-policy=automatic >/dev/null

  principal="principal://iam.googleapis.com/projects/$PROJECT_NUMBER/locations/global/workloadIdentityPools/$PROJECT_ID.svc.id.goog/subject/ns/$NAMESPACE/sa/$SERVICE_ACCOUNT"
  gcloud secrets add-iam-policy-binding "$secret" --project="$PROJECT_ID" \
    --member="$principal" --role=roles/secretmanager.secretAccessor >/dev/null
done

has_enabled_version() {
  [[ -n $(gcloud secrets versions list "$1" --project="$PROJECT_ID" \
    --filter='state=ENABLED' --limit=1 --format='value(name)') ]]
}

PRIVATE_READY=false
PUBLIC_READY=false
has_enabled_version "$PRIVATE_SECRET" && PRIVATE_READY=true
has_enabled_version "$PUBLIC_SECRET" && PUBLIC_READY=true

if [[ "$PRIVATE_READY" == false && "$PUBLIC_READY" == false ]]; then
  echo "JWT 키 쌍 최초 생성"
  trap 'unset PRIVATE_KEY PUBLIC_KEY' EXIT
  PRIVATE_KEY=$(openssl genrsa 4096 2>/dev/null)
  PUBLIC_KEY=$(printf '%s\n' "$PRIVATE_KEY" | openssl pkey -pubout)
  printf '%s\n' "$PRIVATE_KEY" |
    gcloud secrets versions add "$PRIVATE_SECRET" --project="$PROJECT_ID" --data-file=- >/dev/null
  printf '%s\n' "$PUBLIC_KEY" |
    gcloud secrets versions add "$PUBLIC_SECRET" --project="$PROJECT_ID" --data-file=- >/dev/null
  unset PRIVATE_KEY PUBLIC_KEY
elif [[ "$PRIVATE_READY" == true && "$PUBLIC_READY" == true ]]; then
  echo "기존 JWT 키 재사용"
else
  die "JWT Secret이 부분 준비 상태임(private=$PRIVATE_READY, public=$PUBLIC_READY)"
fi

DERIVED_PUBLIC=$(gcloud secrets versions access latest --secret="$PRIVATE_SECRET" \
  --project="$PROJECT_ID" | openssl pkey -pubout 2>/dev/null)
STORED_PUBLIC=$(gcloud secrets versions access latest --secret="$PUBLIC_SECRET" \
  --project="$PROJECT_ID" | openssl pkey -pubin -pubout 2>/dev/null)
[[ "$DERIVED_PUBLIC" == "$STORED_PUBLIC" ]] || die "JWT 키 쌍 불일치"
unset DERIVED_PUBLIC STORED_PUBLIC
echo "JWT 키 쌍 검증 성공: $PROJECT_ID ($ACCOUNT)"
