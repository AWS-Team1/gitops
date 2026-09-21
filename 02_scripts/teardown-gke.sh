#!/usr/bin/env bash
# GKE 삭제 전에 Kubernetes 컨트롤러가 만든 외부 LB만 정리한다.
set -Eeuo pipefail

ARGOCD_NAMESPACE=argocd
APP_NAMESPACE=bank-of-anthos
TIMEOUT=${TIMEOUT:-15m}

die() { echo "ERROR: $*" >&2; exit 1; }

[[ ${1:-} == --confirm ]] || die "Usage: $0 --confirm"
command -v kubectl >/dev/null || die "필수 명령 없음: kubectl"

CONTEXT=$(kubectl config current-context)
[[ "$CONTEXT" == *boa-gke* ]] || die "kubectl 대상이 boa-gke가 아닙니다: $CONTEXT"

CONTROLLER=$(kubectl -n "$ARGOCD_NAMESPACE" get statefulset \
  -l app.kubernetes.io/name=argocd-application-controller \
  -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || true)
if [[ -n "$CONTROLLER" ]]; then
  kubectl -n "$ARGOCD_NAMESPACE" scale statefulset "$CONTROLLER" --replicas=0
  kubectl -n "$ARGOCD_NAMESPACE" rollout status statefulset "$CONTROLLER" --timeout="$TIMEOUT"
fi

# 삭제 완료까지 기다리면 GKE 컨트롤러의 forwarding rule/backend 정리도 끝난다.
kubectl -n "$APP_NAMESPACE" delete service frontend --ignore-not-found --wait --timeout="$TIMEOUT"
kubectl -n "$ARGOCD_NAMESPACE" delete ingress argocd-gcp --ignore-not-found --wait --timeout="$TIMEOUT"
kubectl -n "$ARGOCD_NAMESPACE" delete managedcertificate argocd-gcp --ignore-not-found --wait --timeout="$TIMEOUT"
kubectl -n "$ARGOCD_NAMESPACE" delete frontendconfig argocd-gcp --ignore-not-found --wait --timeout="$TIMEOUT"
kubectl -n "$ARGOCD_NAMESPACE" delete backendconfig argocd-server --ignore-not-found --wait --timeout="$TIMEOUT"

echo "GKE 컨트롤러 소유 LB 정리 완료. gcp-ops의 고정 IP와 DNS는 유지됩니다."
