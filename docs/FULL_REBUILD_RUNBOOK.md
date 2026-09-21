# AWS/GCP 전체 재구축 런북

## 1. 범위

이 문서는 Terraform이 관리하는 네트워크·DB·클러스터·DMS·Load Balancer를 모두
내렸다가 다시 만드는 절차다. 다음 영속 자원은 삭제하지 않는다.

- Terraform state S3 bucket `boa-terraform-state-6416`
- AWS ECR과 GCP Artifact Registry(GAR), 그 안의 이미지
- AWS/GCP DB Secret 컨테이너
- GCP JWT Secret, Public/Private Route53 Hosted Zone, ACM 인증서
- AWS 기존 VPC `vpc-0a36febf3057e5da0`와 SSH Key Pair `boa-bastion`

RDS와 Cloud SQL 데이터는 삭제된다. AWS RDS는 최종 snapshot을 남기지 않는 현재
설정이므로 데이터 보존이 필요하면 destroy 전에 수동 snapshot을 만든다.

## 2. 1회성 선행조건

| 명령 | 목적 | 정상 결과 |
|---|---|---|
| `AWS_PROFILE=team1 aws sts get-caller-identity` | AWS 계정 확인 | Account `769413326616` |
| `gcloud config set project kdt4-1-506106` | GCP 프로젝트 고정 | project updated |
| `gcloud services enable compute.googleapis.com container.googleapis.com sqladmin.googleapis.com servicenetworking.googleapis.com secretmanager.googleapis.com dns.googleapis.com artifactregistry.googleapis.com iamcredentials.googleapis.com` | Terraform이 사용할 GCP API 활성화 | 오류 없이 완료 |
| `aws s3api head-bucket --bucket boa-terraform-state-6416 --profile team1` | state backend 확인 | 출력 없이 exit 0 |
| `gcloud artifacts repositories describe bank-of-anthos --location=asia-northeast2` | 보존 GAR 확인 | repository 정보 출력 |

AWS 기존 VPC, Route53 Zone, ACM 인증서, Key Pair가 없으면 현재 AWS Terraform은
처음부터 생성할 수 없다. 이는 의도된 외부 기반 자원이다.

각 Terraform root의 `.tfvars`를 준비한다.

- `aws-eks`: Code Server IAM role
- `gcp-core`, `gcp-gke`, `gcp-cloudsql`, `gcp-ops`, `net-link`: GCP project/오사카 리전 및 네트워크 값
- `gcp-cloudsql`, `aws-dms`: 동일한 `dms_writer` 비밀번호
- `net-link`: VPN PSK 4개

기존 GCP DB Secret을 처음 Terraform state에 편입하는 경우 컨테이너만 한 번 import한다.
새 Secret version은 다음 apply가 Cloud SQL 사용자와 같은 비밀번호로 생성한다.

```bash
terraform -chdir=Infra/gcp-cloudsql import \
  'google_secret_manager_secret.app_database["accounts"]' \
  projects/kdt4-1-506106/secrets/boa-database-accounts
terraform -chdir=Infra/gcp-cloudsql import \
  'google_secret_manager_secret.app_database["ledger"]' \
  projects/kdt4-1-506106/secrets/boa-database-ledger
```

Secret 외의 실제 자원이 남아 있는데 state만 없다면 apply하지 않는다. 먼저 import하거나
실제 자원을 정리해 “빈 관리 영역” 전제를 맞춘다.

## 3. 전체 삭제

### 3.1 Kubernetes controller 자원

개별 실행:

```bash
kubectl config use-context <boa-eks-context>
bash gitops/02_scripts/teardown-cluster.sh --confirm

kubectl config use-context <boa-gke-context>
bash gitops/02_scripts/teardown-gke.sh --confirm
```

결과는 앱 ALB/GCLB, Argo TargetGroupBinding, Karpenter NodeClaim이 모두 삭제된 상태다.

### 3.2 Terraform

아래는 생성의 역순이다.

| 명령 | 목적 | 정상 결과 |
|---|---|---|
| `terraform -chdir=Infra/aws-dms destroy` | DMS task/endpoint/instance 삭제 | destroy complete |
| `terraform -chdir=Infra/net-link destroy` | AWS-GCP VPN 삭제 | destroy complete |
| `terraform -chdir=Infra/aws-db-bootstrap destroy -target=aws_eks_pod_identity_association.db_bootstrap` | EKS에 묶인 association만 삭제 | Secret/IAM 유지 |
| `terraform -chdir=Infra/aws-eks destroy` | EKS 삭제 | destroy complete |
| `terraform -chdir=Infra/gcp-gke destroy` | GKE 삭제 | destroy complete |
| `terraform -chdir=Infra/gcp-cache destroy` | GCP Valkey/PSC/endpoint Secret 삭제 | destroy complete |
| `terraform -chdir=Infra/gcp-cloudsql apply -var='deletion_protection=false'` | Cloud SQL 삭제 보호 해제 | apply complete |
| `terraform -chdir=Infra/gcp-cloudsql destroy -target=module.cloudsql -target=google_dns_record_set.database -target=google_dns_managed_zone.database -target=google_secret_manager_secret_version.accounts -target=google_secret_manager_secret_version.ledger -var='deletion_protection=false'` | Cloud SQL/DNS/비밀번호 버전 삭제, Secret 컨테이너 유지 | destroy complete |
| `terraform -chdir=Infra/aws-rds destroy` | RDS 삭제 | destroy complete |
| `terraform -chdir=Infra/aws-cache destroy` | Valkey 삭제 | destroy complete |
| `terraform -chdir=Infra/gcp-ops destroy` | GCP Argo IP/DNS 삭제 | destroy complete |
| `terraform -chdir=Infra/aws-ops destroy -target=aws_route53_record.argocd -target=module.ops_alb` | AWS Argo ALB/DNS만 삭제, ECR 유지 | targeted destroy complete |
| `terraform -chdir=Infra/gcp-core destroy` | GCP VPC/NAT/PSA 삭제 | destroy complete |
| `terraform -chdir=Infra/aws-core destroy` | AWS subnet/NAT/bastion 삭제, 기존 VPC 유지 | destroy complete |

`aws-db-bootstrap` 전체와 `aws-ops` 전체를 destroy하지 않는다. 전자는 DB Secret을,
후자는 ECR을 보존하기 위해서다.

## 4. 빈 관리 영역에서 전체 생성

### 4.1 기반 네트워크

```bash
terraform -chdir=Infra/aws-core init
terraform -chdir=Infra/gcp-core init
terraform -chdir=Infra/aws-core apply & AWS_CORE_PID=$!
terraform -chdir=Infra/gcp-core apply & GCP_CORE_PID=$!
wait $AWS_CORE_PID && wait $GCP_CORE_PID
```

### 4.2 DB·클러스터·운영 endpoint

각 root를 개별 실행해도 되고, 아래처럼 독립 root만 병렬 실행해도 된다.

```bash
terraform -chdir=Infra/aws-rds apply & P1=$!
terraform -chdir=Infra/aws-cache apply & P2=$!
terraform -chdir=Infra/aws-eks apply & P3=$!
terraform -chdir=Infra/aws-ops apply & P4=$!
terraform -chdir=Infra/gcp-cloudsql apply & P5=$!
terraform -chdir=Infra/gcp-gke apply & P6=$!
terraform -chdir=Infra/gcp-ops apply & P7=$!
terraform -chdir=Infra/gcp-cache apply & P8=$!
wait $P1 && wait $P2 && wait $P3 && wait $P4 && wait $P5 && wait $P6 && wait $P7 && wait $P8
```

그 다음 교차 의존 root를 순서대로 적용한다.

```bash
terraform -chdir=Infra/net-link apply
terraform -chdir=Infra/aws-db-bootstrap apply
terraform -chdir=Infra/aws-dms apply -var='start_tasks=false'
```

### 4.3 RDS master Secret ARN 갱신

RDS를 다시 만들면 master Secret ARN이 바뀐다. 다음 출력값으로
`gitops/03_manifests/eks/shared/secrets.yaml`의 `rds!db-...` 한 줄만 갱신한다.

```bash
terraform -chdir=Infra/aws-db-bootstrap output -raw rds_master_secret_arn
git diff -- gitops/03_manifests/eks/shared/secrets.yaml
```

이미지 YAML을 stage하지 말고 해당 파일만 별도 commit해 `dev`에 반영한다.

### 4.4 kubeconfig와 애플리케이션

```bash
aws eks update-kubeconfig --name boa-eks --region ap-northeast-2
gcloud container clusters get-credentials boa-gke --region asia-northeast2 --project kdt4-1-506106

export INFRA_ROOT="$PWD/Infra"
export ARGOCD_REPO_USERNAME='<github-user-or-bot>'
read -rs ARGOCD_REPO_PASSWORD && export ARGOCD_REPO_PASSWORD
```

개별 실행:

```bash
kubectl config use-context <boa-eks-context>
bash gitops/02_scripts/bootstrap-argocd-platform.sh eks

kubectl config use-context <boa-gke-context>
bash gitops/02_scripts/bootstrap-argocd-platform.sh gke
```

동시 실행:

```bash
bash gitops/02_scripts/bootstrap-all.sh
```

EKS는 앱 6개 Ready/HPA 6개, GKE는 앱 6개 Ready/HPA 0개가 정상이다.

## 5. 검증

```bash
kubectl -n argocd get applications
kubectl -n bank-of-anthos get deploy,hpa,secret
terraform -chdir=Infra/aws-eks plan
terraform -chdir=Infra/gcp-gke plan
terraform -chdir=Infra/aws-cache plan
terraform -chdir=Infra/gcp-cache plan
```

각 클러스터의 Argo Application 5개가 `Synced/Healthy`이고 Terraform plan이
`No changes`여야 한다. DMS 연결과 대상 스키마를 확인한 뒤에만 `start_tasks=true`로 apply한다.

### 5.1 GCP DB 권한 확인 — 현재 자동화 공백

`gcp-cloudsql`은 `accounts_app`, `ledger_app` 로그인 사용자와 비밀번호 Secret을 만들지만,
각 DB의 schema/table 권한은 부여하지 않는다. DMS가 테이블을 복제해도 앱 사용자의 권한까지
보장하지 않으므로, 완전히 비운 상태에서 재구축한 뒤에는 GCP를 active로 전환하지 않는다.
`replicas=1`과 Argo `Healthy`도 DB 사용 가능 여부를 증명하지 않는다.

다음 SQL 결과를 DB 담당자와 확인한 뒤 DMS를 시작하거나 GCP를 active로 전환한다.

```sql
SELECT datname, datacl FROM pg_database WHERE datname IN ('accountsdb', 'ledgerdb');
SELECT grantee, table_schema, privilege_type
FROM information_schema.role_table_grants
WHERE grantee IN ('accounts_app', 'ledger_app')
ORDER BY grantee, table_schema, table_name, privilege_type;
```

현재 최소 대안은 권한 SQL을 수동 실행하는 것이다. 반복 재구축까지 한 번에 보장하려면 AWS의
`db-bootstrap`처럼 GCP에도 idempotent grant Job과 그 Job이 쓸 관리자 Secret이 추가로 필요하다.

### 5.2 GCP frontend 노출 — Application Load Balancer

`03_manifests/gke/frontend`는 `ClusterIP` Service와 GCE Ingress를 사용해 외부 HTTP
Application Load Balancer를 만든다. Ingress IP는 고정하지 않으므로 클러스터를 재생성할
때마다 새 `ADDRESS`를 확인해 `app.bespinglobal.site` A 레코드를 수동 갱신한다.

### 5.3 Redis/Valkey

AWS `aws-cache`는 ElastiCache Valkey와 자격 증명/runtime endpoint Secret을 만들고 EKS가
TLS로 연결한다. GCP `gcp-cache`는 Memorystore for Valkey, PSC Subnet, endpoint Secret을
만들고 GKE SecretSync가 endpoint를 동기화한다. 두 플랫폼 모두 Cache root를 클러스터 앱보다
먼저 적용해야 한다.

GCP는 private PSC 전용 경로에서 `AUTH_DISABLED`와 전송 암호화 비활성화를 사용한다. 현재
Google provider 6.x와 애플리케이션의 정적 자격 증명 방식으로 IAM/token auth를 자동화할 수
없기 때문이다. GCP에서 인증/TLS가 필수이면 앱에 Google IAM/token 갱신과 관리 CA trust를
추가한 뒤 해당 옵션을 활성화한다.

## 6. AWS/GCP 흐름 차이

| 항목 | AWS | GCP |
|---|---|---|
| 네트워크 | 기존 VPC 재사용, subnet/NAT만 관리 | VPC부터 Terraform 생성 |
| 이미지 저장소 | `aws-ops` state의 ECR, 보존 | 외부 GAR, 보존 |
| DB 주소 | `db.boa.internal` Private Route53 | `db.gcp.boa.internal` Private Cloud DNS |
| DB 앱 계정 | db-bootstrap Job이 role/schema/권한 생성 | Terraform이 로그인 사용자/Secret만 생성; schema/table 권한 자동화는 아직 없음 |
| Cache | ElastiCache Serverless Valkey, TLS/RBAC | Memorystore for Valkey, private PSC |
| Secret 동기화 | AWS CSI provider + sync Deployment | GKE SecretSync addon |
| 앱 상태 | active, HPA 6개 | active, replicas=1, HPA 없음 |
| 앱 노출 | Ingress가 ALB 생성 | GCE Ingress가 Application Load Balancer 생성; 재생성 후 DNS 수동 갱신 |
| Argo 노출 | Terraform ops ALB + TargetGroupBinding | Terraform 고정 IP + GKE Ingress |
| JWT | EKS destroy 시 Secret도 삭제되어 재생성 | Secret Manager에 유지, 기존 키 재사용 |

## 7. 하드코딩 값 목록

### Infra

| 값 | 위치/용도 | 재생성 영향 |
|---|---|---|
| AWS account `769413326616` | IAM role, ECR, 스크립트 계정 가드 | 계정 변경 시 모두 수정 |
| AWS region `ap-northeast-2`, AZ `2a/2c` | 모든 AWS root | 리전 변경 시 backend 제외 전체 수정 |
| VPC `vpc-0a36febf3057e5da0` / `192.168.0.0/16` | `aws-core` 기존 VPC | VPC가 없으면 apply 실패 |
| public `192.168.2/24`, `192.168.3/24` | ALB/NAT subnet | GitOps frontend NetworkPolicy와 일치 필요 |
| private `192.168.8/24`, `192.168.9/24` | EKS node/pod subnet | VPN/보안 규칙과 일치 필요 |
| DB `192.168.16/24`, `192.168.17/24` | RDS subnet | GitOps DB NetworkPolicy와 일치 필요 |
| cache `192.168.24/24`, `192.168.25/24` | Valkey subnet | 변경 시 cache 재생성 가능 |
| `boa.internal`, `bespinglobal.site`, `*.bespinglobal.site` | Private/Public DNS와 ACM | Zone/인증서 선행 필요 |
| `boa-bastion` | 기존 EC2 Key Pair | 없으면 aws-core 실패 |
| EKS API 허용 CIDR `15.165.176.99/32` | EKS public endpoint | 실행 위치 IP가 다르면 kubectl 실패 |
| Code Server role `arn:aws:iam::769413326616:role/CodeServerEc2Role` | EKS access entry | role 변경 시 `aws-eks` 변수 수정 |
| EKS `1.36`, `t3.large`, 노드 `2/2/2`, disk `30GiB` | EKS control plane/node group | 버전·비용·용량 영향 |
| RDS `boa-postgres`, PostgreSQL `16.14`, `db.t4g.micro`, `30-100GiB` | AWS 원본 DB | 재생성 시 endpoint/master Secret ARN 변경 |
| RDS DB/admin `boadb`, `boa_admin` | RDS 및 db-bootstrap | bootstrap 연결값과 일치 필요 |
| DMS `dms.t3.medium`, engine `3.5.3`, storage `50GiB` | AWS DMS | 복제 성능·비용 영향 |
| DMS 사용자 `dms_reader`, `dms_writer` | 원본/대상 endpoint | 양쪽 DB 권한·비밀번호 일치 필요 |
| GCP project `kdt4-1-506106` | provider/GAR/Secret 경로 | 프로젝트 변경 시 GitOps도 수정 |
| GCP region `asia-northeast2` | core/GKE/Cloud SQL/VPN | 모든 GCP root에서 동일해야 함 |
| GCP VPC `10.10.0.0/20`, pods `10.10.16.0/20`, services `10.10.32.0/20` | gcp-core | GKE와 VPN에 영향 |
| PSA `10.50.0.0/16` | Cloud SQL 사설 IP 범위 | GitOps NetworkPolicy와 일치 필요 |
| GKE master `10.10.255.0/28`, `e2-standard-2`, 노드 `1-4` | GKE control plane/node pool | CIDR 중복·비용·용량 영향 |
| Cloud SQL `boa-postgres-dr`, PostgreSQL 16, `db-custom-1-3840`, ZONAL, `20GiB` | 코드 기준 대상 DB | 실제 기존 인스턴스와 이름/tier 불일치 |
| DB `accountsdb`, `ledgerdb`; app role `accounts_app`, `ledger_app` | AWS/GCP 애플리케이션 DB | Secret과 권한 SQL도 함께 변경 |
| VPN ASN AWS `64512`, GCP `64514` | BGP | 서로 달라야 함 |
| VPN tunnel CIDR `169.254.10.0/30`, `.4/30`, `.8/30`, `.12/30` | HA VPN 4개 tunnel | 기존 tunnel과 중복 금지 |
| state bucket `boa-terraform-state-6416` | 모든 backend/remote state | 삭제 금지 |
| cluster `boa-eks`, `boa-gke` | Terraform/kube context/script guard | 이름 변경 시 스크립트 수정 |

### GitOps

| 값 | 위치/용도 | 재생성 영향 |
|---|---|---|
| repo `https://github.com/AWS-Team1/gitops.git`, branch `dev` | Root/Child Application | 변경 시 Application 전체 수정 |
| namespace `bank-of-anthos` | 모든 워크로드/SecretSync | IAM principal과 함께 변경 |
| ECR `boa-{frontend,userservice,contacts,balancereader,ledgerwriter,transactionhistory}` | AWS 이미지 주소 | repository 변경 시 EKS overlay 수정 |
| GAR `asia-northeast2-docker.pkg.dev/kdt4-1-506106/bank-of-anthos` | GCP 이미지 주소 | project/region/repository 변경 시 GKE overlay 수정 |
| `db.boa.internal`, `db.gcp.boa.internal` | 앱 DB 주소 | DNS record와 일치 필요 |
| `/boa/database/*`, `/boa/jwt/*` | AWS Secrets Manager | Terraform/CSI 이름과 일치 필요 |
| `boa-database-*`, `boa-jwt-*` | GCP Secret Manager | Terraform/SecretSync 이름과 일치 필요 |
| `argocd.bespinglobal.site`, `argocd-gcp.bespinglobal.site` | Argo UI | DNS/인증서/Ingress와 일치 필요 |
| Argo Helm chart `10.4.0`, Karpenter `1.14.1` | bootstrap scripts | 업그레이드는 별도 검증 필요 |
| 이미지 `sha-*` | 클라우드별 Deployment overlay | CI가 갱신; 수동 재구축 시 변경 금지 |

`manual/eks`와 Infra의 `boa/k8s`는 현재 배포 정본이 아니므로 그 안의 과거 ARN/IP는
실행용 하드코딩 목록에서 제외한다.
