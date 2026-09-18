#!/usr/bin/env bash
# Terraform 적용과 runtime 렌더가 끝난 뒤 EKS 내부의 최초 배포만 순서대로 수행한다.
set -Eeuo pipefail

SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
REPO_ROOT=$(cd -- "$SCRIPT_DIR/.." && pwd)
REGION=ap-northeast-2
CLUSTER=boa-eks
EXPECTED_ACCOUNT=769413326616
MODE=${1:-help}

usage() {
  cat <<EOF
Usage: $0 [prepare|apply-root|verify|all]

  prepare     JWT, Metrics Server, manual YAML, Argo CD, Karpenter 설치
  apply-root  UI 저장소 연결 뒤 Root Application 적용 및 전체 검증
  verify      Argo CD, 앱, HPA, Karpenter 상태 재검증
  all         prepare + UI 연결 대기 + apply-root
EOF
}

die() { echo "ERROR: $*" >&2; exit 1; }

require() {
  local tool
  for tool in "$@"; do
    command -v "$tool" >/dev/null || die "필수 명령 없음: $tool"
  done
}

check_account() {
  local account
  account=$(aws sts get-caller-identity --query Account --output text)
  [[ "$account" == "$EXPECTED_ACCOUNT" ]] || die "대상 AWS 계정 불일치: $account"
}

verify_frontend() {
  local attempt address=""
  for attempt in {1..60}; do
    address=$(kubectl -n bank-of-anthos get ingress boa-ingress \
      -o jsonpath='{.status.loadBalancer.ingress[0].hostname}' 2>/dev/null || true)
    [[ -n "$address" ]] && break
    sleep 10
  done
  [[ -n "$address" ]] || die "애플리케이션 ALB 주소가 10분 안에 생성되지 않았습니다."
  curl --fail --retry 12 --retry-delay 10 "http://$address/" >/dev/null
}

prepare_cluster() {
  require aws kubectl helm openssl curl
  check_account

  # 1. Terraform이 만든 EKS에 연결하고 기존 Argo CD 관리 여부를 확인한다.
  aws eks update-kubeconfig --name "$CLUSTER" --region "$REGION"
  kubectl get nodes -o wide
  ! kubectl -n argocd get applications --no-headers 2>/dev/null | grep -q . ||
    die "Argo CD가 이미 앱을 관리합니다. prepare 대신 verify를 실행하세요."

  # 2. 애플리케이션이 사용할 JWT 키를 Secrets Manager에 준비한다.
  bash "$SCRIPT_DIR/prepare-jwt.sh"

  # 3. HPA가 CPU 지표를 읽도록 Metrics Server가 없을 때만 설치한다.
  if ! kubectl get apiservice v1beta1.metrics.k8s.io >/dev/null 2>&1; then
    helm repo add metrics-server https://kubernetes-sigs.github.io/metrics-server/ --force-update
    helm upgrade --install metrics-server metrics-server/metrics-server \
      -n kube-system --wait --timeout 10m
  fi

  # 4. 최초 manual YAML을 적용하고 DB bootstrap과 앱 6개가 준비될 때까지 기다린다.
  kubectl kustomize "$REPO_ROOT/manual/eks" >/dev/null
  kubectl apply -f "$REPO_ROOT/manual/eks/namespace.yaml"
  kubectl apply --dry-run=server -k "$REPO_ROOT/manual/eks"
  kubectl apply -k "$REPO_ROOT/manual/eks"
  kubectl -n bank-of-anthos rollout status deployment/bank-of-anthos-secret-sync --timeout=5m
  kubectl -n bank-of-anthos wait --for=condition=complete job/db-bootstrap --timeout=10m

  local app
  for app in userservice contacts balancereader ledgerwriter transactionhistory frontend; do
    kubectl -n bank-of-anthos rollout status "deployment/$app" --timeout=10m
  done

  # 5. Argo CD를 설치하고 Terraform이 만든 UI Target Group에 연결한다.
  bash "$SCRIPT_DIR/install-argocd.sh"
  kubectl apply -f "$REPO_ROOT/manual/eks/argocd-exposure/targetgroupbinding.yaml"

  # 6. Karpenter Controller와 노드 생성 정책을 설치한다.
  helm upgrade --install karpenter \
    oci://public.ecr.aws/karpenter/karpenter \
    --version 1.14.1 -n karpenter --create-namespace \
    --set settings.clusterName="$CLUSTER" \
    --set serviceAccount.create=true \
    --set serviceAccount.name=karpenter \
    --set replicas=2 --wait --timeout 10m
  kubectl apply -f "$REPO_ROOT/manual/eks/karpenter/ec2nodeclass.yaml"
  kubectl wait --for=condition=Ready ec2nodeclass/default --timeout=5m
  kubectl apply -f "$REPO_ROOT/manual/eks/karpenter/nodepool.yaml"
  kubectl wait --for=condition=Ready nodepool/default --timeout=5m

  # 7. 앱 ALB가 실제 HTTP 요청에 응답하는지 확인한다.
  verify_frontend
  echo "준비 완료: https://argocd.bespinglobal.site 에서 저장소를 연결하세요."
}

verify_cluster() {
  require kubectl curl

  # Argo CD가 Root 1개와 Child 4개를 모두 동기화했는지 확인한다.
  bash "$SCRIPT_DIR/verify-argocd.sh"

  # HPA 6개가 실제 CPU metrics를 받고 있는지 확인한다.
  local hpa_count
  hpa_count=$(kubectl -n bank-of-anthos get hpa --no-headers | wc -l)
  [[ "$hpa_count" -eq 6 ]] || die "HPA가 6개가 아닙니다: $hpa_count"
  ! kubectl -n bank-of-anthos get hpa --no-headers | grep -q '<unknown>' ||
    die "HPA metrics가 아직 준비되지 않았습니다."
  kubectl -n bank-of-anthos get hpa -o wide

  # Karpenter Controller와 노드 정책이 Ready인지 확인한다.
  kubectl -n karpenter rollout status deployment/karpenter --timeout=10m
  kubectl wait --for=condition=Ready ec2nodeclass/default --timeout=5m
  kubectl wait --for=condition=Ready nodepool/default --timeout=5m
  kubectl get ec2nodeclass,nodepool,nodeclaim

  verify_frontend
  echo "전체 검증 성공"
}

apply_root() {
  local repo_count app_count attempt
  repo_count=$(kubectl -n argocd get secrets \
    -l argocd.argoproj.io/secret-type=repository --no-headers 2>/dev/null | wc -l)
  [[ "$repo_count" -ge 1 ]] || die "Argo CD 저장소 Credential이 없습니다. UI 연결을 먼저 완료하세요."

  # UI 저장소 연결 뒤 Root Application을 적용하고 Child 4개가 생길 때까지 기다린다.
  kubectl apply -f "$REPO_ROOT/01_bootstrap/root-application-eks.yaml"
  app_count=0
  for attempt in {1..90}; do
    app_count=$(kubectl -n argocd get applications --no-headers 2>/dev/null | wc -l)
    [[ "$app_count" -eq 5 ]] && break
    sleep 10
  done
  [[ "$app_count" -eq 5 ]] || die "Argo CD Application 5개가 15분 안에 생성되지 않았습니다."
  kubectl -n argocd wait applications --all \
    --for=jsonpath='{.status.sync.status}'=Synced --timeout=15m
  kubectl -n argocd wait applications --all \
    --for=jsonpath='{.status.health.status}'=Healthy --timeout=15m
  verify_cluster
}

case "$MODE" in
  prepare) prepare_cluster ;;
  apply-root) apply_root ;;
  verify) verify_cluster ;;
  all)
    prepare_cluster
    [[ -t 0 ]] || die "UI 저장소 연결이 필요하므로 대화형 터미널에서 실행하세요."
    echo "03_manifests의 RDS ARN/targetRevision을 원격 GitOps 브랜치에 push하세요."
    read -r -p "Argo CD UI 저장소 연결도 Successful이면 Enter를 누르세요: "
    apply_root
    ;;
  help|-h|--help) usage ;;
  *) usage >&2; exit 2 ;;
esac
