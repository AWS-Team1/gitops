# EKS Argo CD 재현 런북 (`jiho-test-cd`)

이 문서는 기존 `jiho-test-cd` 브랜치 기록이다. `feat/manual`의 앱/HPA·수동
Karpenter 설치와 삭제는 [통합 런북](EKS_APP_ARGO_KARPENTER_HPA_RUNBOOK.md)을 따른다.

이 문서는 새 작업자가 `AWS-TEAM1-DEV/Infra`와 `AWS-TEAM1-DEV/gitops`의
`jiho-test-cd` 브랜치만 checkout한 뒤, 터미널과 Argo CD UI에서 같은 배포를
재현하기 위한 절차다. 명령은 code server의 `karfa` 또는 동등한 AWS 권한을 가진
사용자에서 실행한다.

## 0. HARD-CODED 교체 목록

아래 값은 현재 팀 환경에 맞춘 **HARD-CODED 값**이다. 다른 환경에서 재사용할 때
코드의 `HARD-CODED` 주석과 아래 표를 먼저 바꾼다.

| 값 | 현재 값 | 주요 위치 |
|---|---|---|
| AWS Account | `769413326616` | Infra account guard, Secret 준비 스크립트, ECR 이미지 |
| Region | `ap-northeast-2` | Terraform provider/backend, 준비 스크립트 |
| Terraform state bucket | `boa-terraform-state-6416` | 각 root `backend.tf`, remote state |
| EKS cluster | `boa-eks` | Infra output/Pod Identity, kubeconfig |
| Kubernetes namespace | `bank-of-anthos` | Pod Identity, GitOps manifests |
| GitHub repository | `AWS-TEAM1-DEV/gitops` | Root/Child Applications |
| Git revision | `jiho-test-cd` | Root/Child Applications |
| App DB Secret | `/boa/database/app` | Infra, SecretProviderClass, 준비 스크립트 |
| JWT Secrets | `/boa/jwt/private`, `/boa/jwt/public` | Infra/GitOps |
| Private DNS | `db.boa.internal` | Infra Route53, workload/DB bootstrap |
| Argo CD URL | `argocd.bespinglobal.site` | aws-ops, aws-cd-bootstrap |
| Helm chart | `argo-cd` chart `10.4.0` | `02_scripts/install-argocd.sh` |
| ALB TG ARN / SG ID | 계정에서 생성되는 값 | `targetgroupbinding.yaml`; render 스크립트가 갱신 |
| RDS master Secret ARN | RDS 재생성 시 변경 | `shared/secrets.yaml`; render 스크립트가 갱신 |

## 1. 필수 도구와 권한

```bash
for tool in aws terraform kubectl helm git openssl jq; do
  command -v "$tool" || exit 1
done

aws sts get-caller-identity
```

반드시 Account가 `769413326616`인지 확인한다. 필요한 권한은 Terraform backend S3,
VPC/EKS/RDS/ECR/ALB/Route53/Secrets Manager/IAM 관리 권한과 두 GitHub 저장소 접근권한이다.

## 2. 저장소 checkout

```bash
mkdir -p ~/work-dir
cd ~/work-dir

git clone https://github.com/AWS-TEAM1-DEV/Infra.git Infra
git -C Infra switch jiho-test-cd

git clone https://github.com/AWS-TEAM1-DEV/gitops.git gitops
git -C gitops switch jiho-test-cd
```

기존 clone이 있으면 `git status`로 로컬 변경이 없는지 확인하고 `git fetch` 및
`git switch jiho-test-cd`를 수행한다.

## 3. 기본 AWS 인프라 적용

모든 plan은 내용을 읽은 뒤 적용한다. `destroy`, 리소스 교체, 예상 밖 대량 변경이
보이면 중단한다.

`aws-eks/terraform.tfvars`는 Git에 저장하지 않는다.

```hcl
# HARD-CODED: 실제 code server 또는 운영자 IAM Role ARN으로 변경
code_server_role_arn = "arn:aws:iam::769413326616:role/CodeServerEc2Role"
```

적용 순서:

```bash
cd ~/work-dir/Infra

terraform -chdir=aws-core init
terraform -chdir=aws-core plan -out=/tmp/boa-core.tfplan
terraform -chdir=aws-core apply /tmp/boa-core.tfplan

terraform -chdir=aws-rds init
terraform -chdir=aws-rds plan -out=/tmp/boa-rds.tfplan
terraform -chdir=aws-rds apply /tmp/boa-rds.tfplan

terraform -chdir=aws-cache init
terraform -chdir=aws-cache plan -out=/tmp/boa-cache.tfplan
terraform -chdir=aws-cache apply /tmp/boa-cache.tfplan

terraform -chdir=aws-ops init
terraform -chdir=aws-ops plan -out=/tmp/boa-ops.tfplan
terraform -chdir=aws-ops apply /tmp/boa-ops.tfplan

terraform -chdir=aws-eks init
terraform -chdir=aws-eks plan -out=/tmp/boa-eks.tfplan
terraform -chdir=aws-eks apply /tmp/boa-eks.tfplan
```

기존 환경에서는 각 plan이 `No changes`일 수 있다.

## 4. Argo CD AWS 사전조건 적용

별도 state의 `aws-cd-bootstrap`이 다음을 관리한다.

- 애플리케이션 DB Secret 컨테이너
- DB bootstrap IAM Role/Policy/Pod Identity
- `db.boa.internal`
- `argocd.bespinglobal.site`

```bash
cd ~/work-dir/Infra
terraform -chdir=aws-cd-bootstrap init
terraform -chdir=aws-cd-bootstrap plan -out=/tmp/boa-cd-bootstrap.tfplan
terraform -chdir=aws-cd-bootstrap apply /tmp/boa-cd-bootstrap.tfplan
terraform -chdir=aws-cd-bootstrap output
```

## 5. AWS 런타임 값을 GitOps에 반영

ALB/SG/RDS를 재생성하면 ARN과 ID가 바뀐다. 아래 두 매니페스트의 값을 수동으로 갱신한다.

```bash
# manual/eks/argocd-exposure/targetgroupbinding.yaml
#   targetGroupARN: 새 Target Group ARN
#   spec.networking.ingress[].from[].securityGroup.groupID: 새 ALB Security Group ID
# 03_manifests/eks/shared/secrets.yaml
#   db-bootstrap SecretProviderClass의 objectName: 새 RDS master secret ARN

git diff --check
kubectl kustomize 03_manifests/eks >/dev/null
kubectl kustomize 03_manifests/eks/applications >/dev/null
kubectl kustomize 03_manifests/eks/argocd-exposure >/dev/null
```

`git diff`가 있으면 Argo CD 연결 전에 `jiho-test-cd`에 commit/push한다.

```bash
git diff
git add 03_manifests/eks/argocd-exposure/targetgroupbinding.yaml \
        03_manifests/eks/shared/secrets.yaml
git commit -m "chore: render AWS runtime values"
git push origin jiho-test-cd
```

## 6. Secret 값과 Argo CD 설치

다음 명령은 DB/JWT 값이 없을 때만 생성하고 기존 값은 보존한다. 비밀값을 화면에
출력하거나 Git에 저장하지 않는다.

```bash
cd ~/work-dir/gitops
bash 02_scripts/bootstrap.sh prepare
```

이 명령이 수행하는 작업:

1. `/boa/database/app` 값 준비
2. JWT RSA 키 쌍 준비 및 검증
3. Helm으로 Argo CD 설치
4. UI용 TargetGroupBinding 적용

Target Group 확인:

```bash
TG_ARN=$(terraform -chdir=~/work-dir/Infra/aws-cd-bootstrap output -raw argocd_target_group_arn)
aws elbv2 describe-target-health \
  --region ap-northeast-2 \
  --target-group-arn "$TG_ARN"
```

상태가 `healthy`여야 한다.

## 7. Argo CD UI 로그인

URL:

```bash
terraform -chdir=~/work-dir/Infra/aws-cd-bootstrap output -raw argocd_url
```

초기 계정은 `admin`이다. 비밀번호는 터미널에서 확인한다.

```bash
kubectl -n argocd get secret argocd-initial-admin-secret \
  -o jsonpath='{.data.password}' | base64 -d; echo
```

## 8. UI에서 private GitOps 저장소 연결

GitHub에서 fine-grained PAT를 만든다.

- Resource owner: `AWS-TEAM1-DEV`
- Repository access: `gitops`만 선택
- Repository permission: `Contents: Read-only`, `Metadata: Read-only`
- 조직 승인이 필요하면 승인 후 진행

Argo CD UI의 `Settings → Repositories → Connect Repo`에서 입력한다.

| 필드 | 입력값 |
|---|---|
| Connection method | `VIA HTTPS` |
| Type | `git` |
| Project | **비워 둔다(All projects)** |
| Repository URL | `https://github.com/AWS-TEAM1-DEV/gitops.git` |
| Username | PAT를 만든 GitHub 사용자명 |
| Password | fine-grained PAT |
| Skip server verification | 선택하지 않음 |
| Enable LFS | 선택하지 않음 |

`Project=default`로 설정하면 Root 앱만 인증되고 `boa-*` 하위 앱은
`authentication required: Repository not found`로 실패한다. 반드시 비워 둔다.

연결 결과가 `Successful`인지 확인한다.

## 9. Root Application 적용

UI 연결이 완료된 다음에만 실행한다.

```bash
cd ~/work-dir/gitops
bash 02_scripts/bootstrap.sh apply-root
```

Root와 모든 Child Application은 `jiho-test-cd`를 desired revision으로 사용한다.
워크로드에 직접 `kubectl apply -k 03_manifests/eks`를 실행하지 않는다.

## 10. 최종 검증

```bash
cd ~/work-dir/gitops
bash 02_scripts/verify-argocd.sh
```

정상 기준:

- 6개 Application 모두 `Synced / Healthy`
- 서비스 Deployment 6개와 secret-sync Deployment가 모두 Available
- `db-bootstrap` Job `Complete`
- `db-secret` 존재
- Argo CD Target Group `healthy`
- `https://argocd.bespinglobal.site` 응답 `200`

추가 확인:

```bash
kubectl -n bank-of-anthos get secret db-secret
kubectl -n bank-of-anthos logs job/db-bootstrap
curl -kfsS -o /dev/null -w '%{http_code}\n' https://argocd.bespinglobal.site/
```

## 11. 자주 발생하는 오류

### Child Application이 `Unknown`

```text
authentication required: Repository not found
```

Repository 연결의 Project 제한을 제거한다. UI에서 Project를 빈 값으로 저장한다.

### `db-bootstrap`에서 Secret mount 실패

```bash
aws secretsmanager describe-secret --secret-id /boa/database/app --region ap-northeast-2
aws eks list-pod-identity-associations --cluster-name boa-eks --region ap-northeast-2
kubectl -n bank-of-anthos describe pod -l job-name=db-bootstrap
```

### Argo CD Target Group이 비어 있음

```bash
kubectl -n argocd get targetgroupbinding argocd-server
kubectl -n kube-system logs deployment/aws-load-balancer-controller --tail=100
```

Target Group ARN과 ALB SG ID가 현재 `aws-ops` 값과 일치하는지 확인한다.

### 변경 후 `OutOfSync`가 유지됨

UI에서 `Refresh → Hard Refresh`를 실행하고 다음을 확인한다.

```bash
kubectl -n argocd get applications
kubectl -n argocd get application boa-shared -o jsonpath='{.status.conditions}'
```

수동으로 만든 워크로드 리소스가 있으면 삭제부터 하지 말고 Git desired state와
차이를 확인한다. Application은 `selfHeal`과 `prune`이 활성화돼 있다.

## 12. 초기 관리자 Secret 정리

UI에서 관리자 비밀번호를 변경하고 새 비밀번호로 재로그인한 뒤에만 삭제한다.

```bash
kubectl -n argocd delete secret argocd-initial-admin-secret
```
