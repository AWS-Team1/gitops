# Bank of Anthos GitOps

EKS용 Bank of Anthos 매니페스트와 Argo CD App-of-Apps 구성을 관리합니다.
AWS 인프라(VPC, EKS, RDS, IAM, ECR, AWS Load Balancer Controller)는 Terraform이 소유합니다.

재현 가능한 전체 설치 절차와 `HARD-CODED` 교체 목록은
[`docs/ARGOCD_EKS_RUNBOOK.md`](docs/ARGOCD_EKS_RUNBOOK.md)를 따릅니다.
Terraform 적용을 제외한 앱 수동 시험 → Argo CD 인수 → Karpenter/HPA 검증 및 삭제는
[`docs/EKS_APP_ARGO_KARPENTER_HPA_RUNBOOK.md`](docs/EKS_APP_ARGO_KARPENTER_HPA_RUNBOOK.md)를 따릅니다.

## 구조

```text
01_bootstrap/
├── argocd-values.yaml
└── root-application-eks.yaml
02_scripts/
├── bootstrap.sh
├── install-argocd.sh
├── prepare-database-secret.sh
├── prepare-jwt.sh
├── render-aws-runtime.sh
├── verify-argocd.sh
└── teardown-cluster.sh
03_manifests/
└── eks/
    ├── kustomization.yaml       # 전체 리소스 렌더링/검증용
    ├── argocd-exposure/         # ops ALB TargetGroupBinding
    ├── applications/            # AppProject + child Applications
    ├── shared/                  # Namespace, SA, secrets, DB bootstrap
    ├── accounts/                # userservice, contacts
    ├── ledger/                  # balancereader, ledgerwriter, transactionhistory
    └── frontend/                # frontend, ALB Ingress
manual/
└── karpenter/                 # 수동 배포용 EC2NodeClass, NodePool
```

## 배포 흐름

```bash
# 1. Secret 값, Argo CD, UI 노출 준비
bash 02_scripts/bootstrap.sh prepare

# 2. 런북대로 UI에서 저장소 연결 후 Root 적용
bash 02_scripts/bootstrap.sh apply-root
```

Root Application은 `applications/`를 읽고, child Application이 `shared`,
`accounts`, `ledger`, `frontend`를 배포합니다. 워크로드에 직접
`kubectl apply`를 실행하지 마세요. Argo CD가 유일한 리소스 소유자입니다.

## 검증

```bash
kubectl kustomize 03_manifests/eks
kubectl kustomize 03_manifests/eks/argocd-exposure
kubectl kustomize 03_manifests/eks/applications
kubectl -n argocd get applications
```
