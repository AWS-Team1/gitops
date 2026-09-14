# Bank of Anthos GitOps

EKS용 Bank of Anthos 매니페스트와 Argo CD App-of-Apps 구성을 관리합니다.
AWS 인프라(VPC, EKS, RDS, IAM, ECR, AWS Load Balancer Controller)는 Terraform이 소유합니다.

## 구조

```text
01_bootstrap/
└── root-application-eks.yaml
02_scripts/
├── bootstrap.sh
├── install-argocd.sh
├── prepare-jwt.sh
├── register-repo.sh
└── teardown-cluster.sh
03_manifests/
└── eks/
    ├── kustomization.yaml       # 수동 워크로드 전체 배포
    ├── argocd/                  # Argo CD 설치
    ├── applications/            # AppProject + child Applications
    ├── shared/                  # Namespace, SA, secrets, DB bootstrap
    ├── accounts/                # userservice, contacts
    ├── ledger/                  # balancereader, ledgerwriter, transactionhistory
    └── frontend/                # frontend, ALB Ingress
```

## 배포 흐름

```bash
# 1. Terraform 배포 완료 후 워크로드 수동 적용
kubectl apply -k 03_manifests/eks

# 2. Argo CD 설치
kubectl apply -k 03_manifests/eks/argocd

# 3. 저장소 자격 증명 등록 후 App-of-Apps 시작
bash 02_scripts/register-repo.sh
kubectl apply -f 01_bootstrap/root-application-eks.yaml
```

Root Application은 `applications/`를 읽고, child Application은 수동 배포와 동일한
`shared`, `accounts`, `ledger`, `frontend` 경로를 인계합니다.

## 검증

```bash
kubectl kustomize 03_manifests/eks
kubectl kustomize 03_manifests/eks/argocd
kubectl kustomize 03_manifests/eks/applications
```
