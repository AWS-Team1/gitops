# EKS 수동 배포 → Argo CD → CI/CD → HPA/Karpenter 런북

대상은 AWS Account `769413326616`, Region `ap-northeast-2`, EKS `boa-eks`다.
명령은 특별한 안내가 없으면 `final-project-dev` 상위 디렉터리에서 실행한다.

## 0. 감사 결과와 중단 조건

### Critical

- 현재 기본/`target` AWS 자격증명은 `141177383006`이다. 대상 계정으로 전환하기 전에는
  Terraform plan/apply, runtime 렌더, kubectl 작업을 실행하지 않는다.
- `boa.internal` Private Hosted Zone은 Terraform이 생성하지 않고 `aws-rds`가 조회만 한다.
  대상 VPC에 Zone이 먼저 존재해야 한다.
- `accounts`, `ledger`, `frontend` 저장소에는 CI workflow가 없다. 현재 CI/CD는 아래의
  로컬 테스트·Docker build/push·GitOps 태그 커밋 절차이며 자동 파이프라인이 아니다.

### Warning

- Root/Child Application은 `feat/manual-yaml`을 가리킨다. 다른 브랜치를 배포하면 5개 파일을
  모두 같은 원격 브랜치로 바꾸고 push해야 한다.
- 앱 Deployment 6개에는 readiness/liveness probe가 없다. `Available`만으로 실제 HTTP/DB
  동작을 판정하지 말고 이 런북의 HTTP·로그 검증까지 수행한다.
- `/boa/database/accounts`, `/boa/database/ledger` Secret은 `prevent_destroy=true`와 7일
  recovery window를 사용하므로 전체 destroy/동명 재생성은 별도 보호 해제 절차가 필요하다.
- `aws-eks`가 EKS와 Kubernetes/Helm 리소스를 한 root에서 관리한다. 첫 apply의 provider
  초기화가 실패하면 클러스터 `ACTIVE` 확인 후 같은 apply를 다시 실행한다.

### 이번 검사에서 수정한 항목

- 수동 YAML의 ECR 이름을 Terraform 소유 `boa-*` 저장소로 통일했다.
- 수동 YAML도 `accountsdb/accounts_app`, `ledgerdb/ledger_app` 분리 구조로 통일했다.
- Argo CD 검증 스크립트의 Application 기대값을 실제 구성인 5개로 수정했다.
- DB 비밀번호는 로컬 보호 파일 → Terraform write-only → Secrets Manager 흐름으로 통일했다.
- manual runtime 값은 렌더링하고 `03_manifests` 값은 직접 검토·커밋하도록 분리했다.

## 1. Terraform과 필수 도구 설치

Terraform은 write-only Secret 입력 때문에 `>= 1.11`이 필요하다. Ubuntu/Debian은
[HashiCorp 공식 설치 문서](https://developer.hashicorp.com/terraform/install)를 따른다.

```bash
wget -O - https://apt.releases.hashicorp.com/gpg |
  sudo gpg --dearmor -o /usr/share/keyrings/hashicorp-archive-keyring.gpg
echo "deb [arch=$(dpkg --print-architecture) signed-by=/usr/share/keyrings/hashicorp-archive-keyring.gpg] https://apt.releases.hashicorp.com $(grep -oP '(?<=UBUNTU_CODENAME=).*' /etc/os-release || lsb_release -cs) main" |
  sudo tee /etc/apt/sources.list.d/hashicorp.list
sudo apt update
sudo apt install -y terraform
terraform version
```

다른 필수 도구도 확인한다.

```bash
for tool in aws terraform kubectl helm git docker openssl jq curl; do
  command -v "$tool" >/dev/null || echo "MISSING: $tool"
done
test "$(terraform version -json | jq -r .terraform_version | cut -d. -f1-2)" != "1.10"
```

## 2. 계정·브랜치·외부 전제조건 확인

```bash
EXPECTED_ACCOUNT=769413326616
ACCOUNT=$(aws sts get-caller-identity --query Account --output text)
test "$ACCOUNT" = "$EXPECTED_ACCOUNT" || {
  echo "잘못된 AWS 계정: $ACCOUNT" >&2
  exit 1
}
aws configure get region
git -C Infra status --short --branch
git -C gitops status --short --branch
```

다음 외부 리소스가 있어야 한다.

```bash
aws s3api head-bucket --bucket boa-terraform-state-6416
aws ec2 describe-vpcs --vpc-ids vpc-07194d5f908bac7cf
aws ec2 describe-vpc-endpoints --vpc-endpoint-ids vpce-0853a7dfbfac3dd62
aws route53 list-hosted-zones-by-name --dns-name boa.internal
aws route53 list-hosted-zones-by-name --dns-name bespinglobal.site
aws acm list-certificates --region ap-northeast-2
```

`boa.internal`은 반드시 위 VPC에 연결된 Private Hosted Zone이어야 한다.

## 3. DB 비밀번호 파일 준비

`aws-db-bootstrap` apply 전에 세 파일을 만든다. 값은 출력하지 않는다.

```bash
for name in app accounts ledger; do
  SECRET_NAME="/boa/database/$name" \
    bash gitops/02_scripts/prepare-database-secret.sh
done

for file in ~/.cache/boa/database/{app,accounts,ledger}.password; do
  test -s "$file"
  test "$(stat -c %a "$file")" = 600
done
```

파일을 삭제하면 다음 실행에서 새 비밀번호가 생성된다. 의도하지 않은 rotation을 피하려면
백업 정책을 별도로 정한 뒤 삭제한다.

## 4. Terraform 검증과 적용

### 4.1 정적 검증

```bash
terraform fmt -check -recursive Infra
for root in aws-core aws-rds aws-cache aws-eks aws-ops aws-db-bootstrap; do
  terraform -chdir="Infra/$root" init
  terraform -chdir="Infra/$root" validate
done
```

### 4.2 적용 순서

```bash
terraform -chdir=Infra/aws-core plan -out=tfplan
terraform -chdir=Infra/aws-core apply tfplan

for root in aws-rds aws-cache aws-eks aws-ops; do
  terraform -chdir="Infra/$root" plan -out=tfplan
  terraform -chdir="Infra/$root" apply tfplan
done

terraform -chdir=Infra/aws-db-bootstrap plan -out=tfplan
terraform -chdir=Infra/aws-db-bootstrap apply tfplan
```

`aws-db-bootstrap`은 RDS master ARN, EKS cluster name, 로컬 비밀번호 파일을 모두
사용하므로 `aws-rds`, `aws-eks`보다 뒤에 적용한다.

## 5. 런타임 값 렌더와 원격 GitOps 값 준비

manual YAML은 Terraform output으로 자동 갱신한다.

```bash
bash gitops/02_scripts/render-aws-runtime.sh \
  --infra-root "$(cd Infra && pwd)"

git -C gitops diff -- \
  manual/eks/argocd-exposure/targetgroupbinding.yaml \
  manual/eks/secrets.yaml
```

렌더러가 바꾸는 값은 다음 세 개뿐이다.

- `manual/eks/argocd-exposure/targetgroupbinding.yaml`: Target Group ARN, ALB SG ID
- `manual/eks/secrets.yaml`: RDS master Secret ARN

Argo CD가 읽는 `03_manifests/eks/shared/secrets.yaml`의 RDS master ARN은 직접 바꾸고
원격 저장소에 commit/push한다. Root와 Child Application의 `repoURL` 및
`targetRevision`도 같은 원격 브랜치로 맞춘다.

```bash
rg -n 'rds!db-|targetGroupARN:|groupID:|repoURL:|targetRevision:' \
  gitops/01_bootstrap gitops/03_manifests/eks/applications \
  gitops/03_manifests/eks/shared/secrets.yaml \
  gitops/manual/eks

kubectl kustomize gitops/manual/eks >/dev/null
kubectl kustomize gitops/03_manifests/eks >/dev/null
kubectl kustomize gitops/03_manifests/eks/applications >/dev/null
git -C gitops diff --check
```

## 6. EKS 접속과 플랫폼 선행조건

```bash
aws eks update-kubeconfig --name boa-eks --region ap-northeast-2
EXPECTED_ENDPOINT=$(aws eks describe-cluster --name boa-eks --region ap-northeast-2 \
  --query cluster.endpoint --output text)
CURRENT_ENDPOINT=$(kubectl config view --minify -o jsonpath='{.clusters[0].cluster.server}')
test "$CURRENT_ENDPOINT" = "$EXPECTED_ENDPOINT"

kubectl get nodes -o wide
kubectl get csidriver secrets-store.csi.k8s.io
kubectl get crd secretproviderclasses.secrets-store.csi.x-k8s.io
kubectl -n kube-system get deployment aws-load-balancer-controller
```

JWT를 준비하고 Secret Version 존재 여부만 확인한다.

```bash
bash gitops/02_scripts/prepare-jwt.sh
for secret in /boa/database/app /boa/database/accounts /boa/database/ledger \
              /boa/jwt/private /boa/jwt/public; do
  aws secretsmanager list-secret-version-ids --region ap-northeast-2 \
    --secret-id "$secret" \
    --query "Versions[?contains(VersionStages, 'AWSCURRENT')].VersionId" \
    --output text | grep -q .
done
```

Metrics Server가 없을 때만 설치한다.

```bash
kubectl get apiservice v1beta1.metrics.k8s.io >/dev/null 2>&1 || {
  helm repo add metrics-server https://kubernetes-sigs.github.io/metrics-server/ --force-update
  helm upgrade --install metrics-server metrics-server/metrics-server \
    -n kube-system --wait --timeout 10m
}
kubectl top nodes
```

## 7. YAML 수동 배포와 앱 검증

Argo CD 설치 전에 현재 desired state와 동일한 manual YAML을 배포한다.

```bash
kubectl apply --dry-run=server -k gitops/manual/eks
kubectl apply -k gitops/manual/eks

kubectl -n bank-of-anthos wait --for=condition=complete \
  job/db-bootstrap --timeout=10m
for app in userservice contacts balancereader ledgerwriter transactionhistory frontend; do
  kubectl -n bank-of-anthos rollout status "deployment/$app" --timeout=10m
done
```

리소스 존재뿐 아니라 실제 앱 응답을 확인한다.

```bash
kubectl -n bank-of-anthos get deployments,pods,jobs,svc,ingress,hpa
kubectl -n bank-of-anthos get secret db-secret accounts-db-secret ledger-db-secret
kubectl -n bank-of-anthos logs job/db-bootstrap

APP_ALB=$(kubectl -n bank-of-anthos get ingress boa-ingress \
  -o jsonpath='{.status.loadBalancer.ingress[0].hostname}')
test -n "$APP_ALB"
curl --fail --retry 12 --retry-delay 10 "http://$APP_ALB/" >/dev/null
```

실패한 Pod는 값을 출력하지 않고 이벤트와 로그만 확인한다.

```bash
kubectl -n bank-of-anthos get events --sort-by=.lastTimestamp
kubectl -n bank-of-anthos logs deployment/frontend --tail=100
```

## 8. Argo CD 설치와 UI 연결

```bash
bash gitops/02_scripts/install-argocd.sh
kubectl apply -f gitops/manual/eks/argocd-exposure/targetgroupbinding.yaml
kubectl -n argocd get pods,targetgroupbinding

TG_ARN=$(kubectl -n argocd get targetgroupbinding argocd-server \
  -o jsonpath='{.spec.targetGroupARN}')
aws elbv2 describe-target-health --region ap-northeast-2 \
  --target-group-arn "$TG_ARN" --output table
```

Target 상태가 `healthy`면 `https://argocd.bespinglobal.site`에 접속한다. UI의
`Settings → Repositories → Connect Repo`에서 다음 값을 사용한다.

- Connection: HTTPS
- Type: git
- Repository: `https://github.com/AWS-TEAM1-DEV/gitops.git`
- Username: GitHub 사용자명
- Password: private 저장소 read 권한 PAT

연결이 `Successful`인지 확인한다. PAT는 파일이나 Git에 저장하지 않는다.

## 9. Argo CD 인수와 검증

`03_manifests` 수정이 원격 브랜치에 push된 뒤 Root를 적용한다.

```bash
bash gitops/02_scripts/bootstrap.sh apply-root
bash gitops/02_scripts/verify-argocd.sh

kubectl -n argocd get applications \
  -o custom-columns=NAME:.metadata.name,BRANCH:.spec.source.targetRevision,SYNC:.status.sync.status,HEALTH:.status.health.status
```

완료 기준은 Root 1개와 Child 4개가 모두 `Synced/Healthy`이고, 수동 배포 리소스가
불필요하게 교체되지 않으며, 7장의 HTTP 검증이 계속 성공하는 것이다.

## 10. CI/CD 파이프라인 점검

현재 workflow 파일이 없으므로 아래가 수동 CI/CD 정본이다.

### 10.1 테스트

```bash
(cd accounts/src/accounts/userservice && uv run pytest tests/ -v)
(cd accounts/src/accounts/contacts && uv run pytest tests/ -v)
(cd ledger && ./mvnw test)
```

frontend는 자동 테스트가 없어 Docker build와 배포 후 HTTP 검증이 최소 게이트다.

### 10.2 Build와 ECR push

```bash
ACCOUNT=769413326616
REGION=ap-northeast-2
ECR="$ACCOUNT.dkr.ecr.$REGION.amazonaws.com"
ACCOUNTS_TAG="sha-$(git -C accounts rev-parse HEAD)"
LEDGER_TAG="sha-$(git -C ledger rev-parse HEAD)"
FRONTEND_TAG="sha-$(git -C frontend rev-parse HEAD)"

aws ecr get-login-password --region "$REGION" |
  docker login --username AWS --password-stdin "$ECR"

docker build -t "$ECR/boa-userservice:$ACCOUNTS_TAG" accounts/src/accounts/userservice
docker build -t "$ECR/boa-contacts:$ACCOUNTS_TAG" accounts/src/accounts/contacts
docker build -t "$ECR/boa-balancereader:$LEDGER_TAG" ledger/src/ledger/balancereader
docker build -t "$ECR/boa-ledgerwriter:$LEDGER_TAG" ledger/src/ledger/ledgerwriter
docker build -t "$ECR/boa-transactionhistory:$LEDGER_TAG" ledger/src/ledger/transactionhistory
docker build -t "$ECR/boa-frontend:$FRONTEND_TAG" frontend/src/frontend

for image in \
  boa-userservice:$ACCOUNTS_TAG boa-contacts:$ACCOUNTS_TAG \
  boa-balancereader:$LEDGER_TAG boa-ledgerwriter:$LEDGER_TAG \
  boa-transactionhistory:$LEDGER_TAG boa-frontend:$FRONTEND_TAG; do
  docker push "$ECR/$image"
done
```

### 10.3 GitOps write-back과 CD 확인

manual 및 `03_manifests`의 해당 `image:`를 같은 immutable 태그로 갱신한다.

```bash
rg -n 'image:.*dkr.ecr' gitops/manual/eks gitops/03_manifests/eks
kubectl kustomize gitops/manual/eks >/dev/null
kubectl kustomize gitops/03_manifests/eks >/dev/null
git -C gitops diff --check
git -C gitops diff
```

검토 후 commit/push한다. Argo CD가 자동 Sync한 뒤 이미지와 앱 응답을 확인한다.

```bash
kubectl -n bank-of-anthos get deployments \
  -o custom-columns=NAME:.metadata.name,IMAGE:.spec.template.spec.containers[0].image
bash gitops/02_scripts/verify-argocd.sh
```

## 11. HPA 점검

```bash
kubectl get apiservice v1beta1.metrics.k8s.io
kubectl top nodes
kubectl top pods -n bank-of-anthos
kubectl -n bank-of-anthos get hpa -o wide
```

HPA 6개, `ScalingActive=True`, CPU TARGETS가 `<unknown>`이 아니어야 한다.
모든 Deployment에 CPU request가 있으므로 metrics-server가 정상이라면 계산 가능하다.

## 12. Karpenter 설치와 점검

Terraform이 만든 역할·태그·Pod Identity를 먼저 확인한다.

```bash
aws iam get-role --role-name boa-eks-node-role --query Role.RoleName --output text
aws ec2 describe-subnets --region ap-northeast-2 \
  --filters Name=tag:karpenter.sh/discovery,Values=boa-eks \
  --query 'Subnets[].SubnetId' --output text | grep -q .
aws ec2 describe-security-groups --region ap-northeast-2 \
  --filters Name=tag:karpenter.sh/discovery,Values=boa-eks \
  --query 'SecurityGroups[].GroupId' --output text | grep -q .
aws eks list-pod-identity-associations --cluster-name boa-eks \
  --region ap-northeast-2
```

```bash
helm upgrade --install karpenter \
  oci://public.ecr.aws/karpenter/karpenter \
  --version 1.14.1 -n karpenter --create-namespace \
  --set settings.clusterName=boa-eks \
  --set serviceAccount.create=true \
  --set serviceAccount.name=karpenter \
  --set replicas=2 --wait --timeout 10m

kubectl -n karpenter rollout status deployment/karpenter --timeout=10m
kubectl apply --dry-run=server -f gitops/manual/eks/karpenter/ec2nodeclass.yaml
kubectl apply -f gitops/manual/eks/karpenter/ec2nodeclass.yaml
kubectl wait --for=condition=Ready ec2nodeclass/default --timeout=5m
kubectl apply --dry-run=server -f gitops/manual/eks/karpenter/nodepool.yaml
kubectl apply -f gitops/manual/eks/karpenter/nodepool.yaml
kubectl wait --for=condition=Ready nodepool/default --timeout=5m
kubectl get ec2nodeclass,nodepool,nodeclaim
```

scale-out 시험은 EC2 비용이 발생한다.

```bash
kubectl create namespace karpenter-test
kubectl create deployment inflate -n karpenter-test \
  --image=public.ecr.aws/eks-distro/kubernetes/pause:3.7 --replicas=0
kubectl set resources deployment/inflate -n karpenter-test --requests=cpu=1
kubectl patch deployment inflate -n karpenter-test --type merge \
  -p '{"spec":{"template":{"spec":{"nodeSelector":{"workload-type":"application"}}}}}'
kubectl scale deployment/inflate -n karpenter-test --replicas=5
kubectl -n karpenter-test get pods -w
kubectl get nodeclaims,nodes -w
```

시험 후 namespace를 삭제하고 `consolidateAfter: 10m` 이후 NodeClaim이 회수되는지 본다.

```bash
kubectl delete namespace karpenter-test
kubectl get nodeclaims,nodes -w
```

## 13. 최종 판정표

- Terraform AWS 6개 root: `fmt` 및 `validate` 통과
- manual/Argo Kustomize: 렌더 통과
- DB bootstrap Job: `Complete`
- 앱 Deployment 6개: rollout 완료 및 frontend HTTP 2xx
- Argo CD: Application 5개 `Synced/Healthy`
- CI/CD: 테스트·immutable ECR push·GitOps write-back 확인
- HPA: 6개, metrics 정상
- Karpenter: Controller/EC2NodeClass/NodePool Ready, 시험 NodeClaim 생성·회수

현재 계정이 대상 계정이 아니므로 이 문서 작성 시점에는 클라우드 apply와 실제 클러스터
검증을 수행하지 않았다. 대상 자격증명으로 2장부터 실행해야 최종 운영 검증이 완료된다.

## 14. 2026-09-18 로컬 검사 결과

- Terraform `fmt -check`: 통과
- `aws-core`, `aws-rds`, `aws-cache`, `aws-eks`, `aws-ops`, `aws-db-bootstrap` validate: 통과
- manual/Argo/Application Kustomize 렌더: 통과
- manual과 Argo의 앱·Secret·bootstrap·HPA 선언 비교: 일치
- userservice: 18 tests 통과
- contacts: 19 tests 통과
- ledger: 38 tests 통과
- frontend: 자동 테스트 없음
- 실제 AWS plan/apply, manual 배포, Argo CD, HPA/Karpenter 동작 검증: 잘못된 AWS 계정 때문에 미실행
