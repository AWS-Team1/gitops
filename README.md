# AWS GitOps

Bank of Anthos 워크로드와 Argo CD bootstrap 을 담는 저장소입니다.
AWS 인프라(Terraform)는 별도 저장소(`infra`)가 소유하고, **Kubernetes 로 선언되는
모든 것은 이 저장소가 소유**합니다.

## 구조

```text
.
├── bootstrap/                  # 클러스터에 딱 한 번 kubectl apply 되는 것
│   ├── argocd/values.yaml      #   Argo CD Helm values
│   ├── root-application.yaml   #   app-of-apps 루트 Application
│   └── kustomization.yaml
├── argocd/                     # root Application 이 동기화하는 경로
│   ├── appproject.yaml         #   AppProject: bank-app / platform
│   ├── platform/               #   GitOps 가 소유하는 클러스터 add-on
│   └── applicationset.yaml     #   workload Application 생성
├── k8s/
│   ├── base/                   # 클라우드·환경 무관 애플리케이션 리소스
│   ├── components/aws/         # 환경 무관 AWS 공통 설정
│   │   ├── networkpolicy.yaml
│   │   └── db-bootstrap/       #   DB 논리 DB·역할·스키마 부트스트랩
│   ├── overlays/<env>/aws/     # 환경별 값 (일부는 생성 파일)
│   └── cluster/karpenter/      # 비활성. README 참고
├── environments/<env>/aws.env  # Terraform 이 만들지 않는 입력값
└── scripts/
    ├── bootstrap-eks.sh        # 원클릭 렌더링·검증·배포
    └── register-repo-credentials.sh
```

## 저장소 역할 분리

| 소유 | 대상 | 이유 |
| --- | --- | --- |
| `infra` (Terraform) | VPC, EKS, RDS, IAM, Security Group, Pod Identity | AWS 리소스 수명주기 |
| `infra` (Terraform) | EKS managed addon (vpc-cni, coredns, kube-proxy, ebs-csi, pod-identity-agent, aws-secrets-store-csi-driver-provider) | EKS addon API 로 관리됨 |
| `infra` (Terraform) | AWS Load Balancer Controller | IAM Role + Pod Identity 결합이 필요 |
| `gitops` | Argo CD 설치, AppProject, ApplicationSet, workload | 순수 Kubernetes 선언 |
| `gitops` | secrets-store-csi-driver, metrics-server | AWS IAM 과 무관한 컨트롤러 |

> `infra` 의 EKS addon 은 Secrets Store CSI 의 **AWS provider** 만 설치합니다.
> CSI **driver** 본체(및 `SecretProviderClass` CRD)는 이 저장소의
> `argocd/platform/secrets-store-csi-driver.yaml` 이 sync-wave `-5` 로 먼저 설치합니다.

## 환경 값은 어디서 오는가

환경 종속 값은 `base/` 나 `components/` 에 두지 않습니다.
`scripts/bootstrap-eks.sh` 가 `terraform output -json` 을 읽어 아래 파일을 생성합니다.

| Terraform root output | 생성되는 파일 | 쓰이는 곳 |
| --- | --- | --- |
| `rds_address`, `rds_port` | `k8s/overlays/<env>/aws/env-config.properties` | `DB_HOST`, `DB_PORT` |
| `rds_app_secret_arn` | `k8s/overlays/<env>/aws/secretproviderclass.yaml` | 앱 Pod 의 DB 자격 증명 |
| `rds_master_user_secret_arn` | `k8s/overlays/<env>/aws/secretproviderclass-db-bootstrap.yaml` | db-bootstrap Job 전용 |
| `rds_bootstrap_db_name` | `k8s/overlays/<env>/aws/env-config.properties` | `BOOTSTRAP_DB_NAME` |
| `ecr_registry` | `k8s/overlays/<env>/aws/kustomization.yaml` | `images[].newName` |
| `eks_cluster_name`, `aws_region` | (파일 아님) | `aws eks update-kubeconfig` |
| `aws_account_id` | (파일 아님) | 계정 일치 검증 |

`environments/<env>/aws.env` 의 값(`ENABLE_APP_INGRESS`, `INGRESS_HOST`,
`ACM_CERTIFICATE_ARN`, `ALB_SSL_POLICY`, `ARGOCD_TARGET_GROUP_ARN`)은 Terraform
관리 대상이 아니므로 사람이 입력합니다.

`ENABLE_APP_INGRESS=false` 면 ALB 를 전혀 쓰지 않습니다. Ingress 와
TargetGroupBinding 이 렌더 결과에서 제외되고, 스크립트가 build 결과에 두 리소스가
0개인지 확인합니다. 접근은 port-forward 로 합니다.

```bash
kubectl -n argocd port-forward svc/argocd-server 8080:80
kubectl -n bank-of-anthos port-forward svc/frontend 8081:8080
```
비워두면 해당 기능을 켜지 않고, 형식이 틀리면 적용 전에 중단합니다.

생성 파일은 `# GENERATED FILE - do not edit manually.` 로 시작하며 Git 에 커밋됩니다.
Argo CD 가 읽는 Git 의 desired state 와 클러스터에 적용되는 내용이 항상 같습니다.
**비밀값(username/password/private key)은 어떤 생성 파일에도 들어가지 않습니다.**
RDS master secret 은 ARN 만 다루고 값은 조회조차 하지 않습니다.

## 실행 순서

시연 당일 복사해서 순서대로 실행할 명령은 [DEMO.md](DEMO.md)에 정리되어 있습니다.

Terraform 루트 output 이 없어 `scripts/bootstrap-eks.sh` 를 쓸 수 없을 때(인프라를 지웠다
다시 만든 경우 포함)는 값을 손으로 채우는 [docs/ARGOCD-MANUAL-RUNBOOK.md](docs/ARGOCD-MANUAL-RUNBOOK.md)
를 따릅니다.

```bash
# 0) 인프라 생성
terraform -chdir=~/infra init
terraform -chdir=~/infra apply

# 1) 렌더링 결과 미리보기 (아무것도 바꾸지 않음)
cd ~/gitops
./scripts/bootstrap-eks.sh --infra-dir ~/infra --environment dev

# 2) 저장소에 반영하고 커밋/푸시 (스크립트는 commit/push 하지 않음)
./scripts/bootstrap-eks.sh --infra-dir ~/infra --environment dev --render
git add k8s argocd bootstrap
git commit -m "chore(gitops): render dev/aws from terraform output"
git push

# 3) private 저장소면 Argo CD 에 자격 증명 등록 (최초 1회)
./scripts/register-repo-credentials.sh

# 4) 클러스터 적용
./scripts/bootstrap-eks.sh --infra-dir ~/infra --environment dev --apply
```

`--apply` 는 kubeconfig 갱신 → Argo CD 설치 → root Application 적용 →
Argo CD 가 `argocd/` 를 동기화(AppProject → platform controller → ApplicationSet) →
workload Application 이 `Synced/Healthy` 가 될 때까지 대기합니다.

주요 옵션: `--render`, `--apply`, `--skip-wait`, `--timeout`,
`--skip-argocd-install`, `--allow-dirty`, `--environment`, `--infra-dir`.

## 데이터베이스 자격 증명 분리

자격 증명 경계가 두 개입니다.

```text
RDS master secret (rds!db-*)
    └─ db-bootstrap Job 전용

/project/database/app  (role: bank_app)
    └─ 애플리케이션 Pod 5개 전용
```

- `k8s/components/aws/db-bootstrap/` 의 Job 이 Argo CD **Sync hook (wave -2)** 으로
  애플리케이션보다 먼저 돌면서 논리 DB 2개 생성 → `bank_app` 역할 생성 및 비밀번호를
  `/project/database/app` 값에 맞춤 → 스키마 적용 → `bank_app` 에 DML 권한만 부여
  (DDL·소유권 없음) 를 수행합니다. 전부 멱등이라 매 sync 마다 안전하게 재실행됩니다.
- Job 은 `bank-of-anthos-db-bootstrap` ServiceAccount 를 쓰고, 애플리케이션은
  `bank-of-anthos` 를 씁니다. Pod Identity 로 서로 다른 IAM Role 에 매핑되며
  (`infra/app-identity.tf`), **앱 Role 에는 `rds!db-*` 접근 권한이 없습니다.**
- master 자격 증명은 Kubernetes Secret 으로 동기화되지 않습니다. bootstrap 용
  SecretProviderClass 에는 `secretObjects` 가 없어 Job Pod 안에 파일로만 마운트됩니다.
- `bootstrap-eks.sh` 는 build 결과에서 master ARN 이 db-bootstrap SecretProviderClass
  **한 곳에서만** 참조되는지 확인하고, 아니면 적용 전에 중단합니다.

논리 DB 이름은 `environments/<env>/aws.env` 의 `ACCOUNTS_DB_NAME` /
`LEDGER_DB_NAME` 으로 정합니다. 스키마 SQL 은
`k8s/components/aws/db-bootstrap/sql/` 에 벤더링되어 있어 별도 ConfigMap 수작업이
필요 없습니다.

## CI 이미지 write-back 규칙

CI 는 `k8s/overlays/<env>/aws/kustomization.yaml` 의 `images[].newTag` 만
`sha-<commit>` 형식으로 교체합니다. `images[].newName` 은 `bootstrap-eks.sh` 가
Terraform output 으로 관리하므로 CI 가 건드리지 않습니다.

## Secret 처리

JWT 키와 DB 자격 증명은 Kubernetes Secret 을 저장소에 두지 않고 AWS Secrets Store
CSI Driver 로 주입합니다. `k8s/overlays/<env>/aws/secretproviderclass.yaml` 이
아래를 담당합니다.

- `/project/jwt/private` → Pod 내 `/tmp/.ssh/jwtRS256.key`
- `/project/jwt/public` → Pod 내 `/tmp/.ssh/jwtRS256.key.pub`
- `/project/database/app` → `db-secret` 의 `username` / `password`

각 Deployment 는 `db-secret` 을 `secretKeyRef` 로 참조하며, 인증에는 EKS Pod Identity
를 사용합니다.
