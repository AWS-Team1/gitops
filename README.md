# Bank of Anthos GitOps

EKS/GKE용 Bank of Anthos 매니페스트와 Argo CD App-of-Apps 구성을 관리합니다.
공통 애플리케이션 리소스는 Kustomize base에 두고 클라우드별 설정만 overlay에서 관리합니다.
GKE overlay는 컷오버 전 standby 구성이며 6개 Deployment를 `replicas: 0`으로 유지합니다.

현재 브랜치의 설치·검증 순서는
[`docs/EKS_GITOPS_CICD_RUNBOOK.md`](docs/EKS_GITOPS_CICD_RUNBOOK.md)를 따릅니다.
AWS/GCP 클러스터 동시 재생성·배포는
[`docs/CLUSTER_REBUILD_RUNBOOK.md`](docs/CLUSTER_REBUILD_RUNBOOK.md)를 따릅니다.
기존 `jiho-test-cd` 기준 AWS 값 교체·저장소 연결 상세는
[`docs/ARGOCD_EKS_RUNBOOK.md`](docs/ARGOCD_EKS_RUNBOOK.md)를 참고합니다.

## 구조

```text
01_bootstrap/
├── argocd-values.yaml
└── root-application-eks.yaml
02_scripts/
├── bootstrap-all.sh
├── bootstrap.sh
├── install-argocd.sh
├── prepare-database-secret.sh
├── prepare-jwt.sh
├── prepare-jwt-gcp.sh
├── render-aws-runtime.sh
├── verify-argocd.sh
├── teardown-cluster.sh
└── teardown-gke.sh
03_manifests/
├── base/                         # 공통 Deployment, Service, NetworkPolicy
│   ├── accounts/
│   ├── ledger/
│   └── frontend/
├── eks/                          # AWS 이미지, RDS, CSI, ALB overlay
│   ├── applications/
│   ├── shared/
│   ├── accounts/
│   ├── ledger/
│   └── frontend/
└── gke/                          # Artifact Registry, Cloud SQL, SecretSync, LB overlay
    ├── applications/
    ├── shared/
    ├── accounts/
    ├── ledger/
    └── frontend/
manual/eks/
├── *.yaml                    # 최초 서비스/HPA 수동 배포용 전체 YAML
├── argocd-exposure/           # Argo CD UI ALB 연결 수동 YAML
└── karpenter/                 # 수동 배포용 EC2NodeClass, NodePool
```

## 배포 흐름

```bash
# Terraform 적용과 render-aws-runtime.sh 실행 후, final-project-dev에서 실행
bash gitops/02_scripts/bootstrap.sh all
```

Terraform은 bootstrap 범위가 아니다. 중단 후에는 `prepare`, `apply-root`, `verify` 모드로
EKS 내부의 큰 단계만 다시 실행한다.

`render-aws-runtime.sh`는 `manual/eks`만 수정한다. Argo CD가 읽는
`03_manifests/eks/shared/secrets.yaml` 값은 확인 후 직접 수정·commit·push한다.

Root Application은 `applications/`를 읽고, child Application이 `shared`,
`accounts`, `ledger`, `frontend`를 배포합니다. 워크로드에 직접
`kubectl apply`를 실행하지 마세요. Argo CD가 유일한 리소스 소유자입니다.

## 검증

```bash
kubectl kustomize 03_manifests/eks
kubectl kustomize 03_manifests/gke
kubectl apply --dry-run=server -f manual/eks/argocd-exposure/targetgroupbinding.yaml
kubectl kustomize 03_manifests/eks/applications
kubectl kustomize 03_manifests/gke/applications
kubectl -n argocd get applications
```

