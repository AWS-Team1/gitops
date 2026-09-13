# EKS 구축·검증 런북

Terraform 으로 AWS 인프라를 만든 뒤, 코드서버에서 GitOps bootstrap 과 전체 검증을
수행하는 절차입니다. 모든 명령은 Bash 에서 실행하며 **Secret 값은 조회·출력하지
않습니다**.

- 대상 저장소: `~/infra` (Terraform), `~/gitops` (GitOps)
- 기준 브랜치: 양쪽 `dev`
- 시연용 축약 명령은 [../DEMO.md](../DEMO.md) 참고

---

## 0. 전제 조건

| 항목 | 확인 방법 | 현재 코드서버 상태 |
| --- | --- | --- |
| AWS CLI v2 / Terraform / kubectl / Helm 3 / jq / git | `command -v` | 모두 설치됨 |
| `kustomize` 단독 바이너리 | `command -v kustomize` | **없음.** 스크립트가 `kubectl kustomize` 로 자동 대체하므로 설치 불필요 |
| AWS 자격 증명 | `aws sts get-caller-identity` | `CodeServerEc2Role` 인스턴스 역할 |
| ECR 리포지토리 6개 | `aws ecr describe-repositories` | 존재 (Terraform 관리 대상 아님) |
| ACM 인증서 | `aws acm list-certificates --region ap-northeast-2` | `*.bespinglobal.site` **ISSUED** |
| Route 53 영역 | `aws route53 list-hosted-zones` | `bespinglobal.site.` |
| GitHub PAT | — | GitOps 저장소 **Contents: read** 만 부여 권장 |

```bash
for c in aws terraform kubectl helm jq git; do
  command -v "$c" >/dev/null || { echo "MISSING: $c"; exit 1; }
done
echo "필수 명령 확인 완료"
```

---

> **환경을 재생성했다면 반드시 확인할 것**
>
> `terraform destroy` 후 다시 `apply` 하면 아래 값이 **모두 바뀝니다.**
> `k8s/overlays/<env>/aws/` 의 생성 파일에 이전 값이 남아 있으면 Argo CD 가 삭제된
> 리소스를 가리키게 되므로, 7단계 렌더링을 반드시 다시 수행하고 커밋해야 합니다.
>
> - `rds_master_user_secret_arn` (`rds!db-<uuid>`)
> - `rds_app_secret_arn` (`/project/database/app-<suffix>`)
> - `rds_address` (RDS 재생성 시)
> - ALB / Target Group ARN (Terraform 관리 대상 아님 — 수동 갱신 필요)

## 1. Terraform apply 종료 확인

apply 를 실행한 터미널에서 `Apply complete!` 와 종료 코드 0 을 확인합니다.
다른 터미널에서 Terraform 명령을 **동시에 실행하지 않습니다.**

```bash
# apply 뿐 아니라 destroy 도 확인한다. 둘 중 하나라도 돌고 있으면 대기한다.
pgrep -af '[t]erraform (apply|destroy)' || echo "실행 중인 terraform 작업 없음"
ls ~/infra/.terraform.tfstate.lock.info 2>/dev/null && echo "state lock 잔존 - 대기 필요"

# output 이 비어 있으면 인프라가 없는 상태다.
terraform -chdir=~/infra output -json | jq -e 'length > 0' >/dev/null \
  && echo "Terraform state 에 리소스 있음" \
  || echo "Terraform output 비어 있음 - apply 필요"
```

프로세스나 lock 이 남아 있으면 이후 단계를 시작하지 않습니다.

---

## 2. 코드 및 작업트리 확인

```bash
git -C ~/infra  status --short --branch
git -C ~/gitops status --short --branch
git -C ~/infra  log -1 --oneline --decorate
git -C ~/gitops log -1 --oneline --decorate
```

양쪽 모두 `dev` 이고 `origin/dev` 와 동기 상태여야 합니다. 예상하지 않은 미커밋
변경이 있으면 중단하고 원인을 먼저 확인합니다.

`terraform.tfvars`, `.terraform/`, `tfplan`, `*.tfstate` 는 Git 에 추가하지 않습니다
(`.gitignore` 에 이미 포함).

---

## 3. Terraform 정적 검증 및 output 확인

```bash
terraform -chdir=~/infra fmt -check -recursive
terraform -chdir=~/infra validate

terraform -chdir=~/infra output -json | jq -e '
  [
    .aws_account_id.value, .aws_region.value, .eks_cluster_name.value,
    .rds_address.value, .rds_port.value, .rds_bootstrap_db_name.value,
    .rds_master_user_secret_arn.value, .rds_app_secret_arn.value,
    .rds_app_db_username.value, .ecr_registry.value
  ] | all(. != null and . != "")
' >/dev/null && echo "필수 output 모두 존재"
```

### 자격 증명 분리 확인 (가장 중요)

```bash
MASTER_SECRET_ARN="$(terraform -chdir=~/infra output -raw rds_master_user_secret_arn)"
APP_SECRET_ARN="$(terraform -chdir=~/infra output -raw rds_app_secret_arn)"
test "$MASTER_SECRET_ARN" != "$APP_SECRET_ARN" && echo "master / app secret 분리 확인"
unset MASTER_SECRET_ARN APP_SECRET_ARN
```

이 `test` 가 실패하면 애플리케이션이 master 자격 증명을 쓰게 되므로 **즉시 중단**합니다.

---

## 4. AWS 인프라 준비 상태 확인

```bash
CLUSTER_NAME="$(terraform -chdir=~/infra output -raw eks_cluster_name)"
AWS_REGION="$(terraform -chdir=~/infra output -raw aws_region)"
AWS_ACCOUNT_ID="$(terraform -chdir=~/infra output -raw aws_account_id)"
RDS_ADDRESS="$(terraform -chdir=~/infra output -raw rds_address)"

test "$(aws sts get-caller-identity --query Account --output text)" = "$AWS_ACCOUNT_ID"

aws eks describe-cluster --name "$CLUSTER_NAME" --region "$AWS_REGION" \
  --query 'cluster.{name:name,status:status,version:version}' --output table

test "$(aws eks describe-cluster --name "$CLUSTER_NAME" --region "$AWS_REGION" \
  --query 'cluster.status' --output text)" = "ACTIVE"

for addon in vpc-cni coredns kube-proxy aws-ebs-csi-driver \
             eks-pod-identity-agent aws-secrets-store-csi-driver-provider; do
  status="$(aws eks describe-addon --cluster-name "$CLUSTER_NAME" \
    --addon-name "$addon" --region "$AWS_REGION" \
    --query 'addon.status' --output text)"
  printf '%-48s %s\n' "$addon" "$status"
  test "$status" = "ACTIVE"
done

aws rds describe-db-instances --region "$AWS_REGION" \
  --query "DBInstances[?Endpoint.Address=='$RDS_ADDRESS'].{id:DBInstanceIdentifier,status:DBInstanceStatus}" \
  --output table
```

Secret 은 **메타데이터만** 확인합니다. 값은 읽지 않습니다.

```bash
for arn in "$(terraform -chdir=~/infra output -raw rds_app_secret_arn)" \
           "$(terraform -chdir=~/infra output -raw rds_master_user_secret_arn)"; do
  aws secretsmanager describe-secret --secret-id "$arn" --region "$AWS_REGION" \
    --query '{name:Name,arn:ARN}' --output table
done
```

RDS 가 `available` 이 아니거나 add-on 중 하나라도 `ACTIVE` 가 아니면 bootstrap 을
시작하지 않습니다.

> **주의: `aws-secrets-store-csi-driver-provider` add-on 은 AWS *provider* 만 설치합니다.**
> `SecretProviderClass` CRD 를 제공하는 CSI **driver** 본체는 이 저장소의
> `argocd/platform/secrets-store-csi-driver.yaml` 이 Argo CD 로 설치합니다(sync-wave `-5`).
> 따라서 8단계 이전에는 해당 CRD 가 없는 것이 정상입니다.

---

## 5. kubeconfig 연결 및 노드 확인

```bash
aws eks update-kubeconfig --name "$CLUSTER_NAME" --region "$AWS_REGION"
kubectl cluster-info
kubectl get nodes -o wide
kubectl wait --for=condition=Ready nodes --all --timeout=10m
```

---

## 6. GitOps dry-run

임시 디렉터리에서 렌더링·가드·Kustomize 검증만 수행하며 저장소와 클러스터를
변경하지 않습니다.

```bash
cd ~/gitops
./scripts/bootstrap-eks.sh --infra-dir ~/infra --environment dev --dry-run
```

다음이 모두 통과해야 합니다.

- Terraform output 필수값 존재 (null/빈 값 차단)
- AWS 계정과 Terraform account ID 일치
- **master secret ARN ≠ app secret ARN**
- Terraform 관리 대상이 아닌 입력값(`INGRESS_HOST` / `ACM_CERTIFICATE_ARN` /
  `ALB_SSL_POLICY` / `ARGOCD_TARGET_GROUP_ARN`) 형식·소유 계정·**실재 여부** 검증
  - ACM 인증서는 `ISSUED` 상태여야 하고, Target Group 은 실제로 존재해야 합니다.
  - 환경을 destroy 후 재생성하면 **Target Group ARN 이 바뀝니다.** 이전 값이 남아
    있으면 여기서 중단되므로, 새 ARN 으로 갱신하거나 Argo CD 를 ALB 에 붙이지 않을
    경우 `ARGOCD_TARGET_GROUP_ARN=` 으로 비웁니다.
- placeholder(`__BOOTSTRAP_PENDING__`) 없음
- 이전 환경의 계정 ID / RDS endpoint 없음
- **master ARN 이 db-bootstrap SecretProviderClass 한 곳에서만 참조**
- `k8s/overlays/dev/aws`, `argocd/`, `bootstrap/` Kustomize build 성공

---

## 7. 환경값 렌더링 및 Git 반영

```bash
cd ~/gitops
./scripts/bootstrap-eks.sh --infra-dir ~/infra --environment dev --render

git status --short
git diff --check
git diff -- k8s argocd bootstrap environments
```

diff 에 비밀번호·PAT·private key 가 없어야 합니다. 생성 파일은 모두
`# GENERATED FILE - do not edit manually.` 로 시작합니다.

```bash
git add k8s argocd bootstrap environments
git diff --cached --check
git commit -m "chore(gitops): render dev/aws from terraform output"
git push origin dev
git status --short --branch
```

`nothing to commit` 이면 이미 렌더 결과가 반영된 상태이므로 다음 단계로 진행합니다.

> **생성 파일을 손으로 고치지 마세요.** ALB TLS 정책처럼 조정이 필요한 값은
> `environments/dev/aws.env` 에 입력값으로 추가해야 다음 렌더링에서 유실되지 않습니다.
> (예: `ALB_SSL_POLICY`)

---

## 8. Argo CD private 저장소 인증 등록

최초 한 번만 실행합니다. 프롬프트에 GitHub PAT 를 입력합니다(화면에 표시되지 않음).

```bash
cd ~/gitops
./scripts/register-repo-credentials.sh

kubectl -n argocd get secret -l argocd.argoproj.io/secret-type=repository \
  -o custom-columns=NAME:.metadata.name,CREATED:.metadata.creationTimestamp
```

Secret 데이터를 `-o yaml` / `-o json` 으로 출력하지 않습니다.

> Argo CD 가 아직 설치되지 않아 `argocd` 네임스페이스가 없어도 됩니다.
> 스크립트가 네임스페이스를 먼저 만듭니다.

---

## 9. Argo CD 및 워크로드 bootstrap

```bash
cd ~/gitops
./scripts/bootstrap-eks.sh --infra-dir ~/infra --environment dev --apply --timeout 1200
```

동작 순서:

1. Terraform output 재검증 및 매니페스트 렌더링
2. Git working tree clean + `origin/dev` 푸시 상태 확인 (미푸시면 중단)
3. kubeconfig 갱신, EKS API 연결, ALB Controller CRD 확인
4. Argo CD Helm 설치 (`bootstrap/argocd/values.yaml`)
5. `bootstrap/root-application.yaml` 적용
6. Argo CD 가 `argocd/` 동기화: AppProject(`-20`) → platform controller(`-5`) → ApplicationSet(`0`)
7. workload Application 동기화 중 db-bootstrap Job(Sync hook, wave `-2`) 실행
8. `bank-app-aws-dev` 가 `Synced/Healthy` 가 될 때까지 대기

운영 옵션: `--skip-wait`, `--timeout SECONDS`, `--skip-argocd-install`.

---

## 10. 전체 배포 검증

```bash
kubectl get nodes
kubectl -n argocd get applications \
  -o custom-columns=NAME:.metadata.name,SYNC:.status.sync.status,HEALTH:.status.health.status

kubectl -n kube-system get pods -l app.kubernetes.io/name=secrets-store-csi-driver
kubectl get crd | grep -E 'argoproj|secrets-store|elbv2'

kubectl -n bank-of-anthos get serviceaccount,secretproviderclass
kubectl -n bank-of-anthos get job db-bootstrap
kubectl -n bank-of-anthos wait --for=condition=complete job/db-bootstrap --timeout=10m
kubectl -n bank-of-anthos logs job/db-bootstrap

kubectl -n bank-of-anthos rollout status deploy --all --timeout=10m
kubectl -n bank-of-anthos get pods -o wide
kubectl -n bank-of-anthos get svc,ingress
```

`db-bootstrap` 로그에는 단계별 진행만 출력되며 비밀번호는 나오지 않습니다.

---

## 11. 자격 증명 경계 검증

Secret 값을 출력하지 않는 검증입니다.

```bash
APP_SECRET_ARN="$(terraform -chdir=~/infra output -raw rds_app_secret_arn)"
MASTER_SECRET_ARN="$(terraform -chdir=~/infra output -raw rds_master_user_secret_arn)"

test "$APP_SECRET_ARN" != "$MASTER_SECRET_ARN"

# 앱 SPC 에 app secret 은 있고 master 는 없어야 한다
kubectl -n bank-of-anthos get secretproviderclass bank-of-anthos-secrets -o json \
  | jq -e --arg a "$APP_SECRET_ARN" '.spec.parameters.objects | contains($a)' >/dev/null
kubectl -n bank-of-anthos get secretproviderclass bank-of-anthos-secrets -o json \
  | jq -e --arg m "$MASTER_SECRET_ARN" '.spec.parameters.objects | contains($m) | not' >/dev/null
echo "앱 SPC: app secret 만 참조"

# bootstrap SPC 는 master 를 쓰되 Kubernetes Secret 으로 동기화하지 않는다
kubectl -n bank-of-anthos get secretproviderclass bank-of-anthos-db-bootstrap-secrets -o json \
  | jq -e --arg m "$MASTER_SECRET_ARN" '.spec.parameters.objects | contains($m)' >/dev/null
kubectl -n bank-of-anthos get secretproviderclass bank-of-anthos-db-bootstrap-secrets -o json \
  | jq -e '.spec | has("secretObjects") | not' >/dev/null
echo "bootstrap SPC: master 참조, k8s Secret 미동기화"

# ServiceAccount 분리
kubectl -n bank-of-anthos get deploy -o json \
  | jq -e '[.items[].spec.template.spec.serviceAccountName] | unique == ["bank-of-anthos"]' >/dev/null
test "$(kubectl -n bank-of-anthos get job db-bootstrap \
  -o jsonpath='{.spec.template.spec.serviceAccountName}')" = "bank-of-anthos-db-bootstrap"
echo "ServiceAccount 분리 확인"

# db-secret 은 key 존재만 확인한다 (base64 데이터·decode 출력 금지)
kubectl -n bank-of-anthos get secret db-secret -o json \
  | jq -e '.data | has("username") and has("password")' >/dev/null
echo "db-secret key 확인"

unset APP_SECRET_ARN MASTER_SECRET_ARN
```

Pod Identity 경계:

```bash
aws eks list-pod-identity-associations --cluster-name "$CLUSTER_NAME" --region "$AWS_REGION" \
  --query 'associations[].{ns:namespace,sa:serviceAccount,role:roleArn}' --output table
```

`bank-of-anthos / bank-of-anthos` 와 `bank-of-anthos / bank-of-anthos-db-bootstrap` 이
**서로 다른 Role ARN** 으로 보여야 합니다.

IAM 정책 확인 (앱 Role 에 `rds!db-*` 가 없어야 함):

```bash
aws iam get-policy-version \
  --policy-arn "arn:aws:iam::${AWS_ACCOUNT_ID}:policy/bank-of-anthos-app-secrets" \
  --version-id v1 --query 'PolicyVersion.Document.Statement[].Resource' --output json \
  | grep -q 'rds!db-' && echo "FAIL: 앱 정책에 master secret 접근" || echo "앱 정책: master secret 접근 없음"
```

---

## 12. 외부 접속 검증

```bash
ALB_HOST="$(kubectl -n bank-of-anthos get ingress project-ingress \
  -o jsonpath='{.status.loadBalancer.ingress[0].hostname}')"
echo "ALB: $ALB_HOST"
```

> **DNS 재지정이 필요합니다.**
> `app.bespinglobal.site` 의 A/AAAA alias 레코드는 이전 클러스터의 ALB 를 가리키고
> 있습니다. 새 ALB 가 생성되면 hostname 이 바뀌므로 Route 53 레코드를 갱신해야
> HTTPS 검증이 통과합니다.

```bash
aws route53 list-resource-record-sets --hosted-zone-id Z03791674GY6T60MVQ4V \
  --query "ResourceRecordSets[?starts_with(Name,'app.')].[Name,Type,AliasTarget.DNSName]" \
  --output text
```

현재 레코드의 대상이 위 `$ALB_HOST` 와 다르면 Route 53 에서 alias 대상을 새 ALB 로
변경합니다(콘솔 또는 `change-resource-record-sets`). 전파 후:

```bash
curl -fsSI --retry 12 --retry-delay 10 "https://app.bespinglobal.site/" | head -n 5
```

DNS 전파 전에는 ALB hostname 으로 먼저 확인할 수 있습니다.

```bash
curl -fsSI --retry 6 --retry-delay 10 "http://${ALB_HOST}/" | head -n 5
```

HTTPS 가 실패하면 ACM 인증서가 `ISSUED` 이고 Ingress annotation 의 ARN 과 일치하는지
확인합니다.

```bash
CERT_ARN="$(kubectl -n bank-of-anthos get ingress project-ingress \
  -o jsonpath='{.metadata.annotations.alb\.ingress\.kubernetes\.io/certificate-arn}')"
echo "Ingress certificate-arn: $CERT_ARN"

aws acm describe-certificate --region "$AWS_REGION" --certificate-arn "$CERT_ARN" \
  --query 'Certificate.{domain:DomainName,status:Status,inUse:InUseBy[0]}' --output table
```

---

## 13. 실패 시 진단

```bash
kubectl -n argocd get applications,applicationsets,appprojects
kubectl -n argocd describe application bank-app-root
kubectl -n argocd describe application bank-app-aws-dev

kubectl -n bank-of-anthos get events --sort-by='.lastTimestamp' | tail -n 80
kubectl -n bank-of-anthos describe job db-bootstrap
kubectl -n bank-of-anthos logs job/db-bootstrap --all-containers=true

kubectl -n bank-of-anthos describe pod "$(kubectl -n bank-of-anthos get pods -o name | head -n 1)"
kubectl -n kube-system get pods,daemonset
kubectl get crd | grep -E 'argoproj|secrets-store|elbv2'
```

### 증상별 우선 확인

| 증상 | 확인 |
| --- | --- |
| Pod 가 `ContainerCreating` 에서 멈춤 | CSI 마운트 실패. `describe pod` 의 이벤트, Pod Identity association, Secret ARN |
| `db-bootstrap` 실패 | RDS 보안그룹 5432 인바운드, NetworkPolicy egress, `PGSSLMODE=require` |
| Application 이 `Unknown`/`ComparisonError` | repository secret 미등록 또는 PAT 권한 |
| Ingress 에 ALB hostname 미할당 | AWS Load Balancer Controller 미설치 (infra 소유) |
| `SecretProviderClass` CRD 없음 | `secrets-store-csi-driver` Application sync 상태 |

### 금지 사항

오류가 나도 아래로 우회하지 않습니다. 원인을 확인하고 코드·Terraform 으로 고칩니다.

- `--allow-dirty` 로 Git 확인 건너뛰기
- Secret 값 출력 / decode
- IAM 정책에 wildcard 추가
- 앱 SecretProviderClass 에 master ARN 복원
- 생성 파일 직접 수정

---

## 14. 완료 기준

- [ ] EKS cluster `ACTIVE`, managed node `Ready`
- [ ] 필수 EKS managed add-on 6개 모두 `ACTIVE`
- [ ] RDS `available`
- [ ] Argo CD Application 전부 `Synced/Healthy`
- [ ] `secrets-store-csi-driver` 및 AWS provider 정상 실행
- [ ] `db-bootstrap` Job `Complete`
- [ ] 애플리케이션 Deployment rollout 완료, Pod `Running`/`Ready`
- [ ] 앱 Pod 는 `bank-of-anthos` SA 만 사용
- [ ] bootstrap Job 은 `bank-of-anthos-db-bootstrap` SA 사용
- [ ] 앱 SPC 에 app secret 만, master secret 없음
- [ ] bootstrap SPC 는 master 사용하되 k8s Secret 미동기화
- [ ] `db-secret` 에 `username` / `password` key 존재
- [ ] Ingress 에 ALB hostname 할당
- [ ] Route 53 레코드가 신규 ALB 를 가리킴
- [ ] `https://app.bespinglobal.site/` 응답 성공
