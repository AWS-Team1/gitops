# EKS 초기 배포 → Argo CD → CI/CD → HPA/Karpenter 런북

대상은 AWS Account `769413326616`, Region `ap-northeast-2`, EKS `boa-eks`다.
명령은 `final-project-dev` 디렉터리에서 실행한다.

## 0. 먼저 확인할 사항

### Critical

- AWS 계정이 `769413326616`이 아니면 `bootstrap.sh`가 중단한다.
- `boa.internal` Private Hosted Zone은 Terraform이 생성하지 않고 조회만 한다. 기존
  `vpc-07194d5f908bac7cf`에 미리 연결되어 있어야 한다.
- Argo CD의 private GitHub 저장소 Credential 연결은 UI에서 한 번 수행해야 한다.

### Warning

- Root/Child Application의 `targetRevision`은 실제 push한 GitOps 브랜치와 같아야 한다.
- `accounts`, `ledger`, `frontend`에는 자동 CI workflow가 없다. 앱 테스트·이미지 push와
  GitOps 이미지 태그 갱신은 아래 4장에서 수행한다.
- DB Secret은 `prevent_destroy=true`와 7일 recovery window를 사용한다.
- Karpenter scale-out 시험은 EC2 비용이 발생하므로 기본 bootstrap에 넣지 않았다.

## 1. 최초 도구 설치

Terraform은 write-only Secret 입력 때문에 `>= 1.11`이 필요하다. Ubuntu/Debian은
[HashiCorp 공식 설치 문서](https://developer.hashicorp.com/terraform/install)를 따른다.

```bash
wget -O - https://apt.releases.hashicorp.com/gpg |
  sudo gpg --dearmor -o /usr/share/keyrings/hashicorp-archive-keyring.gpg
echo "deb [arch=$(dpkg --print-architecture) signed-by=/usr/share/keyrings/hashicorp-archive-keyring.gpg] https://apt.releases.hashicorp.com $(grep -oP '(?<=UBUNTU_CODENAME=).*' /etc/os-release || lsb_release -cs) main" |
  sudo tee /etc/apt/sources.list.d/hashicorp.list
sudo apt update
sudo apt install -y terraform
```

AWS CLI, Terraform, kubectl, Helm, Git, OpenSSL, curl도 설치되어 있어야 한다.

## 2. Terraform 적용과 runtime 렌더

```bash
ACCOUNT=$(aws sts get-caller-identity --query Account --output text)
test "$ACCOUNT" = "769413326616" || { echo "잘못된 AWS 계정: $ACCOUNT" >&2; exit 1; }
ZONE_ID=$(aws route53 list-hosted-zones-by-vpc --vpc-id vpc-07194d5f908bac7cf --vpc-region ap-northeast-2 --query "HostedZoneSummaries[?Name=='boa.internal.'].HostedZoneId | [0]" --output text)
test -n "$ZONE_ID" && test "$ZONE_ID" != "None" || { echo "boa.internal Private Hosted Zone이 기존 VPC에 연결되지 않았습니다." >&2; exit 1; }

terraform fmt -check -recursive Infra
for root in aws-core aws-rds aws-cache aws-eks aws-ops aws-db-bootstrap; do
  terraform -chdir="Infra/$root" init
  terraform -chdir="Infra/$root" validate
  terraform -chdir="Infra/$root" plan -out=tfplan
  terraform -chdir="Infra/$root" apply tfplan
  rm -f "Infra/$root/tfplan"
done

bash gitops/02_scripts/render-aws-runtime.sh --infra-root "$(cd Infra && pwd)"
```

Terraform plan은 내용을 확인한 뒤 승인한다. Bootstrap에는 Terraform 명령을 넣지 않는다.

## 3. EKS 초기 배포: 한 명령

```bash
bash gitops/02_scripts/bootstrap.sh all
```

Bootstrap은 EKS 내부 작업만 순서대로 수행한다.

> frontend에는 별도 도메인이 없다. `boa-ingress`가 만든 전용 ALB의 AWS DNS로 검증한다.
> `argocd.bespinglobal.site`는 frontend와 무관한 Argo CD 전용 ops ALB 주소다.

1. EKS kubeconfig와 JWT 준비
2. Metrics Server 설치
3. manual YAML 적용, DB bootstrap과 앱 6개 rollout/HTTP 확인
4. Argo CD와 TargetGroupBinding 설치
5. Karpenter Controller, EC2NodeClass, NodePool 설치
6. 원격 GitOps 값 push와 Argo CD UI 저장소 연결을 기다림
7. Root Application 적용
8. Argo CD 5개 앱, HPA 6개, Karpenter, frontend HTTP 최종 검증

중간에 멈추면 `03_manifests/eks/shared/secrets.yaml`의 RDS master ARN과 Application의
`targetRevision`을 배포할 원격 브랜치에 맞게 수정·commit·push한다. 그다음 UI 작업을 한다.

> Argo CD UI 저장소 연결도 Successful이면 Enter를 누르세요

`https://argocd.bespinglobal.site`의 `Settings → Repositories → Connect Repo`에서 연결한다.

- Connection: HTTPS
- Type: git
- Repository: `https://github.com/AWS-Team1/gitops.git`
- Username: GitHub 사용자명
- Password: private 저장소 read 권한 PAT

PAT는 파일이나 Git에 저장하지 않는다. 연결이 `Successful`이면 터미널에서 Enter를 눌러
나머지 적용과 검증을 계속한다.

## 4. 중단 후 이어서 실행

처음부터 다시 실행할 필요 없이 완료되지 않은 큰 단계만 선택한다. 개별 스크립트는 각자의
본업을 유지하고, 아래 모드가 자잘한 kubectl·대기 명령을 묶는다.

| 상황 | 명령 |
|---|---|
| manual 배포와 Argo/Karpenter 설치부터 | `bash gitops/02_scripts/bootstrap.sh prepare` |
| UI 연결 이후부터 | `bash gitops/02_scripts/bootstrap.sh apply-root` |
| 상태만 다시 검증 | `bash gitops/02_scripts/bootstrap.sh verify` |

각 스크립트를 직접 실행하는 경우는 해당 작업만 필요할 때다.

| 스크립트 | 하는 일 |
|---|---|
| `prepare-jwt.sh` | JWT 키 생성 또는 기존 키 쌍 검증 |
| `render-aws-runtime.sh` | Terraform output을 manual YAML에 렌더 |
| `install-argocd.sh` | Argo CD Helm 설치/업그레이드 |
| `verify-argocd.sh` | Argo CD Application 5개 상태 검증 |

`render-aws-runtime.sh`는 manual YAML만 수정한다. Argo CD가 읽는
`03_manifests/eks/shared/secrets.yaml`의 RDS master ARN과 Application의
`targetRevision`은 원격 GitOps 브랜치에 맞게 직접 수정·commit·push해야 한다.

## 5. CI/CD 점검

### 앱 테스트

```bash
(cd accounts/src/accounts/userservice && uv run pytest tests/ -v)
(cd accounts/src/accounts/contacts && uv run pytest tests/ -v)
(cd ledger && ./mvnw test)
```

frontend는 자동 테스트가 없어 Docker build와 배포 후 HTTP 검증이 최소 게이트다.

### Build와 ECR push

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

manual과 `03_manifests`의 `image:`를 같은 immutable 태그로 바꾸고 GitOps 브랜치에
commit/push한다. Argo CD 자동 Sync 후 다음 한 명령으로 재검증한다.

```bash
bash gitops/02_scripts/bootstrap.sh verify
```

## 6. 선택 사항: Karpenter 실제 scale-out 시험

기본 bootstrap은 설치와 Ready 상태까지만 확인한다. 실제 노드 생성·회수까지 시험할 때만
아래를 실행한다.

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

확인 후 `kubectl delete namespace karpenter-test`를 실행한다. `consolidateAfter: 10m` 이후
NodeClaim이 회수되는지 확인한다.

## 7. 완료 기준

- Terraform AWS 6개 root apply 완료
- DB bootstrap Job `Complete`
- 앱 Deployment 6개 rollout 완료, frontend HTTP 2xx
- Argo CD Application 5개 `Synced/Healthy`
- HPA 6개, CPU TARGETS가 `<unknown>`이 아님
- Karpenter Controller/EC2NodeClass/NodePool Ready

## 8. 2026-09-18 로컬 검사 결과

- Terraform 6개 root fmt/validate 통과
- manual/Argo/Application Kustomize 렌더 통과
- userservice 18, contacts 19, ledger 38 tests 통과
- frontend 자동 테스트 없음
- 실제 AWS/클러스터 검증은 당시 자격증명이 다른 AWS 계정이라 미실행
