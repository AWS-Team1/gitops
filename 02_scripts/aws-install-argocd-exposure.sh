#!/usr/bin/env bash
# 목적: EKS의 Argo CD Service를 Terraform이 만든 AWS Target Group에 연결한다.
# 입력: aws-render-runtime.sh로 갱신된 TargetGroupBinding manifest.
# 결과: argocd/argocd-server TargetGroupBinding이 생성된다.
set -Eeuo pipefail

SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
REPO_ROOT=$(cd -- "$SCRIPT_DIR/.." && pwd)
FILE="$REPO_ROOT/manual/eks/argocd-exposure/targetgroupbinding.yaml"

command -v kubectl >/dev/null || { echo "ERROR: 필수 명령 없음: kubectl" >&2; exit 1; }

# 다른 클러스터에 AWS 리소스를 적용하지 않도록 현재 context를 확인한다.
CONTEXT=$(kubectl config current-context)
[[ "$CONTEXT" == *boa-eks* ]] || { echo "ERROR: EKS context가 아닙니다: $CONTEXT" >&2; exit 1; }

# 렌더된 TargetGroupBinding 하나만 적용한다.
kubectl apply -f "$FILE"
kubectl -n argocd get targetgroupbinding argocd-server
echo "완료: AWS Argo CD TargetGroupBinding이 적용되었습니다."
