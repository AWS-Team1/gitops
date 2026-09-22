# EKS/GKE 클러스터 재생성 런북

AWS/GCP dev 환경을 처음부터 만들고 Argo CD를 먼저 설치한 뒤 GitOps를 push하는 절차는
[Dev EKS/GKE 최초 구축 런북](DEV_MULTI_CLOUD_BOOTSTRAP_RUNBOOK.md)을 따른다.

## 보장 범위

이 런북은 **클러스터만** 지웠다가 다시 만드는 절차다. 다음 상태는 유지한다.

- AWS: `aws-core`, `aws-rds`, `aws-cache`, `aws-dms`, `aws-ops`(ECR·Argo CD ALB 포함)
- GCP: `gcp-core`, `gcp-cloudsql`, `net-link`, `gcp-ops`(Argo CD 고정 IP·DNS 포함)
- AWS Secrets Manager와 GCP Secret Manager의 DB 비밀번호
- GCP JWT 키. AWS JWT 키는 기존 AWS 스크립트가 EKS 재생성 후 다시 준비한다.

`terraform destroy`를 전체 Infra 루트에 실행하지 않는다. 대상은 `aws-eks`, `gcp-gke`뿐이다.

## 사전 확인

| CLI 명령어 | 목적 | 정상 결과 |
|---|---|---|
| `git -C Infra status --short --branch` | Infra 코드와 브랜치 확인 | 의도하지 않은 로컬 변경 없음 |
| `git -C gitops status --short --branch` | GitOps 코드와 브랜치 확인 | 의도하지 않은 로컬 변경 없음 |
| `terraform version` | ephemeral 값 지원 여부 확인 | Terraform `1.11.0` 이상 |
| `aws sts get-caller-identity --query Account --output text` | AWS 계정 오실행 방지 | `769413326616` |
| `gcloud config get-value project` | GCP 프로젝트 확인 | `kdt4-1-506106` |
| `kubectl config current-context` | 삭제/배포 대상 확인 | 작업할 때 `boa-eks` 또는 `boa-gke` 포함 |
| `AWS_PROFILE=team1 aws s3api head-object --bucket boa-terraform-state-6416 --key gcp/core/terraform.tfstate` | GCP core state 존재 확인 | object metadata 출력 |
| `AWS_PROFILE=team1 aws s3api head-object --bucket boa-terraform-state-6416 --key gcp/gke/terraform.tfstate` | GKE state 존재 확인 | object metadata 출력 |

두 GCP state 확인 중 하나라도 `404`가 나오면 아래 destroy/apply를 실행하지 않는다.
2026-09-21 검증 시점에는 `gcp/ops/terraform.tfstate`만 있고 core/GKE state가 없었다.
현재 리소스를 해당 root로 import해 state 소유권을 복구한 뒤 이 런북을 실행해야 한다.

## 삭제

### AWS

| CLI 명령어 | 목적 | 정상 결과 |
|---|---|---|
| `bash gitops/02_scripts/teardown-cluster.sh --confirm` | Argo CD reconcile을 멈추고 앱 Ingress/ALB 삭제 | `앱 Ingress/ALB 정리 완료` |
| `kubectl -n argocd delete targetgroupbinding argocd-server --ignore-not-found` | 유지할 ops ALB에서 기존 EKS Pod target 해제 | TargetGroupBinding 삭제 |
| `kubectl delete nodepool default --ignore-not-found` | Karpenter가 만든 노드 회수 시작 | NodePool 삭제 |
| `kubectl wait --for=delete nodeclaims --all --timeout=15m` | Terraform 밖 EC2 노드가 남지 않게 대기 | 모든 NodeClaim 삭제 |
| `terraform -chdir=Infra/aws-db-bootstrap destroy -target=aws_eks_pod_identity_association.db_bootstrap -auto-approve` | 기존 EKS에 매달린 DB bootstrap association만 제거 | association 1개 삭제, Secret/IAM 유지 |
| `terraform -chdir=Infra/aws-eks plan -destroy -out=destroy.tfplan` | EKS 삭제 범위 확인 | EKS root 리소스만 destroy 예정 |
| `terraform -chdir=Infra/aws-eks apply destroy.tfplan` | EKS 삭제 | apply complete, EKS 없음 |

`aws-ops`를 삭제하지 않으므로 ECR과 Argo CD용 ALB/DNS는 남는다. `aws-db-bootstrap` 전체를 destroy하지 않는다.

### GCP

| CLI 명령어 | 목적 | 정상 결과 |
|---|---|---|
| `bash gitops/02_scripts/teardown-gke.sh --confirm` | frontend LB와 Argo CD Ingress가 만든 LB 구성요소 삭제 | `GKE 컨트롤러 소유 LB 정리 완료` |
| `terraform -chdir=Infra/gcp-gke plan -destroy -out=destroy.tfplan` | GKE 삭제 범위 확인 | GKE cluster/node pool/노드 SA만 destroy 예정 |
| `terraform -chdir=Infra/gcp-gke apply destroy.tfplan` | GKE 삭제 | apply complete, GKE 없음 |

`gcp-ops`를 삭제하지 않으므로 `boa-gke-argocd-ip`와 Route 53 DNS는 남는다. Cloud SQL과 Secret Manager도 삭제하지 않는다.

## 재생성

### AWS/GCP 동시 생성 및 배포

위 사전 확인의 GCP core/GKE state가 모두 존재하는 경우에만 실행한다.
아래는 Linux 기반 EC2 코드 서버에서 실행한다. GCP apply 입력값은 팀의 승인된
`Infra/gcp-gke/terraform.tfvars`에 프로젝트 ID, 오사카 리전(`asia-northeast2`),
코드 서버의 `/32` 승인 CIDR을 넣어 둔다.

```bash
cp Infra/gcp-gke/terraform.tfvars.example Infra/gcp-gke/terraform.tfvars
# 203.0.113.10/32를 실제 코드 서버 공인 IP/32로 한 번만 변경한다.
```

| CLI 명령어 | 목적 | 정상 결과 |
|---|---|---|
| `terraform -chdir=Infra/aws-eks init && terraform -chdir=Infra/gcp-gke init` | 두 root/provider/backend 준비 | 두 init 성공 |
| `terraform -chdir=Infra/aws-eks apply -auto-approve & AWS_PID=$!; terraform -chdir=Infra/gcp-gke apply -auto-approve & GCP_PID=$!; wait $AWS_PID; AWS_RC=$?; wait $GCP_PID; GCP_RC=$?; test $AWS_RC -eq 0 -a $GCP_RC -eq 0` | EKS와 GKE 동시 생성 | 두 apply 모두 exit 0 |
| `terraform -chdir=Infra/aws-db-bootstrap apply -auto-approve` | 새 EKS의 DB bootstrap Pod Identity 재연결 | association 생성, DB Secret 유지 |
| `aws eks update-kubeconfig --name boa-eks --region ap-northeast-2` | EKS context 생성 | `boa-eks` context 존재 |
| `gcloud container clusters get-credentials boa-gke --region asia-northeast2 --project kdt4-1-506106` | GKE context 생성 | `boa-gke` context 존재 |
| `export INFRA_ROOT="$PWD/Infra" ARGOCD_REPO_USERNAME='<user>'; read -rs ARGOCD_REPO_PASSWORD; export ARGOCD_REPO_PASSWORD` | 병렬 bootstrap 입력값 준비 | 환경변수 설정 |
| `bash gitops/02_scripts/bootstrap-all.sh` | 독립 kubeconfig로 AWS/GCP 서비스 동시 배포 | `AWS/GCP GitOps bootstrap 완료` |

`bootstrap-all.sh`는 새 클러스터용이다. AWS는 기존 `bootstrap.sh prepare` 흐름을
그대로 사용하고, GCP는 JWT 준비 후 Argo CD standby 배포를 수행한다. 재실행 검증만
필요하면 플랫폼별 `bootstrap-argocd-platform.sh`를 사용한다.

### AWS

| CLI 명령어 | 목적 | 정상 결과 |
|---|---|---|
| `terraform -chdir=Infra/aws-eks init && terraform -chdir=Infra/aws-eks apply` | EKS와 필수 addon/controller 생성 | apply complete |
| `terraform -chdir=Infra/aws-db-bootstrap apply` | 새 EKS에 Pod Identity Association 재연결 | association 생성, 기존 DB Secret 유지 |
| `aws eks update-kubeconfig --name boa-eks --region ap-northeast-2` | kubectl을 새 EKS에 연결 | context 갱신 |
| `bash gitops/02_scripts/render-aws-runtime.sh --infra-root "$PWD/Infra"` | 유지 중인 ops ALB/RDS 값을 수동 bootstrap YAML에 반영 | 두 YAML 경로 출력 |
| `bash gitops/02_scripts/bootstrap.sh prepare` | 기존 AWS 방식대로 JWT, Metrics Server, 앱, Argo CD, Karpenter 준비 | `EKS 최초 준비 완료` |
| `export ARGOCD_REPO_USERNAME='<user>'; read -rs ARGOCD_REPO_PASSWORD; export ARGOCD_REPO_PASSWORD` | 비공개 Git 저장소 자격 증명 준비 | 환경변수 설정 |
| `bash gitops/02_scripts/bootstrap-argocd-platform.sh eks` | Root Application부터 서비스까지 Argo CD로 수렴·검증 | Application 5개 Synced/Healthy, 앱 6개 Ready |

AWS JWT Secret이 EKS root와 함께 재생성되는 현재 구조에서는 `prepare-jwt.sh`가 새 키를 만든다. 따라서 재생성 전 JWT 세션은 무효화된다. DB Secret은 회전하지 않는다.

### GCP

| CLI 명령어 | 목적 | 정상 결과 |
|---|---|---|
| `terraform -chdir=Infra/gcp-gke init && terraform -chdir=Infra/gcp-gke apply` | Secret Sync가 활성화된 GKE 재생성 | apply complete |
| `gcloud container clusters get-credentials boa-gke --region asia-northeast2 --project kdt4-1-506106` | kubectl을 새 GKE에 연결 | context 갱신 |
| `export ARGOCD_REPO_USERNAME='<user>'; read -rs ARGOCD_REPO_PASSWORD; export ARGOCD_REPO_PASSWORD` | 비공개 Git 저장소 자격 증명 준비 | 환경변수 설정 |
| `bash gitops/02_scripts/bootstrap-argocd-platform.sh gke` | JWT 재사용/생성, Argo CD 설치, standby 서비스 동기화 | Application 5개 Synced/Healthy, 앱 6개 replicas=0 |

GCP의 `prepare-jwt-gcp.sh`는 `boa-jwt-private`, `boa-jwt-public`을 조회한다. 둘 다 비어 있을 때만 RSA 4096 키를 만들고, 기존 버전이 있으면 재사용한다. DB 비밀번호 Secret은 생성하거나 변경하지 않는다.

## 최종 검증

| CLI 명령어 | 목적 | 정상 결과 |
|---|---|---|
| `kubectl -n argocd get applications` | Argo CD CD 상태 확인 | Root+Child 5개 모두 Synced/Healthy |
| `kubectl -n bank-of-anthos get secret accounts-db-secret ledger-db-secret bank-app-jwt` | Secret 동기화 확인 | 세 Secret 존재 |
| `kubectl -n bank-of-anthos get deploy,hpa` | 플랫폼별 실행 정책 확인 | EKS 앱 Ready/HPA 6개, GKE replicas=0/HPA 없음 |
| `terraform -chdir=Infra/aws-eks plan` 또는 `terraform -chdir=Infra/gcp-gke plan` | Terraform drift 확인 | `No changes` |

## 현재 남은 구조적 제약

1. `aws-db-bootstrap`의 Pod Identity Association만 EKS 수명주기에 묶여 있다. 위 targeted destroy/apply가 현재 최소 안전 절차다. 이 수동 단계를 없앨 때만 association을 별도 root로 옮긴다.
2. 이 절차는 DB 재생성을 보장하지 않는다. GCP 매니페스트의 Cloud SQL 사설 IP와 AWS RDS master Secret ARN은 DB를 유지한다는 전제다.
3. Redis는 아직 GitOps에 연결되지 않았다. 현재 회원가입 분산 락은 Redis가 없으면 실패하도록 구현되어 있으므로 실제 활성화 전 별도 Redis 인프라·Secret·NetworkPolicy가 필요하다.
