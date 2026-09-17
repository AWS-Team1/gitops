#!/usr/bin/env bash
# aws-db-bootstrap이 읽을 DB 비밀번호를 로컬 캐시에 최초 한 번 생성한다.
set -Eeuo pipefail

SECRET_NAME="${SECRET_NAME:-/boa/database/app}"
CACHE_DIR="${DB_PASSWORD_DIR:-${XDG_CACHE_HOME:-$HOME/.cache}/boa/database}"
PASSWORD_FILE="${PASSWORD_FILE:-$CACHE_DIR/${SECRET_NAME##*/}.password}"

command -v openssl >/dev/null || { echo "ERROR: 필수 명령 없음: openssl" >&2; exit 1; }

install -d -m 700 "$CACHE_DIR"
if [[ -s "$PASSWORD_FILE" ]]; then
  chmod 600 "$PASSWORD_FILE"
  echo "기존 DB 비밀번호 파일을 재사용합니다: $PASSWORD_FILE"
  exit 0
fi

umask 077
printf '%s' "$(openssl rand -hex 32)" >"$PASSWORD_FILE"
echo "DB 비밀번호 파일을 생성했습니다: $PASSWORD_FILE"
