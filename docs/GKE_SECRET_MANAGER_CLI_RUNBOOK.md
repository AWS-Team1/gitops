# GKE Secret Manager CLI 런북

이 문서는 Terraform을 사용하지 않고 Accounts와 Ledger의 DB 비밀번호를
Secret Manager에서 GKE로 동기화하는 절차다.

AWS 이름과의 대응은 다음과 같다.

| 용도 | AWS | GCP | Kubernetes Secret |
|---|---|---|---|
| Accounts DB | `/boa/database/accounts` | `boa-database-accounts` | `accounts-db-secret` |
| Ledger DB | `/boa/database/ledger` | `boa-database-ledger` | `ledger-db-secret` |
| JWT private | `/boa/jwt/private` | `boa-jwt-private` | `bank-app-jwt` / `jwtRS256.key` |
| JWT public | `/boa/jwt/public` | `boa-jwt-public` | `bank-app-jwt` / `jwtRS256.key.pub` |

GKE SecretSync는 AWS CSI의 `jmesPath`처럼 JSON 내부 필드를 분리하지 못한다.
따라서 사용자명은 매니페스트의 고정값으로 두고, 두 비밀번호만 별도 Secret으로
저장한다. 시크릿 값은 Git, 셸 기록, Terraform state에 남기지 않는다.

> 주의: 이 절차로 활성화한 GKE SecretSync는 현재 Terraform 코드에 선언되어 있지
> 않다. Terraform으로 정식 관리하기 전까지 `Infra/gcp-gke`에서 `terraform apply`를
> 실행하지 않는다. 실행 전에는 반드시 plan에서 SecretSync 비활성화 여부를 확인한다.

## 0. PowerShell 변수 설정

### CLI 명령어

```powershell
$PROJECT_ID = "kdt4-1-506106"
$GKE_REGION = "asia-northeast2"
$CLUSTER = "boa-gke"
$CLOUD_SQL_INSTANCE = "boa-postgres-dr-osaka"
$DB_HOST = "10.50.1.5"
$NAMESPACE = "bank-of-anthos"
$ACCOUNTS_DB_SECRET = "boa-database-accounts"
$LEDGER_DB_SECRET = "boa-database-ledger"
$JWT_PRIVATE_SECRET = "boa-jwt-private"
$JWT_PUBLIC_SECRET = "boa-jwt-public"
$K8S_ACCOUNTS_SECRET = "accounts-db-secret"
$K8S_LEDGER_SECRET = "ledger-db-secret"
$K8S_JWT_SECRET = "bank-app-jwt"
$GCLOUD_BIN = Join-Path $env:LOCALAPPDATA "Google\Cloud SDK\google-cloud-sdk\bin"
if ($env:Path -notlike "*$GCLOUD_BIN*") { $env:Path += ";$GCLOUD_BIN" }
```

### 목적

이후 명령에서 프로젝트·클러스터·시크릿 이름을 반복 입력하지 않게 한다.

### 실행 후 결과

출력은 없다. `$PROJECT_ID`, `$GKE_REGION` 등의 변수가 현재 PowerShell 세션에 설정된다.

## 1. gcloud 설치 확인 및 재로그인

### CLI 명령어

```powershell
gcloud version
gcloud auth login ba016@bespin.email --force
gcloud config set project $PROJECT_ID
gcloud auth list --filter=status:ACTIVE
```

### 목적

Google Cloud CLI 설치와 로그인 상태를 확인하고 작업 프로젝트를 고정한다. `--force`는
만료된 캐시 자격 증명의 터미널 비밀번호 재입력 대신 새 브라우저 로그인을 시작한다.

### 실행 후 결과

- `gcloud version`에 Google Cloud SDK 버전이 출력된다.
- 브라우저 로그인이 완료된다.
- `Updated property [core/project].`가 출력된다.
- 활성 계정에 `ba016@bespin.email`이 표시된다.

## 2. GKE 사전 조건 확인

### CLI 명령어

```powershell
gcloud container clusters describe $CLUSTER `
  --region=$GKE_REGION `
  --project=$PROJECT_ID `
  --format="yaml(name,location,currentMasterVersion,workloadIdentityConfig.workloadPool,secretManagerConfig,secretSyncConfig)"

gcloud container clusters get-credentials $CLUSTER `
  --region=$GKE_REGION `
  --project=$PROJECT_ID

kubectl config current-context
```

### 목적

대상 클러스터와 Workload Identity Federation을 확인하고 이후 `kubectl` 명령의
현재 컨텍스트를 오사카 GKE로 전환한다. `SecretSync`는 GKE 1.33 이상이 필요하므로
`currentMasterVersion`의 앞 두 숫자가 1.33 이상이어야 한다.

### 실행 후 결과

다음 형태의 값이 출력되어야 한다.

```yaml
name: boa-gke
location: asia-northeast2
currentMasterVersion: 1.35.8-gke.1036000
secretManagerConfig:
  enabled: true
  rotationConfig:
    enabled: true
    rotationInterval: 300s
workloadIdentityConfig:
  workloadPool: kdt4-1-506106.svc.id.goog
```

마지막 명령은 `gke_kdt4-1-506106_asia-northeast2_boa-gke` 컨텍스트를 출력해야 한다.

버전이 1.33 미만이거나 `workloadPool`이 비어 있으면 여기서 중단한다.
2026-09-21 실환경에서 Secret Manager add-on과 SecretSync가 모두 활성화됐고,
rotation interval은 각각 `300s`다. 클러스터 상태는 `RUNNING`이다.

## 2.1 Cloud SQL 사용자 확인

### CLI 명령어

```powershell
gcloud sql users list `
  --instance=$CLOUD_SQL_INSTANCE `
  --project=$PROJECT_ID `
  --format="table(name,type)"
```

### 목적

Secret Manager에 저장할 비밀번호의 실제 Cloud SQL 사용자가 먼저 존재하는지
확인한다. Secret 생성은 DB 사용자를 만들지 않는다.

### 실행 후 결과

`gcloud sql users list`에는 Cloud SQL API로 관리되는 사용자만 표시될 수 있다.
2026-09-21에 PostgreSQL role로 `accounts_app`, `ledger_app`을 생성하고 각각
`accountsdb`, `ledgerdb`에 최소 권한을 부여했다. `dms_writer`는 데이터 이관 전용이므로
GKE 앱에 제공하지 않는다.

## 2.2 PostgreSQL role 확인

### CLI 명령어

```powershell
SELECT rolname
FROM pg_roles
WHERE rolname IN ('accounts_app', 'ledger_app');
```

### 목적

Cloud SQL Studio에서 오사카 인스턴스의 `postgres` DB에 접속해 두 로그인 role이
존재하는지 확인한다. `\gexec` 같은 `psql` 메타 명령은 Studio에서 사용하지 않는다.

### 실행 후 결과

`accounts_app`, `ledger_app` 두 행이 출력되어야 한다. 하나라도 없으면 Secret을 만들지
말고 해당 role부터 생성한다.

## 3. Secret Manager API 활성화

### CLI 명령어

```powershell
gcloud services enable secretmanager.googleapis.com `
  --project=$PROJECT_ID

gcloud services list --enabled `
  --project=$PROJECT_ID `
  --filter="config.name:secretmanager.googleapis.com" `
  --format="value(config.name)"
```

### 목적

프로젝트에서 Secret Manager API를 사용할 수 있게 한다. 이미 활성화되어 있어도
명령을 다시 실행해도 안전하다.

### 실행 후 결과

마지막 명령이 다음 값을 출력해야 한다.

```text
secretmanager.googleapis.com
```

## 4. GKE SecretSync 활성화

### CLI 명령어

```powershell
gcloud container clusters update $CLUSTER `
  --region=$GKE_REGION `
  --project=$PROJECT_ID `
  --enable-secret-sync `
  --enable-secret-sync-rotation `
  --secret-sync-rotation-interval=300s
```

### 목적

Secret Manager 값을 Kubernetes Secret으로 동기화한다. 현재 앱 이미지는
`secretKeyRef` 환경변수를 사용하므로 파일 마운트 전용 add-on 대신 SecretSync가
필요하다. 5분마다 새 Secret Manager 버전을 확인한다.

### 실행 후 결과

클러스터 업데이트가 완료되고 오류 없이 종료된다. 확인 명령은 다음과 같다.

```powershell
gcloud container clusters describe $CLUSTER `
  --region=$GKE_REGION `
  --project=$PROJECT_ID `
  --format="yaml(secretSyncConfig)"
```

출력에서 SecretSync와 rotation이 활성화된 상태여야 한다.

## 5. DB 비밀번호 Secret 생성

### CLI 명령어

```powershell
foreach ($secret in @(
  $ACCOUNTS_DB_SECRET,
  $LEDGER_DB_SECRET,
  $JWT_PRIVATE_SECRET,
  $JWT_PUBLIC_SECRET
)) {
  gcloud secrets describe $secret --project=$PROJECT_ID *> $null
  if ($LASTEXITCODE -ne 0) {
    gcloud secrets create $secret `
      --project=$PROJECT_ID `
      --replication-policy=automatic
  }
}

function Add-PasswordVersion([string] $SecretName) {
  $secure = Read-Host "$SecretName password" -AsSecureString
  $bstr = [Runtime.InteropServices.Marshal]::SecureStringToBSTR($secure)
  $tempFile = Join-Path ([IO.Path]::GetTempPath()) "$SecretName-$PID"
  try {
    $plain = [Runtime.InteropServices.Marshal]::PtrToStringBSTR($bstr)
    [IO.File]::WriteAllText($tempFile, $plain, [Text.UTF8Encoding]::new($false))
    gcloud secrets versions add $SecretName `
      --project=$PROJECT_ID `
      --data-file=$tempFile
    if ($LASTEXITCODE -ne 0) { throw "$SecretName version 생성 실패" }
  }
  finally {
    [Runtime.InteropServices.Marshal]::ZeroFreeBSTR($bstr)
    $plain = $null
    if (Test-Path -LiteralPath $tempFile) {
      Remove-Item -LiteralPath $tempFile -Force
    }
  }
}

Add-PasswordVersion $ACCOUNTS_DB_SECRET
Add-PasswordVersion $LEDGER_DB_SECRET
```

### 목적

AWS의 `/boa/database/accounts`, `/boa/database/ledger`에 대응하는 글로벌 자동 복제
Secret을 만들고, 비밀번호를 화면과 셸 기록에 남기지 않은 채 각각 새 버전으로 추가한다.
임시 파일은 명령 종료 시 삭제된다.

### 실행 후 결과

두 번의 숨김 입력 후 각 Secret에 새 버전이 생성됐다는 메시지가 출력된다.

```text
boa-database-accounts
boa-database-ledger
```

## 5.1 SecretSync 서비스 계정 권한 부여

### CLI 명령어

```powershell
$PROJECT_NUMBER = gcloud projects describe $PROJECT_ID `
  --format="value(projectNumber)"
$SECRET_SYNC_KSA = "bank-app-secret-sync"
$SECRET_SYNC_MEMBER = "principal://iam.googleapis.com/projects/$PROJECT_NUMBER/locations/global/workloadIdentityPools/$PROJECT_ID.svc.id.goog/subject/ns/$NAMESPACE/sa/$SECRET_SYNC_KSA"

foreach ($secret in @($ACCOUNTS_DB_SECRET, $LEDGER_DB_SECRET)) {
  gcloud secrets add-iam-policy-binding $secret `
    --project=$PROJECT_ID `
    --role="roles/secretmanager.secretAccessor" `
    --member=$SECRET_SYNC_MEMBER
}
```

### 목적

`bank-app-secret-sync` Kubernetes ServiceAccount가 두 DB 비밀번호만 읽도록 Secret
단위 최소 권한을 부여한다.

### 실행 후 결과

각 Secret의 IAM 정책에 `roles/secretmanager.secretAccessor` 바인딩이 추가된다.
비밀번호 값은 출력되지 않는다.

## 6. 기존 GKE Secret 확인

### CLI 명령어

```powershell
kubectl get secret $K8S_ACCOUNTS_SECRET $K8S_LEDGER_SECRET $K8S_JWT_SECRET `
  --namespace=$NAMESPACE
```

### 목적

Accounts와 Ledger Secret의 현재 생성 여부를 확인한다. SecretSync 매니페스트 적용
전에는 두 DB Secret이 없어도 정상이다.

### 실행 후 결과

SecretSync 적용 후 다음 Secret이 `Opaque` 타입으로 표시되어야 한다.

```text
accounts-db-secret
ledger-db-secret
bank-app-jwt
```

## 7. SecretSync 매니페스트 적용

### CLI 명령어

```powershell
kubectl apply -k 03_manifests/gke/shared

kubectl get secretsync,secretproviderclass `
  --namespace=$NAMESPACE
```

### 목적

서비스 계정과 SecretSync 리소스를 적용하고 동기화 상태를 확인한다.

### 실행 후 결과

`accounts-db-secret`, `ledger-db-secret`, `bank-app-jwt` SecretSync와
`bank-of-anthos-db-secrets` SecretProviderClass가 표시되어야 한다.

## 8. 값 노출 없이 최종 확인

### CLI 명령어

```powershell
gcloud secrets list `
  --project=$PROJECT_ID `
  --filter="name:boa-database-" `
  --format="table(name,replication.automatic)"

kubectl get secret $K8S_ACCOUNTS_SECRET $K8S_LEDGER_SECRET `
  --namespace=$NAMESPACE
```

### 목적

Secret Manager와 Kubernetes에 분리된 DB Secret이 모두 존재하는지 확인한다.
Secret 값은 출력하지 않는다.

### 실행 후 결과

- Secret Manager에 `boa-database-accounts`, `boa-database-ledger`가 표시된다.
- Kubernetes에 `accounts-db-secret`, `ledger-db-secret`, `bank-app-jwt`가 표시된다.
- 비밀번호 값은 출력되지 않는다.

## GitOps에서 이어서 만들 리소스

CLI 작업이 끝나면 GKE 매니페스트에서 다음 이름을 그대로 사용한다.

- Accounts DB Secret: `accounts-db-secret` (`password` 키)
- Ledger DB Secret: `ledger-db-secret` (`password` 키)
- JWT Secret: `bank-app-jwt`
- Accounts 사용자명: `accounts_app` (매니페스트 고정값)
- Ledger 사용자명: `ledger_app` (매니페스트 고정값)
- DB 주소: `10.50.1.5`; DB 이름: `accountsdb`, `ledgerdb`
- JWT 키: `jwtRS256.key`, `jwtRS256.key.pub`

## 9. 기존 수동 Deployment를 GKE 매니페스트로 전환

### CLI 명령어

```powershell
cd C:\final-project-dev\gitops-gke

$DB_DEPLOYMENTS = @(
  "userservice",
  "contacts",
  "balancereader",
  "ledgerwriter",
  "transactionhistory"
)

foreach ($deployment in $DB_DEPLOYMENTS) {
  kubectl set env deployment/$deployment `
    --namespace=bank-of-anthos `
    SPRING_DATASOURCE_URL- `
    SPRING_DATASOURCE_USERNAME- `
    SPRING_DATASOURCE_PASSWORD- `
    ACCOUNTS_DB_URI-
}

# Redis는 선택 기능이다. 과거 Deployment에 남은 값이 있으면 앱이 없는 redis Service를 호출한다.
kubectl set env deployment/userservice `
  --namespace=bank-of-anthos `
  REDIS_URL-

# 2026-09-21 최초 적용에서 생성된 중복 HPA가 있을 때만 제거한다.
kubectl delete hpa `
  frontend-hpa userservice-hpa contacts-hpa `
  ledgerwriter-hpa balancereader-hpa transactionhistory-hpa `
  --namespace=bank-of-anthos `
  --ignore-not-found

kubectl apply --server-side --force-conflicts -k 03_manifests/gke
```

### 목적

기존 수동 Deployment에 남아 있는 `bank-app-runtime` 환경변수를 최초 한 번 제거한 뒤,
AWS와 같은 앱 설정을 GKE 리소스로 전환한다. 이후에는 GitOps 매니페스트만 관리한다.

### 실행 후 결과

```powershell
kubectl get deployment,pod,hpa -n bank-of-anthos
kubectl get service frontend -n bank-of-anthos
```

6개 Deployment와 HPA가 표시되고 각 Deployment의 READY가 `2/2`가 되어야 한다.
`frontend` Service의 `EXTERNAL-IP`는 GKE LoadBalancer 준비 후 값이 표시된다.

## 10. 로그인 장애 확인 및 복구

### CLI 명령어

```powershell
kubectl logs deployment/userservice `
  --namespace=bank-of-anthos `
  --all-pods=true `
  --since=10m `
  --prefix

kubectl describe secretsync bank-app-jwt `
  --namespace=bank-of-anthos
```

### 목적

로그인 실패가 DB 연결인지 JWT SecretSync인지 구분한다. 다음 메시지는 각각 아래 원인이다.

- `connection to server on socket "@10.50.1.5/..."`: 비밀번호의 `@` 같은 예약문자가 DB URI에 직접 삽입되어 호스트가 잘못 파싱됨
- `InvalidKeyError` 또는 `Could not parse the provided public key`: `bank-app-jwt`가 PEM이 아닌 placeholder 값임
- `Redis unavailable during signup`: 회원가입 경로 오류이며 로그인 실패 원인은 아님

Accounts 매니페스트는 비밀번호를 URI에 넣지 않고 libpq 표준 환경변수인 `PGPASSWORD`로
전달한다. 따라서 비밀번호를 변경하거나 URL 인코딩하지 않아도 된다.

### 기존 수동 JWT Secret 충돌 복구

`bank-app-jwt` SecretSync 상태가 `UserInputValidationFailed`이고 기존
`bank-app-jwt` Secret을 수동으로 만들었다면, placeholder Secret만 한 번 삭제한다.
Secret Manager의 `boa-jwt-private`, `boa-jwt-public`은 삭제하지 않는다.

```powershell
kubectl delete secret bank-app-jwt `
  --namespace=bank-of-anthos

kubectl wait --for=create secret/bank-app-jwt `
  --namespace=bank-of-anthos `
  --timeout=90s

kubectl get secretsync bank-app-jwt `
  --namespace=bank-of-anthos `
  -o yaml
```

### 실행 후 결과

SecretSync의 condition이 `status: "True"`이고 `lastSuccessfulSyncTime`이 표시되어야 한다.
키를 시작 시점에 읽는 앱이 새 Secret을 사용하도록 재시작한다.

```powershell
kubectl rollout restart deployment/userservice deployment/contacts deployment/frontend deployment/balancereader deployment/ledgerwriter deployment/transactionhistory `
  --namespace=bank-of-anthos

kubectl rollout status deployment/userservice deployment/frontend `
  --namespace=bank-of-anthos `
  --timeout=5m
```

DB 연결과 JWT 서명을 실제 계정 정보 및 Secret 값을 출력하지 않고 확인한다.

```powershell
$POD = kubectl get pod `
  --namespace=bank-of-anthos `
  --selector=app=userservice `
  -o jsonpath='{.items[0].metadata.name}'

kubectl exec --namespace=bank-of-anthos $POD -- python -c "import os; from sqlalchemy import create_engine,text; from sqlalchemy.engine import make_url; u=make_url(os.environ['ACCOUNTS_DB_URI']); print('host=',u.host); print('db_select=',create_engine(os.environ['ACCOUNTS_DB_URI']).connect().execute(text('select 1')).scalar())"

kubectl exec --namespace=bank-of-anthos $POD -- python -c "import os,jwt; k=open(os.environ['PRIV_KEY_PATH']).read(); print('jwt_sign=',bool(jwt.encode({'check':'ok'},k,algorithm='RS256')))"
```

정상 결과는 `host= 10.50.1.5`, `db_select= 1`, `jwt_sign= True`다.
이 검증은 로그인 준비 상태만 확인한다. 실제 로그인은 DMS로 복제된 기존 사용자로 수행한다.

> AWS→GCP 단방향 DMS가 실행 중일 때 GCP에서 회원가입이나 송금을 수행하면 데이터가
> AWS로 돌아가지 않는다. 컷오버 전에는 기존 사용자 로그인·조회만 검증한다.

참고 문서:

- [Secret Manager와 GKE 연동](https://docs.cloud.google.com/secret-manager/docs/secret-manager-managed-csi-component)
- [Secret Manager를 Kubernetes Secret으로 동기화](https://docs.cloud.google.com/secret-manager/docs/sync-k8-secrets)
- [Secret 단위 IAM 최소 권한](https://docs.cloud.google.com/secret-manager/docs/access-control)
