# Dev EKS/GKE 최초 구축 런북 (Valkey 제외)

## 범위와 순서

이 문서는 `Infra/dev`와 `gitops/dev`만 사용해 AWS/GCP 개발 환경을 새로 올린다.
`aws-cache`, GCP Valkey root와 Valkey 관련 기능 브랜치는 적용하지 않는다. VPN/DMS는
클러스터 기동에 필요하지 않으므로 이 런북의 범위에서 제외한다.

순서는 고정한다.

1. Terraform으로 AWS와 GCP의 core, DB, ops, cluster root 적용
2. EKS와 GKE에 Argo CD와 필수 선행 구성 설치
3. Terraform 런타임 값을 GitOps YAML에 반영하고 `gitops/dev`에 한 번만 push
4. 두 Root Application을 적용해 Argo CD가 워크로드를 배포

Argo CD를 설치하기 전에는 GitOps 변경을 push하지 않는다. Root Application을 적용하기
전에는 앱 매니페스트를 `kubectl apply`하지 않는다.

## 1. 실행 환경과 저장소 확인

Linux 코드 서버에서 두 저장소의 상위 디렉터리로 이동한다.

```bash
cd ~/work-dir

git -C Infra fetch origin
git -C Infra switch dev
git -C Infra pull --ff-only origin dev

git -C gitops fetch origin
git -C gitops switch dev
git -C gitops pull --ff-only origin dev

test -z "$(git -C Infra status --porcelain)"
test -z "$(git -C gitops status --porcelain)"
```

필수 도구와 AWS 계정을 확인한다.

```bash
for tool in aws gcloud terraform kubectl helm git openssl curl jq; do
  command -v "$tool" >/dev/null || exit 1
done

export AWS_REGION=ap-northeast-2
if aws configure list-profiles | grep -Fxq team1; then
  export AWS_PROFILE=team1
else
  unset AWS_PROFILE
fi
test "$(aws sts get-caller-identity --query Account --output text)" = "769413326616"
gcloud auth application-default print-access-token >/dev/null
gcloud config set project kdt4-1-506106
test "$(gcloud config get-value project)" = "kdt4-1-506106"
terraform version
```

Terraform은 `1.11.0` 이상이어야 한다. GCP 결제와 필요한 API가 활성화돼 있어야 하며,
Backend 버킷 `s3://boa-terraform-state-6416`도 먼저 존재해야 한다.

## 2. 코드 검증

```bash
terraform -chdir=Infra fmt -recursive -check

for root in \
  aws-core aws-rds aws-ops aws-eks aws-db-bootstrap \
  gcp-core gcp-cloudsql gcp-ops gcp-gke; do
  terraform -chdir="Infra/$root" init -backend=false -input=false
  terraform -chdir="Infra/$root" validate
done

# 반복 구축에 필요한 GCP 수정이 Infra/dev에 들어왔는지 확인한다.
grep -q 'edition.*=.*"ENTERPRISE"' Infra/gcp-modules/cloudsql/main.tf
grep -q 'secret_sync_config' Infra/gcp-modules/gke/main.tf
grep -q 'total_min_node_count' Infra/gcp-modules/gke/main.tf

for dir in $(find gitops -name kustomization.yaml -printf '%h\n' | sort -u); do
  kubectl kustomize "$dir" >/dev/null
done
```

## 3. Terraform apply

모든 plan을 읽고 `destroy`, 예상하지 않은 교체 또는 대량 변경이 없을 때만 apply한다.

```bash
apply_root() {
  root=$1
  plan="/tmp/boa-${root}.tfplan"
  terraform -chdir="Infra/$root" init -reconfigure -input=false
  terraform -chdir="Infra/$root" plan -lock-timeout=5m -out="$plan"
  terraform -chdir="Infra/$root" show -no-color "$plan"
  terraform -chdir="Infra/$root" apply "$plan"
}
```

### 3.1 AWS

```bash

apply_root aws-core
apply_root aws-rds
apply_root aws-ops
```

EKS API에는 현재 코드 서버의 공인 IP만 허용한다.

```bash
OPERATOR_IP=$(curl -fsS https://checkip.amazonaws.com | tr -d '[:space:]')
[[ "$OPERATOR_IP" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]]
export TF_VAR_public_access_cidrs="[\"${OPERATOR_IP}/32\"]"
```

클러스터 재생성 전부터 JWT Secret 컨테이너를 보존했다면 EKS state에 먼저 채택한다.
이미 state에 있거나 AWS에도 없으면 아무 작업도 하지 않는다.

```bash
terraform -chdir=Infra/aws-eks init -reconfigure -input=false

adopt_secret() {
  root=$1 resource=$2 name=$3
  terraform -chdir="$root" state list | grep -Fxq "$resource" && return 0
  arn=$(aws secretsmanager describe-secret --secret-id "$name" --query ARN --output text 2>/dev/null || true)
  [[ -z "$arn" || "$arn" = None ]] || terraform -chdir="$root" import "$resource" "$arn"
}

adopt_secret Infra/aws-eks \
  'module.eks.aws_secretsmanager_secret.jwt_public' '/boa/jwt/public'
adopt_secret Infra/aws-eks \
  'module.eks.aws_secretsmanager_secret.jwt_private' '/boa/jwt/private'

apply_root aws-eks
```

DB Secret도 삭제 예약 상태면 복구한 뒤 state에 채택한다.

```bash
terraform -chdir=Infra/aws-db-bootstrap init -reconfigure -input=false

adopt_db_secret() {
  resource=$1 name=$2
  terraform -chdir=Infra/aws-db-bootstrap state list | grep -Fxq "$resource" && return 0
  info=$(aws secretsmanager describe-secret --secret-id "$name" --output json 2>/dev/null || true)
  [[ -n "$info" ]] || return 0
  arn=$(jq -r .ARN <<<"$info")
  [[ $(jq -r '.DeletedDate // empty' <<<"$info") = "" ]] || \
    aws secretsmanager restore-secret --secret-id "$arn" >/dev/null
  terraform -chdir=Infra/aws-db-bootstrap import "$resource" "$arn"
}

adopt_db_secret aws_secretsmanager_secret.app_database /boa/database/app
adopt_db_secret aws_secretsmanager_secret.accounts_database /boa/database/accounts
adopt_db_secret aws_secretsmanager_secret.ledger_database /boa/database/ledger

apply_root aws-db-bootstrap
```

### 3.2 GCP

GCP 변수는 파일에 저장하지 않고 현재 셸에서만 넘긴다. `dms_password`는 Cloud SQL의
`dms_writer` 계정 생성에 필요하지만 화면이나 Git에 출력하지 않는다.

```bash
export TF_VAR_gcp_project_id=kdt4-1-506106
export TF_VAR_region=asia-northeast2

read -rs -p 'GCP DMS password: ' TF_VAR_dms_password; echo
export TF_VAR_dms_password

GCP_OPERATOR_IP=$(curl -fsS https://checkip.amazonaws.com | tr -d '[:space:]')
[[ "$GCP_OPERATOR_IP" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]]
export TF_VAR_master_authorized_cidrs='[{"cidr_block":"'"$GCP_OPERATOR_IP"'/32","display_name":"code-server"}]'

apply_root gcp-core

# destroy 뒤에도 보존한 Secret Manager 컨테이너는 삭제하지 말고 state에 채택한다.
terraform -chdir=Infra/gcp-cloudsql init -reconfigure -input=false
adopt_gcp_secret() {
  resource=$1 name=$2
  terraform -chdir=Infra/gcp-cloudsql state list | grep -Fxq "$resource" && return 0
  gcloud secrets describe "$name" --project="$TF_VAR_gcp_project_id" >/dev/null 2>&1 || return 0
  terraform -chdir=Infra/gcp-cloudsql import "$resource" \
    "projects/$TF_VAR_gcp_project_id/secrets/$name"
}
adopt_gcp_secret 'google_secret_manager_secret.app_database["accounts"]' boa-database-accounts
adopt_gcp_secret 'google_secret_manager_secret.app_database["ledger"]' boa-database-ledger

apply_root gcp-cloudsql
apply_root gcp-ops
apply_root gcp-gke

unset TF_VAR_dms_password
```

현재 `gitops/dev`에는 GCP DB 권한 bootstrap Job이 없다. Cloud SQL을 새로 만들었다면
Root Application 적용 전에 GCP Console의 Cloud SQL Studio에서 `accountsdb`와
`ledgerdb`를 각각 선택하고 `Infra/docs/GCP_CLOUDSQL_USER_GRANTS.sql`을 실행한다.
기존 Cloud SQL과 권한을 유지한 재구축이면 이 단계는 생략한다.

이 런북에서는 `aws-cache`, GCP Valkey root, `net-link`, `aws-dms`를 실행하지 않는다.

### 3.3 GCP 재구축 오류 복구

`gcp-core`가 기존 PSA 연결의 예전 range 이름 때문에 `Cannot modify allocated ranges`
오류로 끝났다면 새 Terraform range를 기존 연결에 붙이고 state에 채택한다.

```bash
gcloud services vpc-peerings update \
  --network=boa-vpc \
  --ranges=boa-psa-range \
  --service=servicenetworking.googleapis.com \
  --project=kdt4-1-506106 \
  --force

terraform -chdir=Infra/gcp-core import \
  'module.network.google_service_networking_connection.psa' \
  'projects/kdt4-1-506106/global/networks/boa-vpc:servicenetworking.googleapis.com'

apply_root gcp-core
```

Cloud SQL plan에는 `settings.edition = "ENTERPRISE"`가 있어야 한다. PostgreSQL 16의
기본값인 Enterprise Plus는 `db-custom-1-3840`을 허용하지 않는다. 기존
`boa-database-accounts`, `boa-database-ledger`가 409를 내면 삭제하지 말고 위의
`adopt_gcp_secret`으로 import한다.

## 4. Argo CD 선설치

### 4.1 EKS

```bash
aws eks update-kubeconfig --name boa-eks --region "$AWS_REGION"
EKS_CONTEXT=$(kubectl config current-context)
kubectl wait node --all --for=condition=Ready --timeout=10m
kubectl -n kube-system rollout status deployment/aws-load-balancer-controller --timeout=10m
```

Terraform 출력으로 Argo CD TargetGroupBinding과 RDS master Secret ARN을 갱신한다.
`--gitops`가 `03_manifests/eks/shared/secrets.yaml`도 함께 갱신한다.

```bash
bash gitops/02_scripts/render-aws-runtime.sh \
  --infra-root "$PWD/Infra" \
  --gitops
```

JWT 값, Metrics Server, Argo CD를 준비한다. 앱은 아직 배포하지 않는다.

```bash
bash gitops/02_scripts/prepare-jwt.sh

helm repo add metrics-server https://kubernetes-sigs.github.io/metrics-server/ --force-update
helm upgrade --install metrics-server metrics-server/metrics-server \
  -n kube-system --wait --timeout 10m

bash gitops/02_scripts/install-argocd.sh
kubectl apply -f gitops/manual/eks/argocd-exposure/targetgroupbinding.yaml

kubectl -n argocd rollout status deployment/argocd-server --timeout=10m
test -z "$(kubectl -n argocd get applications -o name 2>/dev/null)"
```

비공개 Git 저장소 읽기 자격 증명을 등록한다. PAT에는 GitOps 저장소의
`Contents: Read-only` 권한만 부여한다.

```bash
export ARGOCD_REPO_USERNAME='<github-user>'
read -rs ARGOCD_REPO_PASSWORD
export ARGOCD_REPO_PASSWORD

kubectl -n argocd create secret generic gitops-repo \
  --from-literal=type=git \
  --from-literal=url=https://github.com/AWS-Team1/gitops.git \
  --from-literal=username="$ARGOCD_REPO_USERNAME" \
  --from-literal=password="$ARGOCD_REPO_PASSWORD" \
  --dry-run=client -o yaml | kubectl apply -f -
kubectl -n argocd label secret gitops-repo \
  argocd.argoproj.io/secret-type=repository --overwrite
```

### 4.2 GKE

GKE context로 전환한 뒤 JWT를 준비하고 GKE용 Helm 값과 고정 IP Ingress를 적용한다.
이 단계도 Root Application은 만들지 않는다.

```bash
gcloud container clusters get-credentials boa-gke \
  --region asia-northeast2 \
  --project kdt4-1-506106
GKE_CONTEXT=$(kubectl config current-context)

kubectl wait node --all --for=condition=Ready --timeout=10m
kubectl wait --for=condition=Established \
  crd/secretsyncs.secret-sync.gke.io --timeout=5m

GCP_PROJECT_ID=kdt4-1-506106 bash gitops/02_scripts/prepare-jwt-gcp.sh
ARGOCD_PLATFORM_VALUES_FILE="$PWD/gitops/01_bootstrap/argocd-values-gke.yaml" \
  bash gitops/02_scripts/install-argocd.sh
kubectl apply -f gitops/01_bootstrap/argocd-exposure-gke.yaml

kubectl -n argocd rollout status deployment/argocd-server --timeout=10m
test -z "$(kubectl -n argocd get applications -o name 2>/dev/null)"

kubectl -n argocd create secret generic gitops-repo \
  --from-literal=type=git \
  --from-literal=url=https://github.com/AWS-Team1/gitops.git \
  --from-literal=username="$ARGOCD_REPO_USERNAME" \
  --from-literal=password="$ARGOCD_REPO_PASSWORD" \
  --dry-run=client -o yaml | kubectl apply -f -
kubectl -n argocd label secret gitops-repo \
  argocd.argoproj.io/secret-type=repository --overwrite
```

## 5. GitOps 검증 후 dev push

push 대상은 Terraform 런타임 값이 바뀐 아래 세 파일뿐이다.

```bash
git -C gitops diff -- \
  manual/eks/argocd-exposure/targetgroupbinding.yaml \
  manual/eks/secrets.yaml \
  03_manifests/eks/shared/secrets.yaml

git -C gitops diff --check
kubectl kustomize gitops/manual/eks >/dev/null
kubectl kustomize gitops/03_manifests/eks >/dev/null
kubectl kustomize gitops/03_manifests/eks/applications >/dev/null
kubectl kustomize gitops/03_manifests/gke >/dev/null
kubectl kustomize gitops/03_manifests/gke/applications >/dev/null

git -C gitops add \
  manual/eks/argocd-exposure/targetgroupbinding.yaml \
  manual/eks/secrets.yaml \
  03_manifests/eks/shared/secrets.yaml
git -C gitops commit -m "chore: refresh dev AWS runtime values"
git -C gitops push origin dev
```

변경이 하나도 없으면 commit/push는 생략한다. Argo CD는 이미 설치됐지만 Root
Application이 아직 없으므로 이 push만으로 워크로드가 배포되지는 않는다.

## 6. Root Application 적용과 클러스터 기동

```bash
wait_argocd() {
  for _ in {1..90}; do
    [[ $(kubectl -n argocd get applications --no-headers 2>/dev/null | wc -l) -eq 5 ]] && break
    sleep 10
  done
  kubectl -n argocd wait applications --all \
    --for=jsonpath='{.status.sync.status}'=Synced --timeout=15m
  kubectl -n argocd wait applications --all \
    --for=jsonpath='{.status.health.status}'=Healthy --timeout=15m
}

kubectl config use-context "$EKS_CONTEXT"
kubectl apply -f gitops/01_bootstrap/root-application-eks.yaml
wait_argocd

kubectl config use-context "$GKE_CONTEXT"
kubectl apply -f gitops/01_bootstrap/root-application-gke.yaml
wait_argocd
```

## 7. 최종 검증

### 7.1 EKS

```bash
kubectl config use-context "$EKS_CONTEXT"
kubectl -n argocd get applications
kubectl -n bank-of-anthos get deploy,hpa,pod
kubectl -n bank-of-anthos wait deployment --all \
  --for=condition=Available --timeout=15m
kubectl -n bank-of-anthos wait job/db-bootstrap \
  --for=condition=Complete --timeout=10m
kubectl -n bank-of-anthos get secret accounts-db-secret ledger-db-secret bank-app-jwt

terraform -chdir=Infra/aws-core plan -detailed-exitcode
terraform -chdir=Infra/aws-rds plan -detailed-exitcode
terraform -chdir=Infra/aws-ops plan -detailed-exitcode
terraform -chdir=Infra/aws-eks plan -detailed-exitcode
terraform -chdir=Infra/aws-db-bootstrap plan -detailed-exitcode
```

Frontend ALB가 생성됐는지도 확인한다.

```bash
kubectl -n bank-of-anthos get ingress boa-ingress
kubectl -n argocd get targetgroupbinding argocd-server
terraform -chdir=Infra/aws-ops output -raw argocd_url
```

### 7.2 GKE

```bash
kubectl config use-context "$GKE_CONTEXT"
kubectl -n argocd get applications
kubectl -n bank-of-anthos get deploy,pod
kubectl -n bank-of-anthos wait deployment --all \
  --for=condition=Available --timeout=15m
test -z "$(kubectl -n bank-of-anthos get hpa -o name)"
kubectl -n bank-of-anthos get secret accounts-db-secret ledger-db-secret bank-app-jwt
kubectl -n bank-of-anthos get ingress boa-ingress
kubectl -n argocd get ingress argocd-gcp
kubectl -n argocd get managedcertificate argocd-gcp

terraform -chdir=Infra/gcp-core plan -detailed-exitcode
read -rs -p 'GCP DMS password: ' TF_VAR_dms_password; echo
export TF_VAR_dms_password
terraform -chdir=Infra/gcp-cloudsql plan -detailed-exitcode
unset TF_VAR_dms_password
terraform -chdir=Infra/gcp-ops plan -detailed-exitcode
terraform -chdir=Infra/gcp-gke plan -detailed-exitcode
```

Terraform의 정상 종료 코드는 변경 없음일 때 `0`, 변경이 남았을 때 `2`다. 마지막 plan에서
`2`가 나오면 내용을 확인하고, 바로 추가 apply하지 않는다.

## 8. 코드 서버 단절 시 로컬 복구

apply 중 SSH가 끊겨도 같은 root를 바로 다시 실행하지 않는다. 먼저 기존 Terraform
프로세스와 실제 클라우드 작업 상태를 확인한다. 프로세스가 살아 있으면 기다린다.

```bash
pgrep -af 'terraform.*gcp-gke'
gcloud container clusters describe boa-gke \
  --region asia-northeast2 \
  --project kdt4-1-506106 \
  --format='yaml(name,status,endpoint)'
```

코드 서버를 재부팅했거나 프로세스 종료를 확인한 뒤에만 오류에 표시된 lock ID를
해제한다. 클러스터와 서비스 계정은 생성됐지만 state가 비었다면 두 리소스를 먼저
import하고 plan으로 나머지만 생성한다.

```bash
terraform -chdir=Infra/gcp-gke force-unlock -force '<LOCK_ID>'
terraform -chdir=Infra/gcp-gke import google_service_account.gke_node \
  'projects/kdt4-1-506106/serviceAccounts/boa-gke-node@kdt4-1-506106.iam.gserviceaccount.com'
terraform -chdir=Infra/gcp-gke import module.gke.google_container_cluster.main \
  'projects/kdt4-1-506106/locations/asia-northeast2/clusters/boa-gke'
apply_root gcp-gke
```

Windows PowerShell에서 인계받을 때는 Bash의 `export`, `\` 줄 연장, `/tmp` 경로를
사용하지 않는다.

```powershell
gcloud auth login ba016@bespin.email --force --update-adc
$env:AWS_PROFILE='team1'
$env:TF_VAR_gcp_project_id='kdt4-1-506106'
$env:TF_VAR_region='asia-northeast2'
$operatorIp=(Invoke-RestMethod 'https://checkip.amazonaws.com').Trim()
$env:TF_VAR_master_authorized_cidrs='[{"cidr_block":"' + $operatorIp + '/32","display_name":"operator"}]'
```

GKE 생성 후 `secretsyncs.secret-sync.gke.io` CRD가 없다면 Infra 코드의
`secret_sync_config`가 빠진 것이다. Root Application을 적용하지 말고 먼저 Terraform
코드를 고친 뒤 `No changes`까지 확인한다. 리전 노드풀이 3대로 시작하면 autoscaling이
`min_node_count`가 아니라 `total_min_node_count`를 사용하는지도 확인한다.

## 실패 시 중단 기준

- AWS Account가 `769413326616`이 아님
- GCP Project가 `kdt4-1-506106`이 아님
- plan에 Valkey, 의도하지 않은 destroy 또는 교체가 포함됨
- 현재 공인 IP `/32`가 아닌 넓은 EKS/GKE API 허용 CIDR이 잡힘
- Argo CD 설치 전에 GitOps runtime 값을 push함
- Root Application 적용 전에 워크로드를 직접 `kubectl apply`함
- 어느 클러스터든 Application 5개 중 하나라도 `Synced/Healthy`가 아님
