#!/usr/bin/env bash
# 목적: EKS에 Metrics Server를 설치하거나 기존 설치를 갱신한다.
# 입력: 현재 kubectl context가 boa-eks를 가리켜야 한다.
# 결과: v1beta1.metrics.k8s.io APIService가 Available 상태가 된다.
set -Eeuo pipefail

for tool in kubectl helm; do
  command -v "$tool" >/dev/null || { echo "ERROR: 필수 명령 없음: $tool" >&2; exit 1; }
done

# 다른 클러스터에 설치하지 않도록 context를 확인한다.
CONTEXT=$(kubectl config current-context)
[[ "$CONTEXT" == *boa-eks* ]] || { echo "ERROR: EKS context가 아닙니다: $CONTEXT" >&2; exit 1; }

# 공식 Helm 저장소에서 Metrics Server를 설치한다.
helm repo add metrics-server https://kubernetes-sigs.github.io/metrics-server/ --force-update
helm upgrade --install metrics-server metrics-server/metrics-server \
  -n kube-system --wait --timeout 10m

# Metrics API가 실제로 요청을 받을 준비가 됐는지 확인한다.
kubectl wait --for=condition=Available apiservice/v1beta1.metrics.k8s.io --timeout=5m
echo "완료: EKS Metrics Server가 준비되었습니다."
