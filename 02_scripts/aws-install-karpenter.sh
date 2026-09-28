#!/usr/bin/env bash
# 목적: EKS에 Karpenter Controller와 노드 정책을 설치한다.
# 입력: CLUSTER 환경변수(선택), 현재 kubectl context가 boa-eks여야 한다.
# 결과: Karpenter Deployment, EC2NodeClass, NodePool이 Ready 상태가 된다.
set -Eeuo pipefail

CLUSTER=${CLUSTER:-boa-eks}
SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
REPO_ROOT=$(cd -- "$SCRIPT_DIR/.." && pwd)

for tool in kubectl helm; do
  command -v "$tool" >/dev/null || { echo "ERROR: 필수 명령 없음: $tool" >&2; exit 1; }
done

# 다른 클러스터에 설치하지 않도록 context를 확인한다.
CONTEXT=$(kubectl config current-context)
[[ "$CONTEXT" == *boa-eks* ]] || { echo "ERROR: EKS context가 아닙니다: $CONTEXT" >&2; exit 1; }

# 검증된 버전의 Karpenter Controller를 설치한다.
helm upgrade --install karpenter \
  oci://public.ecr.aws/karpenter/karpenter \
  --version 1.14.1 -n karpenter --create-namespace \
  --set settings.clusterName="$CLUSTER" \
  --set serviceAccount.create=true \
  --set serviceAccount.name=karpenter \
  --set replicas=2 --wait --timeout 10m

# 팀 표준 EC2NodeClass와 NodePool을 적용한다.
kubectl apply -f "$REPO_ROOT/manual/eks/karpenter/ec2nodeclass.yaml"
kubectl wait --for=condition=Ready ec2nodeclass/default --timeout=5m
kubectl apply -f "$REPO_ROOT/manual/eks/karpenter/nodepool.yaml"
kubectl wait --for=condition=Ready nodepool/default --timeout=5m

echo "완료: EKS Karpenter와 노드 정책이 준비되었습니다."
