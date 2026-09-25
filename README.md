# Bank of Anthos GitOps

EKS/GKE의 Bank of Anthos manifest와 Argo CD App-of-Apps 구성을 관리합니다.

설치·설정·검증은 한 스크립트에 묶지 않습니다. 각 스크립트는 한 가지 작업만 하며,
실행 순서와 결과는 [`docs/RUNBOOK.md`](docs/RUNBOOK.md)에 정리되어 있습니다.

## 디렉터리

```text
01_bootstrap/   Argo CD values, Root Application, GCP Argo CD 노출 manifest
02_scripts/     한 가지 작업만 수행하는 운영 스크립트
03_manifests/   EKS/GKE App-of-Apps 및 workload manifest
manual/eks/     AWS 초기 설정용 manifest
docs/           실행 런북과 보조 문서
```

Root Application은 `03_manifests/<platform>/applications`를 읽고 `shared`,
`accounts`, `ledger`, `frontend` Application을 배포합니다. workload를 별도로
`kubectl apply`하지 않습니다.

## 정적 검증

```bash
for file in 02_scripts/*.sh; do bash -n "$file"; done
kubectl kustomize 03_manifests/eks/applications
kubectl kustomize 03_manifests/gke/applications
```
