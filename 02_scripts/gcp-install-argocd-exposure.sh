#!/usr/bin/env bash
# 목적: GKE의 Argo CD Service를 외부 Ingress로 노출한다.
# 입력: 현재 kubectl context가 boa-gke를 가리켜야 한다.
# 결과: argocd namespace의 GCP Argo CD Ingress가 생성된다.
set -Eeuo pipefail

SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
FILE="$SCRIPT_DIR/../01_bootstrap/argocd-exposure-gke.yaml"

command -v kubectl >/dev/null || { echo "ERROR: 필수 명령 없음: kubectl" >&2; exit 1; }

# 다른 클러스터에 GCP 리소스를 적용하지 않도록 현재 context를 확인한다.
CONTEXT=$(kubectl config current-context)
[[ "$CONTEXT" == *boa-gke* ]] || { echo "ERROR: GKE context가 아닙니다: $CONTEXT" >&2; exit 1; }

# GKE 전용 Argo CD 노출 리소스만 적용한다.
kubectl apply -f "$FILE"
kubectl -n argocd get ingress,service
echo "완료: GCP Argo CD 외부 노출 리소스가 적용되었습니다."
