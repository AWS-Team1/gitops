# Bank of Anthos GitOps

EKS용 Bank of Anthos 매니페스트와 Argo CD App-of-Apps 구성을 관리합니다.
AWS 인프라(VPC, EKS, RDS, IAM, ECR, AWS Load Balancer Controller)는 Terraform이 소유합니다.

현재 브랜치의 설치·검증·삭제 순서는
[`docs/EKS_APP_ARGO_KARPENTER_HPA_RUNBOOK.md`](docs/EKS_APP_ARGO_KARPENTER_HPA_RUNBOOK.md)를 따릅니다.
기존 `jiho-test-cd` 기준 AWS 값 교체·저장소 연결 상세는
[`docs/ARGOCD_EKS_RUNBOOK.md`](docs/ARGOCD_EKS_RUNBOOK.md)를 참고합니다.

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
    ├── shared/                  # Namespace, SA, secrets, DB bootstrap, HPA
    ├── accounts/                # userservice, contacts
    ├── ledger/                  # balancereader, ledgerwriter, transactionhistory
    └── frontend/                # frontend, ALB Ingress
manual/eks/
├── *.yaml                    # 최초 서비스/HPA 수동 배포용 전체 YAML
├── argocd-exposure/           # Argo CD UI ALB 연결 수동 YAML
└── karpenter/                 # 수동 배포용 EC2NodeClass, NodePool
```

## 배포 흐름

```bash
# 1. DB 비밀번호 파일 생성 후 Infra가 Secrets Manager Version 생성
for name in app accounts ledger; do
  SECRET_NAME="/boa/database/$name" bash 02_scripts/prepare-database-secret.sh
done
terraform -chdir=../Infra/aws-db-bootstrap apply

# 2. Terraform output으로 manual YAML만 갱신
bash 02_scripts/render-aws-runtime.sh --infra-root "$(cd ../Infra && pwd)"

# 3. 나머지 Secret과 서비스/HPA 수동 배포
bash 02_scripts/prepare-jwt.sh
kubectl apply -k manual/eks

# 4. Argo CD 설치 후 런북대로 저장소 연결·Root 적용
bash 02_scripts/install-argocd.sh
bash 02_scripts/bootstrap.sh apply-root
```

`render-aws-runtime.sh`는 `manual/eks`만 수정한다. Argo CD가 읽는
`03_manifests/eks/shared/secrets.yaml` 값은 확인 후 직접 수정·commit·push한다.

Root Application은 `applications/`를 읽고, child Application이 `shared`,
`accounts`, `ledger`, `frontend`를 배포합니다. 워크로드에 직접
`kubectl apply`를 실행하지 마세요. Argo CD가 유일한 리소스 소유자입니다.

## 검증

```bash
kubectl kustomize 03_manifests/eks
kubectl apply --dry-run=server -f manual/eks/argocd-exposure/targetgroupbinding.yaml
kubectl kustomize 03_manifests/eks/applications
kubectl -n argocd get applications
```

