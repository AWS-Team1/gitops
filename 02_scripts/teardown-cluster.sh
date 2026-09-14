#!/usr/bin/env bash
# Terraform destroy 전에 Argo CD의 자동 재생성을 멈추고 Ingress/ALB를 정상 정리한다.
# ALB가 남은 채 VPC를 destroy하면 ENI가 물려 실패하므로, ALB가 사라진 걸 확인하고 끝낸다.
# 실제 리소스를 지우므로 반드시 --confirm이 있어야 실행된다. Terraform은 실행하지 않고 안내만 한다.
set -euo pipefail
export AWS_PAGER=""

# 환경변수로 덮어쓸 수 있는 기본값
REGION=${REGION:-ap-northeast-2}
EXPECTED_ACCOUNT=${EXPECTED_ACCOUNT:-769413326616}   # 팀 계정 가드
CLUSTER=${CLUSTER:-boa-eks}
ARGOCD_NAMESPACE=${ARGOCD_NAMESPACE:-argocd}
APP_NAMESPACE=${APP_NAMESPACE:-bank-of-anthos}
POLL_SECONDS=${POLL_SECONDS:-10}          # ALB 삭제 확인 폴링 간격
TIMEOUT_SECONDS=${TIMEOUT_SECONDS:-900}   # 각 대기 단계 제한 시간

die() { echo "ERROR: $*" >&2; exit 1; }
info() { echo "INFO: $*"; }

# --confirm 없으면 실행 거부 (안전장치)
case "${1:-}" in
  --confirm) ;;
  -h|--help)
    echo "Usage: teardown-cluster.sh --confirm"
    echo "Stops Argo CD reconciliation and waits for Ingress/ALB cleanup."
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

# 이 클러스터가 속한 VPC (아래 ALB 조회 범위 한정용)
VPC_ID=$(aws eks describe-cluster \
  --region "$REGION" --name "$CLUSTER" \
  --query cluster.resourcesVpcConfig.vpcId --output text)

# 이 클러스터(LBC)가 만든 ALB만 골라낸다.
# VPC 안 application LB 중 elbv2.k8s.aws/cluster=<cluster> 태그가 붙은 것만 반환.
cluster_albs() {
  local arn arns tags
  if ! arns=$(aws elbv2 describe-load-balancers --region "$REGION" \
    --query "LoadBalancers[?VpcId=='$VPC_ID' && Type=='application'].LoadBalancerArn" \
    --output text); then
    return 1
  fi
  while IFS= read -r arn; do
    [[ -n "$arn" ]] || continue
    if ! tags=$(aws elbv2 describe-tags --region "$REGION" --resource-arns "$arn" \
      --query 'TagDescriptions[0].Tags[].[Key,Value]' --output text); then
      return 1
    fi
    if grep -Fqx $'elbv2.k8s.aws/cluster\t'"$CLUSTER" <<< "$tags"; then
      echo "$arn"
    fi
  done < <(tr '\t' '\n' <<< "$arns")
  return 0
}

# 정리 대상 현황 먼저 출력 (무엇을 건드리게 되는지 확인용)
echo "AWS account : $ACCOUNT"
echo "Region      : $REGION"
echo "Cluster     : $CLUSTER"
echo "VPC         : $VPC_ID"
echo "Ingresses:"
kubectl get ingress -A || true
echo "Cluster ALBs:"
ALBS=$(cluster_albs) || die "ALB 조회 실패"
[[ -z "$ALBS" ]] || sed 's/^/  /' <<< "$ALBS"

# 1) application-controller를 replicas=0으로 → 삭제한 Ingress를 자동 재생성 못 하게 막음
CONTROLLER=$(kubectl -n "$ARGOCD_NAMESPACE" get statefulset \
  -l app.kubernetes.io/name=argocd-application-controller \
  -o jsonpath='{.items[0].metadata.name}')
[[ -n "$CONTROLLER" ]] || die "Argo CD application-controller를 찾지 못함"

info "Argo CD reconciliation 중지"
kubectl -n "$ARGOCD_NAMESPACE" scale statefulset "$CONTROLLER" --replicas=0
kubectl -n "$ARGOCD_NAMESPACE" rollout status statefulset "$CONTROLLER" \
  --timeout="${TIMEOUT_SECONDS}s"

# 2) 앱/argocd 네임스페이스의 Ingress 삭제 → LBC가 ALB 회수를 시작
for namespace in "$APP_NAMESPACE" "$ARGOCD_NAMESPACE"; do
  info "$namespace Ingress 삭제"
  kubectl -n "$namespace" delete ingress --all --ignore-not-found --wait=false
  kubectl -n "$namespace" wait --for=delete ingress --all \
    --timeout="${TIMEOUT_SECONDS}s" 2>/dev/null || \
    [[ -z $(kubectl -n "$namespace" get ingress -o name) ]] || \
    die "$namespace Ingress 삭제 시간 초과"
done

# 3) 이 클러스터 태그 ALB가 실제로 다 사라질 때까지 폴링 (남으면 VPC destroy가 막힘)
DEADLINE=$(( $(date +%s) + TIMEOUT_SECONDS ))
while :; do
  ALBS=$(cluster_albs) || die "ALB 조회 실패"
  [[ -n "$ALBS" ]] || break
  echo "ALB 삭제 대기 중:"
  sed 's/^/  /' <<< "$ALBS"
  (( $(date +%s) < DEADLINE )) || die "ALB 삭제 시간 초과; Terraform destroy를 실행하지 마세요"
  sleep "$POLL_SECONDS"
done

info "Ingress와 cluster-tagged ALB 정리 완료"
# Terraform destroy는 자동 실행하지 않고 안내만 (별도 infra 저장소에서 검토 후 수동 실행)
echo "다음 단계는 infra 저장소에서 별도로 검토 후 실행하세요:"
echo "  terraform destroy"
