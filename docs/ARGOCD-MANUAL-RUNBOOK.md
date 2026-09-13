# Argo CD 수동 설치 런북 (인프라 재생성 대비)

인프라를 `terraform destroy` 후 다시 만들었을 때, **스크립트 없이 손으로** 값을 채워
Argo CD 설치·설정까지 끝내는 절차입니다.

- 대상: `~/gitops` (이 저장소), 클러스터 `project-eks` / `ap-northeast-2`
- 파일 수정은 **GitHub 웹 편집으로 해도 됩니다.** Argo CD 는 Git 내용만 읽으므로
  누가 값을 채웠는지는 상관없습니다.
- 스크립트 기반 절차는 [EKS-BOOTSTRAP-DEMO-RUNBOOK.md](EKS-BOOTSTRAP-DEMO-RUNBOOK.md) 참고.

---

## 0. 이 문서를 쓰는 경우

`scripts/bootstrap-eks.sh` 는 `terraform output -json` 에서 값을 읽어 파일을 렌더링합니다.
루트 `outputs.tf` 가 없으면 output 이 비어 있어 스크립트가 **즉시 중단**됩니다.

```bash
terraform -chdir=~/infra output -json | jq 'length'   # 0 이면 스크립트 경로 사용 불가
```

`0` 이면 이 문서의 수동 절차를 따릅니다. `0` 이 아니고 아래 output 이 모두 있으면
스크립트 런북이 더 안전합니다: `aws_region` `aws_account_id` `ecr_registry`
`eks_cluster_name` `rds_address` `rds_port` `rds_master_user_secret_arn`
`rds_app_secret_arn` `rds_bootstrap_db_name`.

> **수동 편집과 스크립트를 섞지 마세요.** 나중에 `--render` 를 돌리면 아래 파일들을
> `terraform output` 값으로 통째로 덮어씁니다(`write_file` / `sed_file`).

---

## 1. 값 수집

재생성 후 아래를 실행해 워크시트를 채웁니다. **secret 값은 조회하지 않고 ARN 만** 씁니다.

```bash
export AWS_REGION=ap-northeast-2
export CLUSTER_NAME=project-eks

# 계정 / ECR 레지스트리
aws sts get-caller-identity --query Account --output text
# → <ACCOUNT_ID>.dkr.ecr.ap-northeast-2.amazonaws.com 형태로 조합

# RDS endpoint / port / bootstrap DB / master secret ARN
aws rds describe-db-instances --region "$AWS_REGION" \
  --query 'DBInstances[].{id:DBInstanceIdentifier,ep:Endpoint.Address,port:Endpoint.Port,db:DBName,sec:MasterUserSecret.SecretArn}' \
  --output table

# Secrets Manager 목록 (JWT / 앱 DB secret 존재 확인)
aws secretsmanager list-secrets --region "$AWS_REGION" \
  --query 'SecretList[].{name:Name,arn:ARN}' --output table

# EKS / add-on / Pod Identity
aws eks list-clusters --region "$AWS_REGION"
aws eks list-addons --cluster-name "$CLUSTER_NAME" --region "$AWS_REGION"
aws eks list-pod-identity-associations --cluster-name "$CLUSTER_NAME" --region "$AWS_REGION" \
  --query 'associations[].{ns:namespace,sa:serviceAccount}' --output table

# ECR 리포지토리 및 태그 (kustomization 의 newTag 가 실재하는지)
aws ecr describe-repositories --region "$AWS_REGION" --query 'repositories[].repositoryName' --output json
aws ecr describe-images --repository-name frontend --region "$AWS_REGION" \
  --query 'imageDetails[].imageTags[]' --output text
```

### 워크시트

| # | 값 | 수집 명령 | 2026-09-11 기준 실제 값 | 재생성 후 |
| --- | --- | --- | --- | --- |
| 1 | ACCOUNT_ID | `aws sts get-caller-identity` | `769413326616` | 계정 유지 시 동일 |
| 2 | REGION | 고정 | `ap-northeast-2` | 동일 |
| 3 | CLUSTER_NAME | `aws eks list-clusters` | `project-eks` | 이름 유지 시 동일 |
| 4 | DB_HOST | `describe-db-instances .Endpoint.Address` | `project-postgres.cb5wjpnydii8.ap-northeast-2.rds.amazonaws.com` | **반드시 바뀜** |
| 5 | DB_PORT | `.Endpoint.Port` | `5432` | 동일 |
| 6 | BOOTSTRAP_DB_NAME | `.DBName` | `projectdb` | 동일 |
| 7 | MASTER_SECRET_ARN | `.MasterUserSecret.SecretArn` | `arn:aws:secretsmanager:ap-northeast-2:769413326616:secret:rds!db-22d614ad-ba0f-47f5-856c-584e639a0db5-rNnmG0` | **반드시 바뀜** |
| 8 | APP_SECRET_ARN | `list-secrets` → `/project/database/app` | **아직 없음 → 2단계에서 생성** | 생성 후 기록 |
| 9 | ECR_REGISTRY | 1+2 조합 | `769413326616.dkr.ecr.ap-northeast-2.amazonaws.com` | 계정 유지 시 동일 |
| 10 | ACM_CERTIFICATE_ARN | `aws acm list-certificates` | `arn:aws:acm:ap-northeast-2:769413326616:certificate/1c81ee2e-edbc-4a42-961d-816d571767ab` | ACM 재발급 시 바뀜 |

JWT secret `/project/jwt/public`, `/project/jwt/private` 는 Terraform(`modules/eks/secrets.tf`)이
만듭니다. 이름이 고정이라 파일 수정은 필요 없습니다.

---

## 2. AWS 선행 작업 (GitHub 편집으로는 안 되는 것)

### 2-1. 앱 전용 DB secret 생성

이 저장소는 애플리케이션이 RDS master 자격 증명을 쓰지 않는 전제로 되어 있습니다.
`/project/database/app` 이 없으면 SecretProviderClass 가 존재하지 않는 secret 을
가리켜 Pod 가 `ContainerCreating` 에서 멈춥니다.

```bash
# 비밀번호를 화면에 출력하지 않는다.
APP_PW="$(openssl rand -base64 24 | tr -d '/+=' | cut -c1-24)"
aws secretsmanager create-secret \
  --name /project/database/app \
  --region "$AWS_REGION" \
  --secret-string "{\"username\":\"bank_app\",\"password\":\"${APP_PW}\"}" \
  --query ARN --output text
unset APP_PW
```

출력된 ARN 을 워크시트 8번에 적습니다. DB 역할(`bank_app`)은 db-bootstrap Job 이
이 secret 값으로 생성/동기화하므로 사람이 psql 로 만들 필요는 없습니다.

앱 Role(`bank-of-anthos-sm`)의 정책은 `secret:/project/*` 를 허용하므로 추가 IAM 작업이
필요 없습니다.

### 2-2. db-bootstrap ServiceAccount 용 Pod Identity

Terraform 은 `bank-of-anthos` SA 만 연결합니다. db-bootstrap Job 은 별도 SA
(`bank-of-anthos-db-bootstrap`)를 쓰므로 연결이 없으면 master secret 을 못 읽고
sync 가 wave `-2` 에서 멈춥니다.

```bash
ACCOUNT_ID="$(aws sts get-caller-identity --query Account --output text)"

cat > /tmp/trust.json <<'JSON'
{
  "Version": "2012-10-17",
  "Statement": [{
    "Effect": "Allow",
    "Principal": { "Service": "pods.eks.amazonaws.com" },
    "Action": ["sts:AssumeRole", "sts:TagSession"]
  }]
}
JSON

aws iam create-role --role-name bank-of-anthos-db-bootstrap \
  --assume-role-policy-document file:///tmp/trust.json >/dev/null

cat > /tmp/policy.json <<JSON
{
  "Version": "2012-10-17",
  "Statement": [{
    "Effect": "Allow",
    "Action": ["secretsmanager:GetSecretValue", "secretsmanager:DescribeSecret"],
    "Resource": [
      "arn:aws:secretsmanager:${AWS_REGION}:${ACCOUNT_ID}:secret:rds!db-*",
      "arn:aws:secretsmanager:${AWS_REGION}:${ACCOUNT_ID}:secret:/project/database/app*"
    ]
  }]
}
JSON

aws iam put-role-policy --role-name bank-of-anthos-db-bootstrap \
  --policy-name db-bootstrap-secrets --policy-document file:///tmp/policy.json

aws eks create-pod-identity-association \
  --cluster-name "$CLUSTER_NAME" --region "$AWS_REGION" \
  --namespace bank-of-anthos \
  --service-account bank-of-anthos-db-bootstrap \
  --role-arn "arn:aws:iam::${ACCOUNT_ID}:role/bank-of-anthos-db-bootstrap"

rm -f /tmp/trust.json /tmp/policy.json
```

확인 — `bank-of-anthos` 와 `bank-of-anthos-db-bootstrap` 이 **서로 다른 Role** 로 보여야 합니다.

```bash
aws eks list-pod-identity-associations --cluster-name "$CLUSTER_NAME" --region "$AWS_REGION" \
  --query 'associations[?namespace==`bank-of-anthos`].{sa:serviceAccount,id:associationId}' --output table
```

### 2-3. 기타 선행 확인

| 항목 | 확인 | 없을 때 |
| --- | --- | --- |
| RDS 상태 `available` | `aws rds describe-db-instances` | 대기 |
| add-on 6개 `ACTIVE` | `aws eks list-addons` | Terraform 재확인 |
| ECR 리포지토리 6개 + 태그 실재 | `aws ecr describe-images` | 3-4 에서 `newTag` 를 실재 태그로 교체 |
| 노드 Ready | `kubectl get nodes` | Karpenter/노드그룹 확인 |

> Karpenter 를 쓰면 `k8s/cluster/karpenter/ec2nodeclass.yaml` 의 `role:
> project-eks-karpenter-node-role` 과 `karpenter.sh/discovery: project-eks` 태그가
> 실제 IAM Role / 서브넷·보안그룹 태그와 일치해야 합니다. 단 이 경로는 Argo CD 동기화
> 대상이 아니므로(overlay 에서 참조하지 않음) 필요할 때 직접 apply 합니다.

---

## 3. GitHub 에서 채울 값

`__BOOTSTRAP_PENDING__` 이 남아 있는 곳이 **8군데**입니다. 남은 자리 확인:

```bash
grep -rn "__BOOTSTRAP_PENDING__" k8s argocd bootstrap
```

### 3-1. `k8s/overlays/dev/aws/env-config.properties`

워크시트 4·5·6 을 채웁니다. 논리 DB 이름 2개는 고정값입니다.

```properties
DB_HOST=project-postgres.cb5wjpnydii8.ap-northeast-2.rds.amazonaws.com
DB_PORT=5432
BOOTSTRAP_DB_NAME=projectdb
ACCOUNTS_DB_NAME=accountsdb
LEDGER_DB_NAME=ledgerdb
```

> 이 파일은 `configMapGenerator` 입력이라 값이 바뀌면 ConfigMap 이름 해시가 바뀌고
> Pod 가 자동으로 롤링됩니다.

### 3-2. `k8s/overlays/dev/aws/secretproviderclass.yaml`

`objects:` 의 첫 `objectName` 을 **앱 secret ARN(워크시트 8)** 으로 바꿉니다.
여기에 master ARN 을 넣으면 최소권한 분리가 깨집니다.

```yaml
      - objectName: "arn:aws:secretsmanager:ap-northeast-2:<ACCOUNT_ID>:secret:/project/database/app-XXXXXX"
```

### 3-3. `k8s/overlays/dev/aws/secretproviderclass-db-bootstrap.yaml`

`objectName` 이 2개입니다. 순서를 지켜야 합니다.

| 위치 | 값 | alias |
| --- | --- | --- |
| 첫 번째 | **master** secret ARN (워크시트 7) | `master-username` / `master-password` |
| 두 번째 | **앱** secret ARN (워크시트 8) | `app-username` / `app-password` |

### 3-4. `k8s/overlays/dev/aws/kustomization.yaml`

계정이 바뀌었을 때만 `images[].newName` 의 레지스트리 호스트 6곳을 바꿉니다.

```
<ACCOUNT_ID>.dkr.ecr.ap-northeast-2.amazonaws.com/<서비스명>
```

`newTag` 는 CI 가 관리하는 값입니다. 해당 태그가 ECR 에 없으면 `ImagePullBackOff` 가
나므로, 재생성으로 ECR 이 비었다면 이미지를 다시 푸시하거나 실재하는 태그로 바꿉니다.

### 3-5. 저장소 좌표 (보통 수정 불필요)

저장소나 브랜치를 바꿨을 때만 아래 3개 파일의 `repoURL` / `targetRevision` 을 맞춥니다.

| 파일 | 필드 |
| --- | --- |
| `bootstrap/root-application.yaml` | `repoURL`, `targetRevision` |
| `argocd/applicationset.yaml` | `repoURL`, `targetRevision` |
| `argocd/appproject.yaml` | `sourceRepos[0]` |

현재 값: `https://github.com/AWS-Team1/gitops.git` / `dev`. 세 곳이 **모두 같아야** 합니다.
(`appproject` 의 `sourceRepos` 와 다르면 Application 이 `ComparisonError` 로 막힙니다.)

### 3-6. 커밋 전 자체 점검

```bash
grep -rn "__BOOTSTRAP_PENDING__" k8s argocd bootstrap && echo "FAIL: 미치환 자리 있음"
grep -rn "769413326616\|rds\.amazonaws\.com" k8s argocd bootstrap   # 이전 환경 값 잔존 확인
kubectl kustomize k8s/overlays/dev/aws  >/dev/null && echo "overlay build ok"
kubectl kustomize argocd                >/dev/null && echo "argocd build ok"
kubectl kustomize bootstrap             >/dev/null && echo "bootstrap build ok"
```

`kustomize` 단독 바이너리는 없어도 됩니다. `kubectl kustomize` 로 충분합니다.
GitHub 웹에서 편집했다면 커밋 후 `git pull` 로 로컬에 받아 위 검증을 돌립니다.

---

## 4. Argo CD 설치

```bash
helm repo add argo https://argoproj.github.io/argo-helm --force-update
helm repo update

helm upgrade --install argocd argo/argo-cd \
  --namespace argocd --create-namespace \
  --version 10.4.0 \
  --values ~/gitops/bootstrap/argocd/values.yaml \
  --atomic --timeout 10m

kubectl -n argocd rollout status deploy/argocd-server --timeout=10m
kubectl get crd | grep argoproj      # applications / applicationsets / appprojects 3개
```

차트 버전은 `environments/dev/aws.env` 의 `ARGOCD_CHART_VERSION` 과 같은 값(10.4.0)입니다.
`values.yaml` 은 dex/notifications 를 끄고 server 를 ClusterIP 로 둡니다.

---

## 5. private 저장소 인증 등록 (PAT)

이 저장소는 private 이므로 repository secret 이 없으면 Application 이
`ComparisonError` 로 멈춥니다. **PAT 는 Git 에 절대 커밋하지 않습니다.**

```bash
cd ~/gitops
./scripts/register-repo-credentials.sh     # PAT 입력 (화면에 표시되지 않음)

kubectl -n argocd get secret -l argocd.argoproj.io/secret-type=repository \
  -o custom-columns=NAME:.metadata.name,CREATED:.metadata.creationTimestamp
```

PAT 권한은 GitOps 저장소 **Contents: read** 만으로 충분합니다.
Secret 을 `-o yaml` / `-o json` 으로 출력하지 않습니다.

> `~/infra/bootstrap/configure-gitops.sh` 도 같은 일을 하지만 URL 이 하드코딩되어 있고,
> 이어서 `bank-app-bootstrap` 이라는 **다른 이름의 root Application** 을 적용합니다.
> 아래 6단계의 `bank-app-root` 와 둘 다 적용하면 같은 리소스를 두 Application 이
> 관리하게 되므로 **한쪽만** 쓰십시오. 이 런북은 `bank-app-root` 기준입니다.

---

## 6. root Application 적용

여기서부터는 Argo CD 가 Git 을 읽어 나머지를 전부 만듭니다.

```bash
cd ~/gitops
git pull                                   # GitHub 웹에서 편집했다면 필수
kubectl kustomize bootstrap | kubectl apply -f -
```

동기화 순서(sync-wave):

```
bank-app-root (-10)
  └─ argocd/   AppProject(-20) → platform: CSI driver·metrics-server(-5) → ApplicationSet(0)
       └─ bank-app-aws-dev
            SecretProviderClass(-3) / ServiceAccount(-3) → db-bootstrap Job(-2) → 앱 Deployment(0)
```

---

## 7. 검증

```bash
kubectl -n argocd get applications \
  -o custom-columns=NAME:.metadata.name,SYNC:.status.sync.status,HEALTH:.status.health.status

kubectl -n kube-system get pods -l app.kubernetes.io/name=secrets-store-csi-driver
kubectl get crd | grep secrets-store

kubectl -n bank-of-anthos get serviceaccount,secretproviderclass
kubectl -n bank-of-anthos wait --for=condition=complete job/db-bootstrap --timeout=10m
kubectl -n bank-of-anthos logs job/db-bootstrap        # 단계 로그만, 비밀번호 없음
kubectl -n bank-of-anthos rollout status deploy --all --timeout=10m
```

자격 증명 경계 (값 출력 없이 확인):

```bash
MASTER_ARN="<워크시트 7>"; APP_ARN="<워크시트 8>"

# 앱 SPC 에는 app 만, master 는 없어야 한다
kubectl -n bank-of-anthos get secretproviderclass bank-of-anthos-secrets -o json \
  | jq -e --arg a "$APP_ARN" '.spec.parameters.objects | contains($a)' >/dev/null
kubectl -n bank-of-anthos get secretproviderclass bank-of-anthos-secrets -o json \
  | jq -e --arg m "$MASTER_ARN" '.spec.parameters.objects | contains($m) | not' >/dev/null

# bootstrap SPC 는 master 를 쓰되 k8s Secret 으로 동기화하지 않는다
kubectl -n bank-of-anthos get secretproviderclass bank-of-anthos-db-bootstrap-secrets -o json \
  | jq -e '.spec | has("secretObjects") | not' >/dev/null

unset MASTER_ARN APP_ARN
```

접속 (현재 `ENABLE_APP_INGRESS=false` 라 ALB 가 없습니다):

```bash
kubectl -n argocd port-forward svc/argocd-server 8080:80
kubectl -n argocd get secret argocd-initial-admin-secret \
  -o jsonpath='{.data.password}' | base64 -d; echo     # 최초 로그인 후 변경
kubectl -n bank-of-anthos port-forward svc/frontend 8081:8080
```

### 완료 기준

- [ ] `grep -rn "__BOOTSTRAP_PENDING__" k8s argocd bootstrap` 결과 없음
- [ ] Argo CD Application 전부 `Synced/Healthy`
- [ ] `secrets-store-csi-driver` Pod 실행, `SecretProviderClass` CRD 존재
- [ ] Pod Identity: `bank-of-anthos`, `bank-of-anthos-db-bootstrap` 두 SA 모두 연결
- [ ] `db-bootstrap` Job `Complete`
- [ ] 앱 Deployment 6개 rollout 완료
- [ ] 앱 SPC 에 master ARN 없음

---

## 8. 재생성 시 무엇이 바뀌나

| 값 | destroy → apply 후 | 조치 |
| --- | --- | --- |
| RDS endpoint | **바뀜** | 3-1 |
| RDS master secret ARN (`rds!db-<uuid>`) | **바뀜** | 3-3 첫 번째 |
| `/project/database/app` | Terraform 관리 대상 아님 → 삭제 안 됨 | 남아 있으면 재사용, 없으면 2-1 |
| JWT secret `/project/jwt/*` | 이름 고정 | 없음 |
| Pod Identity (`bank-of-anthos`) | Terraform 이 재생성 | 없음 |
| Pod Identity (`bank-of-anthos-db-bootstrap`) | **사라짐** (수동 생성분) | 2-2 재실행 |
| ECR 레지스트리·이미지 | Terraform 관리 대상 아님 | 계정 유지 시 그대로 |
| ALB / Target Group ARN | **바뀜** | ALB 를 쓸 때만 부록 A |
| ACM 인증서 | 재발급 시 바뀜 | 부록 A |

> `/project/database/app` 과 db-bootstrap Role 은 **Terraform 밖**에 있습니다.
> 인프라를 지워도 secret 은 남고 IAM Role 도 남지만 Pod Identity 연결은 클러스터와 함께
> 사라집니다. 즉 재생성 후엔 보통 **2-2 만 다시** 하면 됩니다.

---

## 9. 트러블슈팅

| 증상 | 원인 | 확인 |
| --- | --- | --- |
| Application `Unknown` / `ComparisonError` | repository secret 미등록, PAT 만료, `appproject.sourceRepos` 불일치 | 5단계, `kubectl -n argocd logs deploy/argocd-repo-server` |
| Pod 가 `ContainerCreating` 에서 멈춤 | CSI 마운트 실패 — secret ARN 오타, Pod Identity 없음 | `kubectl -n bank-of-anthos describe pod <name>` 이벤트 |
| `db-bootstrap` Job 실패 (secret) | 2-2 미수행 | `aws eks list-pod-identity-associations` |
| `db-bootstrap` Job 실패 (접속) | RDS 보안그룹 5432 인바운드, NetworkPolicy egress, `PGSSLMODE=require` | `kubectl -n bank-of-anthos logs job/db-bootstrap` |
| `ImagePullBackOff` | `newTag` 가 ECR 에 없음 | `aws ecr describe-images --repository-name <repo>` |
| `SecretProviderClass` CRD 없음 | platform Application 미동기화 | `kubectl -n argocd get app` |
| 기존 리소스와 충돌 | 같은 네임스페이스에 수동 배포본이 남아 있음 | ApplicationSet 은 `prune: true, selfHeal: true` → 흡수/교체됨. 의도한 동작인지 확인 |

### 금지 사항

- Secret 값 출력·decode
- 앱 SecretProviderClass 에 master ARN 지정
- PAT 를 파일이나 커밋에 남기기
- IAM 정책에 wildcard 확대
- `bank-app-root` 와 `bank-app-bootstrap` 동시 적용

---

## 부록 A. ALB 로 외부 노출할 때

현재 `environments/dev/aws.env` 의 `ENABLE_APP_INGRESS=false` 이고, 저장소에
`ingress.yaml` 이 없습니다(스크립트가 생성하는 파일). 수동으로 ALB 를 붙이려면
AWS Load Balancer Controller 설치를 확인한 뒤 —

```bash
kubectl get crd ingressclassparams.elbv2.k8s.aws
```

`k8s/overlays/dev/aws/ingress.yaml` 을 만들고,

```yaml
apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
  name: project-ingress
  annotations:
    kubernetes.io/ingress.class: alb
    alb.ingress.kubernetes.io/scheme: internet-facing
    alb.ingress.kubernetes.io/target-type: ip
    alb.ingress.kubernetes.io/listen-ports: '[{"HTTP": 80}, {"HTTPS": 443}]'
    alb.ingress.kubernetes.io/certificate-arn: <워크시트 10>
    alb.ingress.kubernetes.io/ssl-redirect: "443"
    alb.ingress.kubernetes.io/ssl-policy: ELBSecurityPolicy-TLS13-1-2-2021-06
spec:
  rules:
    - host: app.bespinglobal.site
      http:
        paths:
          - path: /
            pathType: Prefix
            backend:
              service:
                name: frontend
                port:
                  number: 8080
```

`k8s/overlays/dev/aws/kustomization.yaml` 의 `resources:` 에
`- ingress.yaml` 을 추가합니다(`secretproviderclass-db-bootstrap.yaml` 다음 줄).

배포 후 ALB hostname 을 확인하고 Route 53 alias 레코드를 새 ALB 로 갱신합니다.

```bash
kubectl -n bank-of-anthos get ingress project-ingress \
  -o jsonpath='{.status.loadBalancer.ingress[0].hostname}'; echo
```

## 부록 B. 나중에 스크립트 경로로 돌아가려면

`~/infra` 루트에 `outputs.tf` 를 추가해 아래 output 을 노출하면 `bootstrap-eks.sh`
경로를 쓸 수 있습니다. 그때부터는 **이 문서의 수동 편집을 중단**하고 렌더링 결과를
커밋하는 방식으로 통일합니다.

| output | 소스 |
| --- | --- |
| `aws_region` / `aws_account_id` | provider / `aws_caller_identity` |
| `eks_cluster_name` | `module.eks` |
| `ecr_registry` | `<account>.dkr.ecr.<region>.amazonaws.com` |
| `rds_address` / `rds_port` / `rds_bootstrap_db_name` | `module.rds` |
| `rds_master_user_secret_arn` | `module.rds.master_user_secret_arn` |
| `rds_app_secret_arn` / `rds_app_db_username` | 앱 전용 secret (현재 수동 생성분을 Terraform 으로 이관) |

스크립트는 `rds_master_user_secret_arn == rds_app_secret_arn` 이면 실행을 중단합니다.
