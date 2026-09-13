#!/usr/bin/env bash
#
# bootstrap-eks.sh
#
# Terraform output을 source of truth로 삼아 이 GitOps 저장소를 렌더링하고,
# 정적으로 검증하고, (--apply 일 때만) EKS / Argo CD 에 적용한다.
#
# 기본 동작은 dry-run 이다. 실제 변경은 --apply 를 줄 때만 일어난다.
#
#   ./scripts/bootstrap-eks.sh --infra-dir ~/infra --environment dev
#   ./scripts/bootstrap-eks.sh --infra-dir ~/infra --environment dev --render
#   ./scripts/bootstrap-eks.sh --infra-dir ~/infra --environment dev --apply
#
# 설계 원칙
#   - Terraform output이 유일한 진실 공급원이다. AWS API를 따로 조회해 값을
#     추측하지 않는다 (호출하는 AWS API는 sts get-caller-identity 뿐이며 확인용이다).
#   - Secret 값(username/password/private key)은 읽지도, 출력하지도, 저장하지도
#     않는다. RDS master secret은 ARN(비밀 아닌 메타데이터)만 다룬다.
#   - 렌더링 결과는 Git에 커밋되어야 하며 그것이 Argo CD의 desired state다.
#     커밋되지 않은 렌더링 결과를 클러스터에 직접 밀어넣지 않는다.
#   - 몇 번을 실행해도 같은 결과가 나온다(idempotent).
#   - commit / push 는 하지 않는다. 사람이 검토하고 커밋한다.

set -Eeuo pipefail

SENTINEL='__BOOTSTRAP_PENDING__'
TOTAL_STEPS=10

# ---------------------------------------------------------------------------
# 출력 도우미
# ---------------------------------------------------------------------------
if [[ -t 1 ]]; then
  C_RED=$'\033[31m'; C_YLW=$'\033[33m'; C_GRN=$'\033[32m'; C_DIM=$'\033[2m'; C_OFF=$'\033[0m'
else
  C_RED=''; C_YLW=''; C_GRN=''; C_DIM=''; C_OFF=''
fi

CURRENT_STEP='시작'

log()  { printf '%s\n' "$*"; }
step() { CURRENT_STEP="$1"; printf '\n%s==> [%s/%s] %s%s\n' "$C_GRN" "$2" "$TOTAL_STEPS" "$1" "$C_OFF"; }
info() { printf '    %s\n' "$*"; }
dim()  { printf '    %s%s%s\n' "$C_DIM" "$*" "$C_OFF"; }
warn() { printf '%swarn:%s %s\n' "$C_YLW" "$C_OFF" "$*" >&2; }
die()  { printf '\n%s실패 단계: %s%s\n%serror:%s %s\n' "$C_RED" "$CURRENT_STEP" "$C_OFF" "$C_RED" "$C_OFF" "$*" >&2; exit 1; }

trap 'die "line ${LINENO}: 명령이 실패했습니다 (종료 코드 $?)"' ERR

usage() {
  cat <<'USAGE'
Usage: bootstrap-eks.sh [options]

Modes (기본: dry-run)
  --dry-run             임시 디렉터리에 렌더링해 diff만 보여준다. 아무것도 바꾸지 않는다.
  --render              렌더링 결과를 이 저장소에 기록한다. 클러스터는 건드리지 않는다.
  --apply               렌더링 + 저장소 기록 + kubeconfig 갱신 + Kubernetes/Argo CD 적용

Paths (절대경로 하드코딩 없음)
  --infra-dir DIR       Terraform root 이자 infra 저장소 경로
                        (기본: $INFRA_DIR, 없으면 <이 저장소의 부모>/infra)
  --tf-dir DIR          Terraform root 만 따로 지정 (기본: --infra-dir 과 동일)
  --gitops-dir DIR      이 GitOps 저장소 (기본: 이 스크립트의 상위 디렉터리)
  --env-file FILE       환경 입력 파일 (기본: <gitops>/environments/<env>/aws.env)

Options
  --environment NAME    overlay 환경 이름 (기본: dev).  별칭: --env
  --skip-argocd-install --apply 시 Argo CD Helm 설치/업그레이드를 건너뛴다
  --skip-wait           --apply 시 sync/rollout 대기를 건너뛴다
  --allow-dirty         렌더링 결과가 커밋/푸시되지 않아도 --apply 를 진행한다 (비권장)
  --timeout SECONDS     rollout / sync 대기 시간 (기본: 600)
  -h, --help            이 도움말
USAGE
}

# ---------------------------------------------------------------------------
# 인자 파싱
# ---------------------------------------------------------------------------
MODE=dry-run
GITOPS_DIR=${GITOPS_DIR:-}
INFRA_DIR=${INFRA_DIR:-}
TF_DIR=${TF_DIR:-}
ENV_FILE=${ENV_FILE:-}
ENV_NAME=dev
SKIP_ARGOCD_INSTALL=false
SKIP_WAIT=false
ALLOW_DIRTY=false
WAIT_TIMEOUT=600

while [[ $# -gt 0 ]]; do
  case "$1" in
    --dry-run) MODE=dry-run; shift ;;
    --render)  MODE=render;  shift ;;
    --apply)   MODE=apply;   shift ;;
    --infra-dir)  INFRA_DIR=${2:?--infra-dir 값이 필요합니다};   shift 2 ;;
    --tf-dir)     TF_DIR=${2:?--tf-dir 값이 필요합니다};         shift 2 ;;
    --gitops-dir) GITOPS_DIR=${2:?--gitops-dir 값이 필요합니다}; shift 2 ;;
    --env-file)   ENV_FILE=${2:?--env-file 값이 필요합니다};     shift 2 ;;
    --environment|--env) ENV_NAME=${2:?--environment 값이 필요합니다}; shift 2 ;;
    --skip-argocd-install) SKIP_ARGOCD_INSTALL=true; shift ;;
    --skip-wait)           SKIP_WAIT=true;           shift ;;
    --allow-dirty)         ALLOW_DIRTY=true;         shift ;;
    --timeout) WAIT_TIMEOUT=${2:?--timeout 값이 필요합니다};     shift 2 ;;
    -h|--help) usage; exit 0 ;;
    *) usage >&2; die "알 수 없는 인자: $1" ;;
  esac
done

[[ "$WAIT_TIMEOUT" =~ ^[0-9]+$ ]] || die "--timeout 은 정수여야 합니다: $WAIT_TIMEOUT"
[[ "$ENV_NAME"     =~ ^[a-z0-9][a-z0-9-]*$ ]] || die "--environment 형식이 올바르지 않습니다: $ENV_NAME"

# ---------------------------------------------------------------------------
# 경로 해석 (절대경로 하드코딩 없음)
# ---------------------------------------------------------------------------
script_dir=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
: "${GITOPS_DIR:=$(cd -- "${script_dir}/.." && pwd)}"
[[ -d "$GITOPS_DIR" ]] || die "GitOps 디렉터리가 없습니다: $GITOPS_DIR"
GITOPS_DIR=$(cd -- "$GITOPS_DIR" && pwd)
[[ -d "${GITOPS_DIR}/k8s/overlays" && -d "${GITOPS_DIR}/argocd" ]] \
  || die "GitOps 저장소로 보이지 않습니다: $GITOPS_DIR"

: "${INFRA_DIR:=$(dirname -- "$GITOPS_DIR")/infra}"
[[ -d "$INFRA_DIR" ]] || die "infra 디렉터리가 없습니다: $INFRA_DIR (--infra-dir 로 지정하세요)"
INFRA_DIR=$(cd -- "$INFRA_DIR" && pwd)

: "${TF_DIR:=$INFRA_DIR}"
[[ -d "$TF_DIR" ]] || die "Terraform 디렉터리가 없습니다: $TF_DIR"
TF_DIR=$(cd -- "$TF_DIR" && pwd)

# ---------------------------------------------------------------------------
step "필수 명령 확인" 1
# ---------------------------------------------------------------------------
need_cmd() { command -v "$1" >/dev/null 2>&1 || die "필수 명령이 없습니다: $1 ($2)"; }
need_cmd aws       "AWS CLI v2"
need_cmd terraform "Terraform >= 1.10"
need_cmd kubectl   "kubectl"
need_cmd jq        "jq"
need_cmd git       "git"

if command -v kustomize >/dev/null 2>&1; then
  kustomize_build() { kustomize build "$1"; }
  info "kustomize : $(command -v kustomize)"
else
  kustomize_build() { kubectl kustomize "$1"; }
  info "kustomize : kubectl 내장 (kubectl kustomize)"
fi

if [[ "$MODE" == apply && "$SKIP_ARGOCD_INSTALL" != true ]]; then
  need_cmd helm "Helm 3 (Argo CD 설치용, 또는 --skip-argocd-install)"
fi

info "mode      : $MODE"
info "gitops    : $GITOPS_DIR"
info "infra     : $INFRA_DIR"
info "terraform : $TF_DIR"

# ---------------------------------------------------------------------------
step "환경 입력 파일 로드" 2
# ---------------------------------------------------------------------------
: "${ENV_FILE:=${GITOPS_DIR}/environments/${ENV_NAME}/aws.env}"
[[ -f "$ENV_FILE" ]] || die "환경 파일이 없습니다: $ENV_FILE"

# 임의 코드 실행을 막기 위해 KEY=VALUE / 주석 / 빈 줄만 허용한다.
if grep -vqE '^[[:space:]]*(#|$)|^[A-Z_][A-Z0-9_]*=' "$ENV_FILE"; then
  grep -nvE '^[[:space:]]*(#|$)|^[A-Z_][A-Z0-9_]*=' "$ENV_FILE" >&2 || true
  die "환경 파일에 KEY=VALUE 형식이 아닌 줄이 있습니다: $ENV_FILE"
fi
set -a
# shellcheck source=/dev/null
source "$ENV_FILE"
set +a

NAMESPACE=${NAMESPACE:-bank-of-anthos}
GIT_TARGET_REVISION=${GIT_TARGET_REVISION:-dev}
ACCOUNTS_DB_NAME=${ACCOUNTS_DB_NAME:-accountsdb}
LEDGER_DB_NAME=${LEDGER_DB_NAME:-ledgerdb}
ECR_REGISTRY=${ECR_REGISTRY:-}
INGRESS_HOST=${INGRESS_HOST:-}
ACM_CERTIFICATE_ARN=${ACM_CERTIFICATE_ARN:-}
ALB_SSL_POLICY=${ALB_SSL_POLICY:-}
ENABLE_APP_INGRESS=${ENABLE_APP_INGRESS:-true}
ARGOCD_TARGET_GROUP_ARN=${ARGOCD_TARGET_GROUP_ARN:-}
ARGOCD_CHART_VERSION=${ARGOCD_CHART_VERSION:-10.4.0}
GITOPS_REPO_URL=${GITOPS_REPO_URL:-}

OVERLAY_REL="k8s/overlays/${ENV_NAME}/aws"
[[ -d "${GITOPS_DIR}/${OVERLAY_REL}" ]] || die "overlay 가 없습니다: ${GITOPS_DIR}/${OVERLAY_REL}"

# Argo CD 가 읽을 저장소 URL 은 origin remote 에서 유도한다(하드코딩 회피).
if [[ -z "$GITOPS_REPO_URL" ]]; then
  origin=$(git -C "$GITOPS_DIR" remote get-url origin 2>/dev/null) \
    || die "origin remote 를 찾을 수 없습니다. 환경 파일에 GITOPS_REPO_URL 을 설정하세요."
  case "$origin" in
    git@*:*)        GITOPS_REPO_URL="https://${origin#git@}"; GITOPS_REPO_URL=${GITOPS_REPO_URL/:/\/} ;;
    ssh://git@*)    GITOPS_REPO_URL="https://${origin#ssh://git@}" ;;
    *)              GITOPS_REPO_URL="$origin" ;;
  esac
  [[ "$GITOPS_REPO_URL" == *.git ]] || GITOPS_REPO_URL="${GITOPS_REPO_URL}.git"
fi

info "env file   : ${ENV_FILE#"$GITOPS_DIR"/}"
info "environment: $ENV_NAME"
info "namespace  : $NAMESPACE"
info "overlay    : $OVERLAY_REL"
info "repo URL   : $GITOPS_REPO_URL"
info "revision   : $GIT_TARGET_REVISION"

# ---------------------------------------------------------------------------
step "AWS identity 확인" 3
# ---------------------------------------------------------------------------
caller_json=$(aws sts get-caller-identity --output json) \
  || die "AWS 자격 증명을 확인할 수 없습니다. aws configure / 인스턴스 역할을 확인하세요."
caller_account=$(jq -r '.Account' <<<"$caller_json")
info "account : $caller_account"
info "arn     : $(jq -r '.Arn' <<<"$caller_json")"

# ---------------------------------------------------------------------------
step "Terraform output 읽기" 4
# ---------------------------------------------------------------------------
if ! tf_json=$(terraform -chdir="$TF_DIR" output -json 2>/dev/null); then
  die "terraform output 실패.
  먼저 'terraform -chdir=${TF_DIR} init' 와 'terraform -chdir=${TF_DIR} apply' 가 완료되어야 합니다."
fi
[[ "$(jq -r 'length' <<<"$tf_json")" != "0" ]] \
  || die "Terraform output 이 비어 있습니다. 인프라가 아직 apply 되지 않았습니다."

# null / unknown 값을 빈 문자열로 정규화한다.
tf_out() {
  jq -r --arg k "$1" '
    if has($k) then (.[$k].value // "") else "" end
    | if . == null or . == "null" then "" else tostring end' <<<"$tf_json"
}

TF_REGION=$(tf_out aws_region)
TF_ACCOUNT_ID=$(tf_out aws_account_id)
TF_ECR_REGISTRY=$(tf_out ecr_registry)
TF_CLUSTER_NAME=$(tf_out eks_cluster_name)
TF_VPC_ID=$(tf_out vpc_id)
TF_RDS_ADDRESS=$(tf_out rds_address)
TF_RDS_PORT=$(tf_out rds_port)
TF_RDS_SECRET_ARN=$(tf_out rds_master_user_secret_arn)
TF_RDS_APP_SECRET_ARN=$(tf_out rds_app_secret_arn)
TF_RDS_APP_DB_USER=$(tf_out rds_app_db_username)
TF_RDS_BOOTSTRAP_DB=$(tf_out rds_bootstrap_db_name)

missing=()
for pair in \
  "aws_region:$TF_REGION" \
  "aws_account_id:$TF_ACCOUNT_ID" \
  "ecr_registry:$TF_ECR_REGISTRY" \
  "eks_cluster_name:$TF_CLUSTER_NAME" \
  "rds_address:$TF_RDS_ADDRESS" \
  "rds_port:$TF_RDS_PORT" \
  "rds_master_user_secret_arn:$TF_RDS_SECRET_ARN" \
  "rds_app_secret_arn:$TF_RDS_APP_SECRET_ARN" \
  "rds_bootstrap_db_name:$TF_RDS_BOOTSTRAP_DB"
do
  [[ -n "${pair#*:}" ]] || missing+=("${pair%%:*}")
done
if (( ${#missing[@]} )); then
  die "필수 Terraform output 이 비어 있거나 없습니다: ${missing[*]}
  infra 저장소의 root outputs.tf 를 확인하고 terraform apply 를 다시 실행하세요."
fi

[[ "$TF_ACCOUNT_ID" == "$caller_account" ]] \
  || die "Terraform state 의 계정($TF_ACCOUNT_ID)과 현재 AWS 자격 증명의 계정($caller_account)이 다릅니다."

info "region       : $TF_REGION"
info "cluster      : $TF_CLUSTER_NAME"
info "rds endpoint : ${TF_RDS_ADDRESS}:${TF_RDS_PORT}"
[[ "$TF_RDS_SECRET_ARN" != "$TF_RDS_APP_SECRET_ARN" ]] \
  || die "rds_master_user_secret_arn 과 rds_app_secret_arn 이 같습니다.
  애플리케이션은 master secret 을 쓰면 안 됩니다."

info "master secret: $TF_RDS_SECRET_ARN"
dim  "               (db-bootstrap Job 전용)"
info "app secret   : $TF_RDS_APP_SECRET_ARN"
dim  "               (애플리케이션 Pod 전용, role ${TF_RDS_APP_DB_USER:-bank_app})"
dim  "(secret 값은 조회하지 않는다. ARN 만 사용한다.)"
info "bootstrap db : $TF_RDS_BOOTSTRAP_DB"
[[ -n "$TF_VPC_ID" ]]           && info "vpc          : $TF_VPC_ID"

# ---------------------------------------------------------------------------
step "Terraform 관리 대상이 아닌 입력값 검증" 5
# ---------------------------------------------------------------------------
if [[ -z "$ECR_REGISTRY" ]]; then
  ECR_REGISTRY=$TF_ECR_REGISTRY
  info "ecr registry : $ECR_REGISTRY (terraform output 유도)"
else
  info "ecr registry : $ECR_REGISTRY (환경 파일 지정)"
fi
[[ "$ECR_REGISTRY" =~ ^[0-9]{12}\.dkr\.ecr\.[a-z0-9-]+\.amazonaws\.com$ ]] \
  || die "ECR_REGISTRY 형식이 올바르지 않습니다: $ECR_REGISTRY"

case "$ENABLE_APP_INGRESS" in
  true|false) ;;
  *) die "ENABLE_APP_INGRESS 는 true 또는 false 여야 합니다: $ENABLE_APP_INGRESS" ;;
esac

if [[ "$ENABLE_APP_INGRESS" != true ]]; then
  # ALB 를 전혀 쓰지 않는 구성. Ingress 와 TargetGroupBinding 이 모두 없어야 한다.
  # Argo CD 와 애플리케이션은 kubectl port-forward 로 접근한다.
  [[ -z "$ARGOCD_TARGET_GROUP_ARN" ]] \
    || die "ENABLE_APP_INGRESS=false 인데 ARGOCD_TARGET_GROUP_ARN 이 설정되어 있습니다.
  ALB 를 쓰지 않으려면 둘 다 비워야 합니다."
  info "app ingress  : 생성하지 않음 (ENABLE_APP_INGRESS=false)"
  if [[ -n "${INGRESS_HOST}${ACM_CERTIFICATE_ARN}" ]]; then
    dim "               INGRESS_HOST / ACM_CERTIFICATE_ARN / ALB_SSL_POLICY 는 무시됩니다"
  fi
  info "argocd tgb   : 생성하지 않음"
else
  if [[ -n "$ACM_CERTIFICATE_ARN" ]]; then
    [[ "$ACM_CERTIFICATE_ARN" =~ ^arn:aws[a-z-]*:acm:[a-z0-9-]+:[0-9]{12}:certificate/ ]] \
      || die "ACM_CERTIFICATE_ARN 형식이 올바르지 않습니다: $ACM_CERTIFICATE_ARN"
    [[ "$ACM_CERTIFICATE_ARN" == *":${TF_ACCOUNT_ID}:"* ]] \
      || die "ACM_CERTIFICATE_ARN 이 현재 계정(${TF_ACCOUNT_ID})의 것이 아닙니다."
    [[ -n "$INGRESS_HOST" ]] \
      || die "ACM_CERTIFICATE_ARN 을 설정하려면 INGRESS_HOST 도 반드시 설정해야 합니다."
    # Terraform 이 관리하지 않는 리소스이므로 실재 여부를 직접 확인한다.
    cert_status=$(aws acm describe-certificate --region "$TF_REGION" \
      --certificate-arn "$ACM_CERTIFICATE_ARN" \
      --query 'Certificate.Status' --output text 2>/dev/null || true)
    [[ -n "$cert_status" ]] \
      || die "ACM 인증서를 찾을 수 없습니다: $ACM_CERTIFICATE_ARN
    environments/${ENV_NAME}/aws.env 의 ACM_CERTIFICATE_ARN 을 확인하세요."
    [[ "$cert_status" == "ISSUED" ]] \
      || die "ACM 인증서 상태가 ISSUED 가 아닙니다: ${cert_status}"
    if [[ -n "$ALB_SSL_POLICY" ]]; then
      [[ "$ALB_SSL_POLICY" =~ ^ELBSecurityPolicy-[A-Za-z0-9.-]+$ ]] \
        || die "ALB_SSL_POLICY 형식이 올바르지 않습니다: $ALB_SSL_POLICY"
      info "tls          : HTTPS 443 (ACM), policy ${ALB_SSL_POLICY}"
    else
      info "tls          : HTTPS 443 (ACM), ALB 기본 정책"
    fi
  else
    info "tls          : HTTP 80 only (ACM_CERTIFICATE_ARN 미설정)"
  fi

  if [[ -n "$INGRESS_HOST" ]]; then
    [[ "$INGRESS_HOST" =~ ^[a-z0-9]([a-z0-9.-]*[a-z0-9])?$ ]] \
      || die "INGRESS_HOST 형식이 올바르지 않습니다: $INGRESS_HOST"
    info "ingress host : $INGRESS_HOST"
  else
    info "ingress host : (없음) ALB DNS 로만 접근"
  fi

  if [[ -n "$ARGOCD_TARGET_GROUP_ARN" ]]; then
    [[ "$ARGOCD_TARGET_GROUP_ARN" =~ ^arn:aws[a-z-]*:elasticloadbalancing:[a-z0-9-]+:[0-9]{12}:targetgroup/ ]] \
      || die "ARGOCD_TARGET_GROUP_ARN 형식이 올바르지 않습니다: $ARGOCD_TARGET_GROUP_ARN"
    [[ "$ARGOCD_TARGET_GROUP_ARN" == *":${TF_ACCOUNT_ID}:"* ]] \
      || die "ARGOCD_TARGET_GROUP_ARN 이 현재 계정(${TF_ACCOUNT_ID})의 것이 아닙니다."
    # Terraform 이 관리하지 않는 리소스이므로 실재 여부를 직접 확인한다.
    aws elbv2 describe-target-groups --region "$TF_REGION" \
      --target-group-arns "$ARGOCD_TARGET_GROUP_ARN" >/dev/null 2>&1 \
      || die "Target Group 을 찾을 수 없습니다: $ARGOCD_TARGET_GROUP_ARN
    이전 환경에서 남은 값일 수 있습니다. Argo CD 를 ALB 에 붙이지 않으려면
    environments/${ENV_NAME}/aws.env 의 ARGOCD_TARGET_GROUP_ARN 을 비우세요."
    info "argocd tgb   : 생성함"
  else
    info "argocd tgb   : 생성하지 않음"
  fi
fi

# ---------------------------------------------------------------------------
step "매니페스트 렌더링" 6
# ---------------------------------------------------------------------------
if [[ "$MODE" == dry-run ]]; then
  RENDER_ROOT=$(mktemp -d)
  trap 'rm -rf "$RENDER_ROOT"' EXIT
  cp -a "${GITOPS_DIR}/k8s" "${GITOPS_DIR}/argocd" "${GITOPS_DIR}/bootstrap" "${RENDER_ROOT}/"
  dim "dry-run: ${RENDER_ROOT} 에 렌더링합니다. 저장소는 변경되지 않습니다."
else
  RENDER_ROOT=$GITOPS_DIR
fi

R_OVERLAY="${RENDER_ROOT}/${OVERLAY_REL}"
R_ARGOCD="${RENDER_ROOT}/argocd"
R_BOOTSTRAP="${RENDER_ROOT}/bootstrap"

changed_files=()
rel() { printf '%s' "${1#"$RENDER_ROOT"/}"; }

write_file() {  # write_file <path> ; 내용은 stdin
  local dest=$1 tmp
  tmp=$(mktemp "${dest}.tmp.XXXXXX")
  cat >"$tmp"
  if [[ -f "$dest" ]] && cmp -s "$tmp" "$dest"; then
    rm -f "$tmp"; dim "unchanged  $(rel "$dest")"
  else
    mv -f "$tmp" "$dest"; chmod 0644 "$dest"
    changed_files+=("$(rel "$dest")"); info "rendered   $(rel "$dest")"
  fi
}

sed_file() {  # sed_file <path> <expr> [<expr>...]
  local dest=$1; shift
  local args=() e
  for e in "$@"; do args+=(-e "$e"); done
  local tmp; tmp=$(mktemp "${dest}.tmp.XXXXXX")
  sed -E "${args[@]}" "$dest" >"$tmp"
  if cmp -s "$tmp" "$dest"; then
    rm -f "$tmp"; dim "unchanged  $(rel "$dest")"
  else
    mv -f "$tmp" "$dest"; chmod 0644 "$dest"
    changed_files+=("$(rel "$dest")"); info "rendered   $(rel "$dest")"
  fi
}

# 6a. DB 접속 메타데이터 (ConfigMap generator 입력)
write_file "${R_OVERLAY}/env-config.properties" <<EOF
# GENERATED FILE - do not edit manually.
# Rendered by scripts/bootstrap-eks.sh from \`terraform output -json\`.
# Non-secret environment metadata only. No credentials here.
DB_HOST=${TF_RDS_ADDRESS}
DB_PORT=${TF_RDS_PORT}
BOOTSTRAP_DB_NAME=${TF_RDS_BOOTSTRAP_DB}
ACCOUNTS_DB_NAME=${ACCOUNTS_DB_NAME}
LEDGER_DB_NAME=${LEDGER_DB_NAME}
EOF

# 6b. 애플리케이션 SecretProviderClass - 앱 secret + JWT 만. master 는 참조하지 않는다.
write_file "${R_OVERLAY}/secretproviderclass.yaml" <<EOF
# GENERATED FILE - do not edit manually.
# Rendered by scripts/bootstrap-eks.sh.
#
# 애플리케이션 Pod 전용. 최소 권한 DB 자격 증명(/project/database/app,
# terraform output rds_app_secret_arn)과 JWT 키만 참조한다.
# RDS master secret 은 여기 없으며, 앱 IAM Role 도 접근 권한이 없다.
# The secret VALUE is never read, printed or stored - only the ARN.
apiVersion: secrets-store.csi.x-k8s.io/v1
kind: SecretProviderClass
metadata:
  name: bank-of-anthos-secrets
  annotations:
    argocd.argoproj.io/sync-wave: "-3"
spec:
  provider: aws
  parameters:
    usePodIdentity: "true"
    objects: |
      - objectName: "${TF_RDS_APP_SECRET_ARN}"
        objectType: "secretsmanager"
        jmesPath:
          - path: username
            objectAlias: db-username
          - path: password
            objectAlias: db-password
      - objectName: "/project/jwt/public"
        objectType: "secretsmanager"
        objectAlias: jwtRS256.key.pub
      - objectName: "/project/jwt/private"
        objectType: "secretsmanager"
        objectAlias: jwtRS256.key
  secretObjects:
    - secretName: db-secret
      type: Opaque
      data:
        - key: username
          objectName: db-username
        - key: password
          objectName: db-password
EOF

# 6b-2. db-bootstrap SecretProviderClass - master secret 을 참조하는 유일한 리소스.
#       secretObjects 가 없으므로 Kubernetes Secret 으로 동기화되지 않는다.
write_file "${R_OVERLAY}/secretproviderclass-db-bootstrap.yaml" <<EOF
# GENERATED FILE - do not edit manually.
# Rendered by scripts/bootstrap-eks.sh.
#
# db-bootstrap Job 전용. RDS master secret 을 참조하는 유일한 리소스다.
# secretObjects 가 없으므로 Kubernetes Secret 으로 동기화되지 않고,
# Job Pod 안에 파일로만 마운트된다.
# The secret VALUES are never read, printed or stored - only the ARNs.
apiVersion: secrets-store.csi.x-k8s.io/v1
kind: SecretProviderClass
metadata:
  name: bank-of-anthos-db-bootstrap-secrets
  annotations:
    argocd.argoproj.io/sync-wave: "-3"
spec:
  provider: aws
  parameters:
    usePodIdentity: "true"
    objects: |
      - objectName: "${TF_RDS_SECRET_ARN}"
        objectType: "secretsmanager"
        jmesPath:
          - path: username
            objectAlias: master-username
          - path: password
            objectAlias: master-password
      - objectName: "${TF_RDS_APP_SECRET_ARN}"
        objectType: "secretsmanager"
        jmesPath:
          - path: username
            objectAlias: app-username
          - path: password
            objectAlias: app-password
EOF

# 6c. Ingress (host / ACM 은 환경 입력값). ENABLE_APP_INGRESS=false 면 만들지 않는다.
if [[ "$ENABLE_APP_INGRESS" == true ]]; then
{
  cat <<EOF
# GENERATED FILE - do not edit manually.
# Rendered by scripts/bootstrap-eks.sh.
# Host / certificate come from environments/${ENV_NAME}/aws.env, not from
# Terraform, because ACM and DNS are not managed by the infra stack yet.
apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
  name: project-ingress
  annotations:
    kubernetes.io/ingress.class: alb
    alb.ingress.kubernetes.io/scheme: internet-facing
    alb.ingress.kubernetes.io/target-type: ip
EOF
  if [[ -n "$ACM_CERTIFICATE_ARN" ]]; then
    cat <<EOF
    alb.ingress.kubernetes.io/listen-ports: '[{"HTTP": 80}, {"HTTPS": 443}]'
    alb.ingress.kubernetes.io/certificate-arn: ${ACM_CERTIFICATE_ARN}
    alb.ingress.kubernetes.io/ssl-redirect: "443"
EOF
    if [[ -n "$ALB_SSL_POLICY" ]]; then
      printf '    alb.ingress.kubernetes.io/ssl-policy: %s\n' "$ALB_SSL_POLICY"
    fi
  else
    printf '%s\n' "    alb.ingress.kubernetes.io/listen-ports: '[{\"HTTP\": 80}]'"
  fi
  printf 'spec:\n  rules:\n'
  if [[ -n "$INGRESS_HOST" ]]; then
    printf '    - host: %s\n      http:\n' "$INGRESS_HOST"
  else
    printf '    - http:\n'
  fi
  cat <<'EOF'
        paths:
          - path: /
            pathType: Prefix
            backend:
              service:
                name: frontend
                port:
                  number: 8080
EOF
} | write_file "${R_OVERLAY}/ingress.yaml"
else
  if [[ -f "${R_OVERLAY}/ingress.yaml" ]]; then
    rm -f "${R_OVERLAY}/ingress.yaml"
    changed_files+=("${OVERLAY_REL}/ingress.yaml (removed)")
    info "removed    ${OVERLAY_REL}/ingress.yaml"
  fi
fi

# 6d. overlay kustomization.yaml
#     - images[].newName 의 ECR 레지스트리 호스트 갱신 (newTag 는 CI 가 관리)
#     - ENABLE_APP_INGRESS 에 따라 resources 의 ingress.yaml 추가/제거
kust="${R_OVERLAY}/kustomization.yaml"
[[ -f "$kust" ]] || die "overlay kustomization.yaml 이 없습니다: $kust"
kust_new=$(
  sed -E "s#^([[:space:]]*newName:[[:space:]]*).*(/[A-Za-z0-9._-]+)\$#\1${ECR_REGISTRY}\2#" "$kust" \
  | awk -v enable="$ENABLE_APP_INGRESS" '
      /^  - ingress\.yaml$/ { next }
      { print }
      /^  - secretproviderclass-db-bootstrap\.yaml$/ {
        if (enable == "true") print "  - ingress.yaml"
      }'
)
printf '%s\n' "$kust_new" | write_file "$kust"
unset kust_new

# 6e. Argo CD 가 읽을 저장소 좌표 (root Application / ApplicationSet / AppProject)
sed_file "${R_BOOTSTRAP}/root-application.yaml" \
  "s#^([[:space:]]*repoURL:[[:space:]]*).*\$#\1${GITOPS_REPO_URL}#" \
  "s#^([[:space:]]*targetRevision:[[:space:]]*).*\$#\1${GIT_TARGET_REVISION}#"
sed_file "${R_ARGOCD}/applicationset.yaml" \
  "s#^([[:space:]]*repoURL:[[:space:]]*).*\$#\1${GITOPS_REPO_URL}#" \
  "s#^([[:space:]]*targetRevision:[[:space:]]*).*\$#\1${GIT_TARGET_REVISION}#"
sed_file "${R_ARGOCD}/appproject.yaml" \
  "s#^([[:space:]]*)- ${SENTINEL}\$#\1- ${GITOPS_REPO_URL}#" \
  "s#^([[:space:]]*)- https://github\.com/.*\.git\$#\1- ${GITOPS_REPO_URL}#"

# 6f. Argo CD server 용 TargetGroupBinding (선택). kustomization 은 통째로 재생성한다.
tgb_file="${R_ARGOCD}/targetgroupbinding.yaml"
if [[ -n "$ARGOCD_TARGET_GROUP_ARN" ]]; then
  write_file "$tgb_file" <<EOF
# GENERATED FILE - do not edit manually.
# Rendered by scripts/bootstrap-eks.sh from ARGOCD_TARGET_GROUP_ARN.
# AWS Load Balancer Controller (elbv2.k8s.aws) 가 설치되어 있어야 동작한다.
apiVersion: elbv2.k8s.aws/v1beta1
kind: TargetGroupBinding
metadata:
  name: argocd-server
  namespace: argocd
spec:
  targetGroupARN: ${ARGOCD_TARGET_GROUP_ARN}
  targetType: ip
  serviceRef:
    name: argocd-server
    port: 80
EOF
  write_file "${R_ARGOCD}/kustomization.yaml" <<'EOF'
apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization
# root Application(bootstrap/root-application.yaml)이 이 경로를 동기화한다.
# sync wave 순서: AppProject(-20) -> platform controller(-5) -> ApplicationSet(0)
resources:
  - appproject.yaml
  - platform
  - applicationset.yaml
  - targetgroupbinding.yaml
EOF
else
  if [[ -f "$tgb_file" ]]; then
    rm -f "$tgb_file"
    changed_files+=("argocd/targetgroupbinding.yaml (removed)")
    info "removed    argocd/targetgroupbinding.yaml"
  fi
  write_file "${R_ARGOCD}/kustomization.yaml" <<'EOF'
apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization
# root Application(bootstrap/root-application.yaml)이 이 경로를 동기화한다.
# sync wave 순서: AppProject(-20) -> platform controller(-5) -> ApplicationSet(0)
resources:
  - appproject.yaml
  - platform
  - applicationset.yaml
EOF
fi

(( ${#changed_files[@]} )) || info "변경 없음 (이미 현재 Terraform state 와 일치)"

# ---------------------------------------------------------------------------
step "렌더링 결과 정적 검증" 7
# ---------------------------------------------------------------------------
scan_dirs=("${RENDER_ROOT}/k8s" "$R_ARGOCD" "$R_BOOTSTRAP")

# 7a. placeholder 가 남아 있으면 절대 적용하지 않는다.
if grep -rIn --exclude-dir=.git -F "$SENTINEL" "${scan_dirs[@]}" >/dev/null 2>&1; then
  grep -rIn --exclude-dir=.git -F "$SENTINEL" "${scan_dirs[@]}" >&2 || true
  die "렌더링되지 않은 placeholder(${SENTINEL})가 남아 있습니다."
fi
info "placeholder 없음"

# 7b. 현재 Terraform state 에 속하지 않는 계정 ID / RDS endpoint / 원시 secret 이름
stale=$(grep -rIn --exclude-dir=.git -E '[0-9]{12}|[a-z0-9.-]+\.rds\.amazonaws\.com|rds!db-' \
          "${scan_dirs[@]}" 2>/dev/null \
        | grep -vF "$TF_ACCOUNT_ID" \
        | grep -vF "$TF_RDS_ADDRESS" || true)
if [[ -n "$stale" ]]; then
  printf '%s\n' "$stale" >&2
  die "이전 환경의 계정 ID / RDS endpoint / secret 이름이 남아 있습니다."
fi
info "이전 환경 값 없음"

# 7c. Kustomize build
build_out=$(mktemp)
kustomize_build "$R_OVERLAY"   >"$build_out"  || die "kustomize build 실패: $R_OVERLAY"
info "kustomize build overlay   ok ($(grep -c '^kind:' "$build_out" || true) resources)"
kustomize_build "$R_ARGOCD"    >/dev/null     || die "kustomize build 실패: $R_ARGOCD"
info "kustomize build argocd    ok"
kustomize_build "$R_BOOTSTRAP" >/dev/null     || die "kustomize build 실패: $R_BOOTSTRAP"
info "kustomize build bootstrap ok"

# 7d. Terraform 값이 실제로 build 결과에 반영됐는지 확인
grep -qF "$TF_RDS_ADDRESS"        "$build_out" || die "build 결과에 RDS endpoint 가 없습니다."
grep -qF "$TF_RDS_APP_SECRET_ARN" "$build_out" || die "build 결과에 앱 secret ARN 이 없습니다."
grep -qF "$TF_RDS_SECRET_ARN"     "$build_out" || die "build 결과에 master secret ARN 이 없습니다."
grep -qF "$ECR_REGISTRY"          "$build_out" || die "build 결과에 ECR 레지스트리가 없습니다."

# master secret 은 db-bootstrap SecretProviderClass 에서만 나와야 한다.
# 앱 SPC 나 Deployment 로 새어 들어가면 최소 권한 분리가 깨진 것이다.
master_refs=$(awk -v arn="$TF_RDS_SECRET_ARN" '
  /^---$/ { doc=""; next }
  { doc=doc $0 ORS }
  index($0, arn) { print doc; doc="" }' "$build_out" \
  | grep -c 'name: bank-of-anthos-db-bootstrap-secrets' || true)
total_master=$(grep -cF "$TF_RDS_SECRET_ARN" "$build_out" || true)
[[ "$total_master" == "1" && "$master_refs" == "1" ]] \
  || die "RDS master secret ARN 이 db-bootstrap SecretProviderClass 밖에서도 참조됩니다
  (참조 ${total_master}건). 애플리케이션은 master secret 을 쓰면 안 됩니다."
info "master secret 참조: db-bootstrap SecretProviderClass 1곳만"

# 7e. ENABLE_APP_INGRESS=false 면 build 결과에 ALB 관련 리소스가 하나도 없어야 한다.
argocd_out=$(mktemp)
kustomize_build "$R_ARGOCD" >"$argocd_out"
if [[ "$ENABLE_APP_INGRESS" == true ]]; then
  grep -q '^kind: Ingress$' "$build_out" \
    || die "ENABLE_APP_INGRESS=true 인데 build 결과에 Ingress 가 없습니다."
  info "ALB 리소스     : Ingress 포함"
else
  ing=$(grep -c '^kind: Ingress$' "$build_out" || true)
  tgb=$( { grep -ch '^kind: TargetGroupBinding$' "$build_out" "$argocd_out" || true; } \
          | awk '{s+=$1} END {print s+0}')
  [[ "$ing" == "0" && "$tgb" == "0" ]] \
    || die "ENABLE_APP_INGRESS=false 인데 build 결과에 ALB 리소스가 있습니다
  (Ingress ${ing}개, TargetGroupBinding ${tgb}개)."
  info "ALB 리소스     : Ingress 0개 / TargetGroupBinding 0개 확인"
fi
rm -f "$argocd_out" "$build_out"
info "build 결과에 Terraform 값 반영 확인"

# ---------------------------------------------------------------------------
git_dirty_paths() { git -C "$GITOPS_DIR" status --porcelain -- k8s argocd bootstrap environments scripts; }

if [[ "$MODE" == dry-run ]]; then
  step "dry-run diff" 8
  changed=0
  for d in k8s argocd bootstrap; do
    if ! diff -ruN --exclude=.git "${GITOPS_DIR}/${d}" "${RENDER_ROOT}/${d}" >/dev/null 2>&1; then
      changed=1
      diff -ruN --exclude=.git "${GITOPS_DIR}/${d}" "${RENDER_ROOT}/${d}" || true
    fi
  done
  (( changed )) || info "저장소와 렌더링 결과가 동일합니다. 반영할 변경이 없습니다."
  log ''
  log "dry-run 완료. 저장소에 반영하려면:"
  log "  $0 --infra-dir ${INFRA_DIR} --environment ${ENV_NAME} --render"
  exit 0
fi

if [[ "$MODE" == render ]]; then
  step "저장소 반영 완료" 8
  if [[ -n "$(git_dirty_paths)" ]]; then
    git -C "$GITOPS_DIR" --no-pager diff --stat -- k8s argocd bootstrap || true
    log ''
    log "변경 내용을 검토한 뒤 커밋/푸시하세요 (이 스크립트는 commit/push 하지 않습니다):"
    log "  git -C ${GITOPS_DIR} add k8s argocd bootstrap"
    log "  git -C ${GITOPS_DIR} commit -m 'chore(gitops): render ${ENV_NAME}/aws from terraform output'"
    log "  git -C ${GITOPS_DIR} push"
    log ''
    log "푸시한 뒤 클러스터에 적용하려면:"
    log "  $0 --infra-dir ${INFRA_DIR} --environment ${ENV_NAME} --apply"
  else
    info "변경 없음. 이미 커밋된 상태와 동일합니다."
  fi
  exit 0
fi

# ---------------------------------------------------------------------------
step "Git desired state 확인" 8
# ---------------------------------------------------------------------------
# Argo CD 는 Git 에서 읽는다. 렌더링 결과가 커밋/푸시되지 않았다면 클러스터 상태와
# Git 의 desired state 가 달라지므로 진행을 막는다.
if [[ "$ALLOW_DIRTY" == true ]]; then
  warn "--allow-dirty: Git 상태 확인을 건너뜁니다. Argo CD 는 여전히 Git 내용을 동기화합니다."
else
  dirty=$(git_dirty_paths)
  if [[ -n "$dirty" ]]; then
    printf '%s\n' "$dirty" >&2
    die "렌더링 결과가 커밋되지 않았습니다. Argo CD 는 Git 을 읽으므로 먼저 커밋/푸시하세요.
  (의도적으로 무시하려면 --allow-dirty)"
  fi
  branch=$(git -C "$GITOPS_DIR" rev-parse --abbrev-ref HEAD)
  [[ "$branch" == "$GIT_TARGET_REVISION" ]] \
    || warn "현재 브랜치(${branch})와 Argo CD 가 동기화할 revision(${GIT_TARGET_REVISION})이 다릅니다."
  upstream=$(git -C "$GITOPS_DIR" rev-parse --abbrev-ref '@{u}' 2>/dev/null) \
    || die "현재 브랜치(${branch})에 upstream 이 없습니다. 먼저 push 하세요."
  git -C "$GITOPS_DIR" fetch --quiet || warn "git fetch 실패. 원격 비교를 건너뜁니다."
  ahead=$(git -C "$GITOPS_DIR" rev-list --count "${upstream}..HEAD")
  [[ "$ahead" == "0" ]] \
    || die "푸시되지 않은 커밋이 ${ahead}개 있습니다 (${branch} -> ${upstream}). 먼저 push 하세요."
  info "${branch} 는 ${upstream} 와 동기 상태"
fi

# ---------------------------------------------------------------------------
step "EKS 연결" 9
# ---------------------------------------------------------------------------
aws eks update-kubeconfig --name "$TF_CLUSTER_NAME" --region "$TF_REGION" >/dev/null \
  || die "kubeconfig 갱신 실패: cluster=${TF_CLUSTER_NAME} region=${TF_REGION}"
info "kubeconfig : $(kubectl config current-context)"
kubectl version -o json >/dev/null 2>&1 || die "클러스터 API 에 연결할 수 없습니다."
info "nodes      : $(kubectl get nodes --no-headers 2>/dev/null | wc -l)"

# Secrets Store CSI Driver 와 ALB Controller 는 설치 주체가 다르다.
#   - CSI driver  : 이 저장소의 argocd/platform (Argo CD 가 설치)
#   - ALB Controller: infra(Terraform, IAM + Pod Identity) 소유
if [[ "$ENABLE_APP_INGRESS" == true ]] && ! kubectl get crd ingressclassparams.elbv2.k8s.aws >/dev/null 2>&1; then
  warn "AWS Load Balancer Controller 가 보이지 않습니다.
    Ingress 가 ALB 를 만들지 못합니다. infra 의 modules/aws-load-balancer-controller 를 확인하세요."
fi
if [[ "$ENABLE_APP_INGRESS" != true ]]; then
  info "ALB 미사용 구성. 접근 방법:"
  dim  "  kubectl -n argocd port-forward svc/argocd-server 8080:80"
  dim  "  kubectl -n ${NAMESPACE} port-forward svc/frontend 8081:8080"
fi
if [[ -n "$ARGOCD_TARGET_GROUP_ARN" ]]; then
  kubectl get crd targetgroupbindings.elbv2.k8s.aws >/dev/null 2>&1 \
    || die "ARGOCD_TARGET_GROUP_ARN 을 쓰려면 AWS Load Balancer Controller 가 먼저 설치되어야 합니다."
  info "CRD ok     : targetgroupbindings"
fi

# ---------------------------------------------------------------------------
step "Argo CD bootstrap" 10
# ---------------------------------------------------------------------------
if [[ "$SKIP_ARGOCD_INSTALL" == true ]]; then
  info "Argo CD 설치 건너뜀 (--skip-argocd-install)"
else
  helm repo add argo https://argoproj.github.io/argo-helm --force-update >/dev/null
  helm repo update >/dev/null
  helm_args=(upgrade --install argocd argo/argo-cd
    --namespace argocd --create-namespace
    --version "$ARGOCD_CHART_VERSION"
    --atomic --timeout "${WAIT_TIMEOUT}s")
  values_file="${GITOPS_DIR}/bootstrap/argocd/values.yaml"
  [[ -f "$values_file" ]] && helm_args+=(--values "$values_file")
  helm "${helm_args[@]}" >/dev/null || die "Argo CD Helm 설치 실패"
  info "Argo CD 설치/업그레이드 완료 (chart ${ARGOCD_CHART_VERSION})"
fi

kubectl -n argocd rollout status deploy/argocd-server --timeout "${WAIT_TIMEOUT}s" >/dev/null \
  || die "argocd-server 가 준비되지 않았습니다."
for crd in applications.argoproj.io applicationsets.argoproj.io appprojects.argoproj.io; do
  kubectl get crd "$crd" >/dev/null 2>&1 || die "Argo CD CRD 가 없습니다: $crd"
done
info "Argo CD 준비 완료"

# private 저장소면 repository secret 이 필요하다.
# PAT 는 이 스크립트가 다루지 않는다 (scripts/register-repo-credentials.sh 참고).
if ! kubectl -n argocd get secret -l argocd.argoproj.io/secret-type=repository \
      --no-headers 2>/dev/null | grep -q .; then
  warn "Argo CD 에 등록된 repository secret 이 없습니다.
    private 저장소라면 먼저 실행하세요: ${GITOPS_DIR}/scripts/register-repo-credentials.sh"
fi

kustomize_build "${GITOPS_DIR}/bootstrap" | kubectl apply -f - >/dev/null \
  || die "root Application 적용 실패"
info "root Application 적용 완료 (이후는 Argo CD 가 Git 의 argocd/ 경로를 동기화한다)"

if [[ "$SKIP_WAIT" == true ]]; then
  log ''
  info "--skip-wait: sync/health 대기를 건너뜁니다."
  info "확인: kubectl -n argocd get applications"
  exit 0
fi

# ---------------------------------------------------------------------------
CURRENT_STEP='배포 확인'
printf '\n%s==> %s%s\n' "$C_GRN" "$CURRENT_STEP" "$C_OFF"
# ---------------------------------------------------------------------------
deadline=$(( SECONDS + WAIT_TIMEOUT ))
app_name="bank-app-aws-${ENV_NAME}"

info "Application ${app_name} 생성 대기..."
until kubectl -n argocd get application "$app_name" >/dev/null 2>&1; do
  (( SECONDS < deadline )) || die "Application ${app_name} 이 생성되지 않았습니다.
  확인: kubectl -n argocd get applicationset,applications"
  sleep 5
done

app_status() { kubectl -n argocd get application "$1" -o jsonpath="{.status.$2.status}" 2>/dev/null || true; }

info "sync / health 대기..."
until [[ "$(app_status "$app_name" sync)" == "Synced" && "$(app_status "$app_name" health)" == "Healthy" ]]; do
  if (( SECONDS >= deadline )); then
    kubectl -n argocd get applications \
      -o custom-columns=NAME:.metadata.name,SYNC:.status.sync.status,HEALTH:.status.health.status >&2
    die "Application ${app_name} 이 시간 내에 Synced/Healthy 가 되지 않았습니다."
  fi
  sleep 10
done

kubectl -n argocd get applications \
  -o custom-columns=NAME:.metadata.name,SYNC:.status.sync.status,HEALTH:.status.health.status
log ''
kubectl -n "$NAMESPACE" get deploy
log ''
printf '%s==> 완료%s\n' "$C_GRN" "$C_OFF"
info "Application ${app_name}: Synced / Healthy"
