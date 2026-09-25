#!/usr/bin/env bash
# 목적: EKS 삭제 전에 앱 Ingress와 해당 ALB만 정리한다.
# 입력: --confirm, 대상 계정/리전/클러스터 환경변수(선택).
# 결과: Argo CD 재동기화가 멈추고 앱 Ingress와 해당 ALB가 제거된다.
# Argo CD 재생성을 멈추고 앱 Ingress와 그 Ingress가 만든 ALB만 정리한다.
# EKS와 Terraform 소유 인프라는 건드리지 않는다. --confirm이 있어야 실행된다.
set -euo pipefail
export AWS_PAGER=""

# 환경변수로 덮어쓸 수 있는 기본값
REGION=${REGION:-ap-northeast-2}
EXPECTED_ACCOUNT=${EXPECTED_ACCOUNT:-769413326616}   # 팀 계정 가드
CLUSTER=${CLUSTER:-boa-eks}
ARGOCD_NAMESPACE=${ARGOCD_NAMESPACE:-argocd}
APP_NAMESPACE=${APP_NAMESPACE:-bank-of-anthos}
APP_INGRESS=${APP_INGRESS:-boa-ingress}
POLL_SECONDS=${POLL_SECONDS:-10}          # ALB 삭제 확인 폴링 간격
TIMEOUT_SECONDS=${TIMEOUT_SECONDS:-900}   # 각 대기 단계 제한 시간

die() { echo "ERROR: $*" >&2; exit 1; }
info() { echo "INFO: $*"; }

# --confirm 없으면 실행 거부 (안전장치)
case "${1:-}" in
  --confirm) ;;
  -h|--help)
    echo "Usage: $0 --confirm"
    echo "Stops Argo CD reconciliation and waits for the app Ingress/ALB cleanup."
    exit 0
    ;;
  "") die "삭제하려면 --confirm이 필요합니다" ;;
  *) die "알 수 없는 옵션: $1" ;;
esac

for tool in aws kubectl; do
  command -v "$tool" >/dev/null || die "필수 명령 없음: $tool"
done

# 계정 + kubectl 대상 클러스터가 맞는지 가드 (엉뚱한 데 실행 방지)
ACCOUNT=$(aws sts get-caller-identity --query Account --output text)
[[ "$ACCOUNT" == "$EXPECTED_ACCOUNT" ]] || die "대상 AWS 계정 불일치: $ACCOUNT"

EXPECTED_ENDPOINT=$(aws eks describe-cluster \
  --region "$REGION" --name "$CLUSTER" \
  --query cluster.endpoint --output text)
CURRENT_ENDPOINT=$(kubectl config view --minify \
  -o jsonpath='{.clusters[0].cluster.server}')
[[ "$CURRENT_ENDPOINT" == "$EXPECTED_ENDPOINT" ]] || die "kubectl 대상 클러스터 불일치"

# 이 클러스터가 속한 VPC (앱 ALB 조회 범위 한정용)
VPC_ID=$(aws eks describe-cluster \
  --region "$REGION" --name "$CLUSTER" \
  --query cluster.resourcesVpcConfig.vpcId --output text)

# 해당 Ingress의 status hostname과 일치하는 ALB만 조회한다.
app_alb() {
  [[ -n "$APP_ALB_DNS" ]] || return 0
  aws elbv2 describe-load-balancers --region "$REGION" \
    --query "LoadBalancers[?VpcId=='$VPC_ID' && DNSName=='$APP_ALB_DNS'].LoadBalancerArn" \
    --output text
}

# 정리 대상 현황 먼저 출력 (무엇을 건드리게 되는지 확인용)
echo "AWS account : $ACCOUNT"
echo "Region      : $REGION"
echo "Cluster     : $CLUSTER"
echo "VPC         : $VPC_ID"
echo "App Ingress:"
kubectl -n "$APP_NAMESPACE" get ingress "$APP_INGRESS" --ignore-not-found
APP_ALB_DNS=$(kubectl -n "$APP_NAMESPACE" get ingress "$APP_INGRESS" \
  -o jsonpath='{.status.loadBalancer.ingress[0].hostname}' 2>/dev/null || true)
echo "App ALB DNS : ${APP_ALB_DNS:-none}"

# 1) application-controller를 replicas=0으로 → 삭제한 Ingress를 자동 재생성 못 하게 막음
CONTROLLER=$(kubectl -n "$ARGOCD_NAMESPACE" get statefulset \
  -l app.kubernetes.io/name=argocd-application-controller \
  -o jsonpath='{.items[0].metadata.name}')
[[ -n "$CONTROLLER" ]] || die "Argo CD application-controller를 찾지 못함"

info "Argo CD reconciliation 중지"
kubectl -n "$ARGOCD_NAMESPACE" scale statefulset "$CONTROLLER" --replicas=0
kubectl -n "$ARGOCD_NAMESPACE" rollout status statefulset "$CONTROLLER" \
  --timeout="${TIMEOUT_SECONDS}s"

# 2) 앱 Ingress만 삭제 → LBC가 이 앱의 ALB 회수를 시작
info "$APP_NAMESPACE/$APP_INGRESS Ingress 삭제"
kubectl -n "$APP_NAMESPACE" delete ingress "$APP_INGRESS" \
  --ignore-not-found --wait=false
kubectl -n "$APP_NAMESPACE" wait --for=delete "ingress/$APP_INGRESS" \
  --timeout="${TIMEOUT_SECONDS}s" 2>/dev/null || \
  [[ -z $(kubectl -n "$APP_NAMESPACE" get ingress "$APP_INGRESS" \
    -o name --ignore-not-found) ]] || die "앱 Ingress 삭제 시간 초과"

# 3) 앱 Ingress가 만든 ALB만 사라질 때까지 폴링
DEADLINE=$(( $(date +%s) + TIMEOUT_SECONDS ))
while :; do
  APP_ALB=$(app_alb) || die "앱 ALB 조회 실패"
  [[ -n "$APP_ALB" && "$APP_ALB" != "None" ]] || break
  echo "앱 ALB 삭제 대기 중: $APP_ALB"
  (( $(date +%s) < DEADLINE )) || die "앱 ALB 삭제 시간 초과"
  sleep "$POLL_SECONDS"
done

info "앱 Ingress/ALB 정리 완료; EKS 및 Terraform 소유 인프라는 유지"
