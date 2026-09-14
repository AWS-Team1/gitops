# Bank of Anthos GitOps

EKS용 Bank of Anthos 매니페스트와 Argo CD App-of-Apps 구성을 관리합니다.
AWS 인프라(VPC, EKS, RDS, IAM, ECR, AWS Load Balancer Controller)는 Terraform이 소유합니다.

## 구조

```text
01_bootstrap/
├── argocd-values.yaml
└── root-application-eks.yaml
02_scripts/
├── bootstrap.sh
├── install-argocd.sh
├── prepare-jwt.sh
├── register-repo.sh
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
```

## 배포 흐름

```bash
# AWS Secret, Pod Identity, private DNS 준비 후 실행한다.
# JWT → Argo CD → 저장소 인증 → Root Application 순서로 진행된다.
bash 02_scripts/bootstrap.sh
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
