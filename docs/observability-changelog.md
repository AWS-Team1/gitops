# 관측 스택 변경 내역 — gitops

- 기준 브랜치: `dev-0922` (`6376c10` "refactor: organize platform manifests as overlays")
- 작업 브랜치: `feat/observability-stack`
- 작성: 2026-09-26
- 담당: 보안·관측 파트
- 짝 문서: `Infra/docs/plans/observability-changelog.md`

검증 상태 — `kubectl kustomize` 7개 경로 전부 렌더 성공. 계측 어노테이션이
EKS·GKE 양쪽에 각각 `inject-java` 3회 · `inject-python` 3회로 나오고,
클라우드별 DB 목적지 패치(`192.168.16.0/24` / `10.50.1.5/32`)가 보존됨을 확인했다.
**CRD 스키마 검증은 하지 않았다** — 오퍼레이터가 설치된 클러스터가 필요하다.

---

## 1. 요약

| 구분 | 파일 | 추가 |
|---|---|---|
| 기존 파일 수정 | 12 | 33 |
| 신규 — base | 3 | 132 |
| 신규 — EKS 오버레이 | 10 | 1405 |
| 신규 — GKE 오버레이 | 9 | 1137 |
| 합계 | 34 | 2707 |

**삭제 0줄.** 기존 리소스를 지우거나 이름을 바꾼 것은 없다.

---

## 2. 앱 코드는 바뀌지 않았다

`frontend` · `ledger` · `accounts` 저장소는 **건드리지 않았다.** 이미지도
재빌드하지 않는다. 계측은 파드 어노테이션 한 줄로 붙는다.

| 변경 범위 | |
|---|---|
| 소스 코드 | 불필요 |
| 이미지 재빌드 | 불필요 |
| 매니페스트 | base + 양쪽 오버레이 |
| 기존 코드 충돌 | 없음 (와탭 네이티브 APM 을 쓰지 않으므로 `apm.instrumentation` 과 겹치지 않는다) |

---

## 3. 수정 — 기존 파일 12개

### 3.1 계측 어노테이션 — `base/` 6개 파일 (각 +4줄)

| 파일 | 어노테이션 |
|---|---|
| `base/ledger/balancereader.yaml` | `inject-java` |
| `base/ledger/ledgerwriter.yaml` | `inject-java` |
| `base/ledger/transactionhistory.yaml` | `inject-java` |
| `base/accounts/userservice.yaml` | `inject-python` |
| `base/accounts/contacts.yaml` | `inject-python` |
| `base/frontend/frontend.yaml` | `inject-python` |

값은 둘 다 `"bank-of-anthos/boa"` — `<Instrumentation 네임스페이스>/<이름>` 이다.
삽입 위치는 6개 파일 모두 동일하다(`spec.template.metadata`, 원본 14행 다음).

**base 에 넣은 이유** — `dev-0922` 재편에서 파드 어노테이션을 통째로 지우던
`op: remove` 패치가 사라졌다(`grep -rn "op: remove" 03_manifests/` 결과 0건).
남은 `/metadata/annotations` 패치 4개는 `overlays/eks/shared/kustomization.yaml`
의 `op: add` sync-wave 이고 대상이 Namespace·ServiceAccount·SecretProviderClass·
ConfigMap — 전부 리소스 레벨이라 파드 템플릿과 무관하다.

결과: **한 커밋이 EKS 와 GKE 를 동시에 계측한다.** 오버레이에 넣으면 같은 줄을
두 번 써야 하고 한쪽만 고치는 드리프트가 생긴다.

> ⚠️ **되돌림도 양쪽에 적용된다.**

### 3.2 `overlays/{eks,gke}/shared/kustomization.yaml` (각 +1줄)

`networkpolicy-observability.yaml` 을 `resources` 에 등록.

### 3.3 `overlays/{eks,gke}/applications/kustomization.yaml` (각 +2줄)

`observability-platform.yaml` · `observability.yaml` 등록.

### 3.4 `overlays/{eks,gke}/applications/project.yaml` (각 +59줄) — **권한 확대**

**이 변경 없이는 관측 스택이 전부 막힌다.** 기존 `boa` AppProject 가 너무 좁았다.

| 항목 | 이전 | 이후 | 왜 |
|---|---|---|---|
| `sourceRepos` | gitops 하나 | + Helm 차트 저장소 3개 | 없으면 `application repo … is not permitted in project` 로 거부 |
| `destinations` | `bank-of-anthos` 하나 | + `monitoring` · `cert-manager` · `opentelemetry-operator-system` · `whatap-monitoring` | 관측 스택이 앱 네임스페이스 밖에 산다 |
| `clusterResourceWhitelist` | `Namespace` 하나 | + CRD · ClusterRole · ClusterRoleBinding · Mutating/ValidatingWebhookConfiguration | 차트가 CRD 를 설치하고 수집기가 클러스터 전역을 읽는다 |

허용한 차트 저장소:

```
https://charts.jetstack.io
https://open-telemetry.github.io/opentelemetry-helm-charts
https://whatap-cloud.github.io/whatap-operator
```

> ⚠️ **이것은 실질적인 권한 확대다.** 이 프로젝트의 **모든** Application 이
> 클러스터 전역 RBAC 를 만들 수 있게 된다. `boa-accounts` 등 앱 Application 은
> 그 리소스를 쓰지 않지만 프로젝트 단위 허용이라 구분되지 않는다.
> 더 좁히려면 관측용 AppProject 를 따로 만드는 편이 맞다 — 미결 6항.

---

## 4. 신규 — `base/observability/` (공통, 3파일)

| 파일 | 내용 |
|---|---|
| `namespace.yaml` | `monitoring` 네임스페이스. sync-wave `-10` |
| `instrumentation.yaml` | `Instrumentation/boa` (ns `bank-of-anthos`). sync-wave `-1` |
| `kustomization.yaml` | 위 둘 |

`monitoring` 네임스페이스에 **default-deny 를 걸지 않았다.** 앱 네임스페이스와
달리 이곳은 외부로 나가는 것이 일(와탭·CloudWatch·S3)이고 막으면 전부 끊긴다.

### Instrumentation CR 의 선택들

| 설정 | 값 | 이유 |
|---|---|---|
| `exporter.endpoint` | `http://otel-gateway-collector.monitoring.svc.cluster.local:4318` | 오퍼레이터가 만드는 Service 이름 규칙은 `<CR 이름>-collector` |
| `sampler` | `parentbased_traceidratio` `1.0` | frontend 가 루트 스팬을 만들므로 실질적으로 frontend 비율이 전체를 정한다 |
| `java` 이미지 | `autoinstrumentation-java:2.11.0` | 태그 고정. 비워 두면 웹훅이 조용히 버전을 올려 계측 동작이 바뀐다 |
| `OTEL_INSTRUMENTATION_GUAVA_ENABLED` | false | ledger 3종의 Guava LoadingCache 를 스팬으로 만들면 스팬 수가 폭발한다 |
| `python` 이미지 | `autoinstrumentation-python:0.58b0` | 같은 이유로 고정 |
| python `OTEL_EXPORTER_OTLP_PROTOCOL` | `http/protobuf` | 파이썬 SDK 기본값은 grpc 다. 안 맞추면 파이썬 3종만 전송 실패 |

**`bank-of-anthos` 네임스페이스에 둔 이유** — 웹훅은 어노테이션 값을 `<ns>/<name>`
으로 해석하므로 다른 네임스페이스도 되지만, 앱과 같은 곳에 두면 앱만 보고도
무엇이 주입되는지 추적된다.

---

## 5. 신규 — 관측 오버레이

### 5.1 수집기를 셋으로 나눈 이유

| 수집기 | 모드 | replicas | 이유 |
|---|---|---|---|
| `otel-gateway` | deployment | 2 | OTLP 수신 · 마스킹 · 목적지 분기. 와탭 사이드카가 여기 붙는다 |
| `otel-agent` | daemonset | 노드당 1 | `kubeletstats` · `hostmetrics` · `filelog` 은 자기 노드를 봐야 한다 |
| `otel-cluster` | deployment | **1 고정** | `k8s_cluster` 는 API 서버에 클러스터 전체를 묻는다. 둘이면 지표가 두 번 들어온다 |

`otel-cluster` 의 `replicas: 1` 은 **바꾸면 안 된다.** 이 제약 때문에
게이트웨이에 합칠 수 없다.

에이전트와 클러스터 수집기는 **AWS/GCP 로 직접 내보내지 않는다.** 게이트웨이에
OTLP 로 넘긴다 — 마스킹 지점을 한 곳으로 유지하려는 것이다. 두 곳에 두면
한쪽을 고칠 때 다른 쪽을 잊는다.

### 5.2 CloudWatch Container Insights 애드온을 쓰지 않는다

`amazon-cloudwatch-observability` 애드온을 설치하지 않는다. 그 애드온의
`autoMonitor.monitorAllServices` 가 기본 true 이고 `kube-system` ·
`amazon-cloudwatch` 만 제외하므로 **6개 서비스 전부가 자동계측 대상**이 되어
오픈텔레메트리 오퍼레이터의 웹훅과 충돌한다. 애드온이 `Instrumentation` CR 까지
관리하려 든다.

그 자리를 `kubeletstats`(노드·파드·컨테이너 자원) + `k8s_cluster`(워크로드 상태)
+ `hostmetrics`(노드 OS)로 채웠다. `k8s_cluster` 가 주는 것이 kube-state-metrics
자리다 — `k8s.deployment.desired/.available`, `k8s.pod.phase`, `k8s.hpa.*`,
`k8s.job.failed_pods`, `k8s.node.condition_ready`.

### 5.3 로그 중복을 끊은 방법

자동계측의 로그 어펜더가 앱 로그를 OTLP 로 보내고, `filelog` 가 같은 stdout 을
파일로 읽으면 **두 배가 된다.** `filelog` 의 `exclude` 로 끊었다.

```
exclude:
  - /var/log/pods/bank-of-anthos_*/*/*.log   # 앱 로그는 OTLP 경로만
  - /var/log/pods/monitoring_*/*/*.log       # 자기 로그를 읽으면 되먹임 루프
```

GKE 는 추가로 `logs` 파이프라인에서 `googlecloud` exporter 를 **뺐다** —
`logging.googleapis.com/kubernetes` 가 이미 컨테이너 stdout 을 Cloud Logging 에
넣고 있어서 세 배가 된다.

### 5.4 마스킹 — 파이프라인 안에서 (핵심)

**왜 수집기에서 하는가** — CloudWatch Logs 데이터 보호 정책은 읽기 시점 마스킹이고
CloudWatch **에만** 적용된다. 와탭과 S3 로 가는 데이터는 그 정책이 닿지 않는다.
수집기가 세 목적지 모두에 걸리는 유일한 지점이다.

프로세서 순서가 의미를 갖는다:

```
memory_limiter → k8sattributes → resourcedetection → resource
  → redaction → transform → batch
```

**마스킹이 `batch` 앞에 있어야 한다.** 뒤에 두면 이미 내보내진 뒤다.

| 프로세서 | 하는 일 |
|---|---|
| `redaction` | 키 패턴으로 속성 삭제 — `url.full` · `url.query` · `http.url` · `http.target` · authorization/password/secret/token/api-key/cookie |
| `redaction.blocked_values` | 값이 10자리 숫자면 삭제 (키 이름을 못 맞춘 경우의 안전망) |
| `transform` | 남은 문자열 안의 숫자 치환 — 스팬 이름과 `url.path` 의 10자리를 `{accountId}` 로, 로그 본문의 JWT 를 `{jwt}` 로 |

계좌번호가 실제로 들어오는 경로:

```
GET /balances/{accountId}      balancereader
GET /transactions/{accountId}  transactionhistory
```

와탭 쪽에서도 한 번 더 막았다 — `otel_attr_tx_url_keys` 의 기본 목록 첫 항목이
`http.url` 인데, 이 앱의 URL 에 계좌번호가 있다. `http.route` 를 앞에 두어
경로 템플릿으로 집계되게 했다.

**EKS 와 GKE 의 마스킹 규칙은 한 글자도 다르지 않다.** 갈라지면 한쪽만 새는
상황이 생긴다.

### 5.5 목적지

| 신호 | EKS | GKE |
|---|---|---|
| traces | 와탭 + S3 | 와탭 + Cloud Trace |
| metrics | 와탭 + `awsemf` | 와탭 + Managed Prometheus |
| logs | 와탭 + `awscloudwatchlogs` + S3 | 와탭 **만** (중복 회피) |

와탭 경로는 `whatap-otel` 사이드카 → `127.0.0.1:6600`. 공식 문서가 "같은 파드"를
전제하므로 별도 Service 로 빼지 않았다. `otel_metric_server_enabled` ·
`otel_log_server_enabled` 는 기본값이 **꺼짐**이라 명시적으로 켰다.

> ⚠️ `whatap-otel` 은 **베타**다. 와탭 문서가 운영 환경 비권장을 명시한다.

### 5.6 `secrets.yaml` — pause 파드가 필요한 이유

Secrets Store CSI 는 **볼륨이 마운트될 때** Secrets Manager 를 읽고 Secret 을
만든다. 수집기와 Grafana 는 `secretKeyRef` 로만 읽으므로 아무도 마운트하지 않으면
Secret 이 영원히 생기지 않고 두 파드가 `CreateContainerConfigError` 로 멈춘다.

그래서 `observability-secret-sync` Deployment(pause 이미지, 20m CPU)가 볼륨만
들고 있는다. sync-wave `7` — 수집기(`10`)보다 먼저 뜬다.

GKE 는 앱 쪽과 같이 `SecretSync` CR 을 쓰므로 이 파드가 필요 없다.

### 5.7 Grafana — 설계상의 약점을 명시한다

층 2(AWS 리소스 지표)만 본다. 층 1은 와탭 화면이다. 합치지 못한 이유는 와탭이
CloudWatch 를 데이터소스로 받지 못하기 때문이다(클라우드 모니터링 제품 종료 예정).

> ⚠️ **관측 수단이 관측 대상과 같은 클러스터에 있다.** EKS 가 죽으면 이 Grafana 도
> 죽고 CloudWatch 를 볼 수단이 AWS 콘솔뿐이 된다. 이것은 "평상시 편의"이고
> 장애 시 정식 경로는 CloudWatch 콘솔이다. **발표에서 먼저 밝히는 편이 낫다.**

`/var/lib/grafana` 가 `emptyDir` 이다 — 파드가 재시작하면 사람이 만든 대시보드는
사라진다. 남겨야 하면 PVC(gp3)로 바꾼다.

**GKE 에는 Grafana 를 두지 않았다.** 대기 사이트에 노드 1대 예산을 관측 UI 가
먹는다. 필요하면 EKS 판 `grafana.yaml` 을 가져다 쓴다.

### 5.8 NetworkPolicy — 별도 객체로 더한 이유

기존 정책을 고치지 않았다. 두 가지 이유:

1. 같은 파드에 붙는 여러 NetworkPolicy 는 **합집합**이다
2. 오버레이가 `/spec/egress/0/to` · `/spec/ingress/0/from` 을 **배열 인덱스로**
   치환한다. base 배열을 건드리면 클라우드별 DB 목적지 패치가 엉뚱한 규칙에
   적용된다 — 별도 객체는 인덱스와 무관하다

렌더로 확인했다 — NetworkPolicy 가 EKS 8→10, GKE 7→9 가 되고
`balancereader-networkpolicy` 의 5432 목적지가 EKS `192.168.16.0/24` ·
GKE `10.50.1.5/32` 로 그대로 유지됐다.

`shared/` 가 base 에 없고 오버레이에만 있어서 **파일이 두 곳에 중복된다.**
base 에 `shared/` 를 새로 만드는 것보다 기존 구조를 건드리지 않는 쪽을 택했다.

---

## 6. 신규 — Argo CD Application

### sync-wave 순서

| wave | 대상 | 왜 이 순서인가 |
|---|---|---|
| −30 | `AppProject boa` | 나머지 전부의 전제 |
| −25 | cert-manager | 오퍼레이터 웹훅 인증서를 발급한다. 없으면 CR 적용이 `failed calling webhook` 으로 멈춘다 |
| −20 | opentelemetry-operator | CRD 와 자동계측 웹훅을 만든다 |
| −15 | whatap-operator | 와탭 쿠버네티스 에이전트 (클러스터 지표) |
| −10 | 앱 4개 (기존) | |
| −5 | `boa-observability` | 우리가 작성한 CR |

**플랫폼이 앱보다 앞이라는 것이 핵심이다.** 앱보다 늦으면 앱 파드가 먼저 떠서
어노테이션이 무시된 채 기동하고, 계측을 붙이려면 파드를 한 번 더 굴려야 한다.

`boa-observability` 가 앱(−10)보다 늦은 −5 인 것은 CRD 가 확실히 존재하게
하려는 것이다. 첫 배포에서 앱이 계측 없이 뜨면 `kubectl rollout restart` 한 번이
필요하다. 순서를 확실히 하려면 −12 로 내리되, 플랫폼 Application 이 Healthy 가
된 것을 확인한 뒤 내린다.

### `ServerSideApply=true` 를 켠 곳

cert-manager · 오퍼레이터 · 와탭 · `boa-observability` 넷 전부. CRD 와
`OpenTelemetryCollector` 의 `config` 가 커서 `kubectl apply` 의 어노테이션 크기
한계(262144 바이트)를 넘는다.

### `ignoreDifferences`

- 수집기 Deployment 의 `/spec/replicas` — 오퍼레이터가 관리한다
- `whatap-observability` · `grafana-admin` Secret 의 `/data` — CSI 가 만든다.
  Git 에 없으므로 Argo CD 가 지우려 들지 않게 한다

---

## 7. 배포 절차

Terraform 을 먼저 끝내고 출력값 6개를 매니페스트에 채운 뒤 커밋한다.

```bash
# ① Infra 먼저 (Infra/docs/plans/observability-changelog.md 5항)
cd Infra/aws-observability && terraform apply

# ② 출력값을 매니페스트에 반영
cd ../../gitops/03_manifests/overlays/eks/observability
#   grafana.yaml         targetGroupARN        ← terraform output -raw grafana_target_group_arn
#   grafana.yaml         groupID               ← terraform -chdir=../../../../../Infra/aws-ops output -raw ops_alb_security_group_id
#   collector-gateway.yaml  awss3.s3_bucket    ← terraform output -raw telemetry_bucket_name

# ③ 렌더 확인 — 7개 경로 전부
cd ../../..
for p in overlays/eks overlays/gke overlays/eks/observability overlays/gke/observability \
         overlays/eks/applications overlays/gke/applications base/observability; do
  kubectl kustomize "$p" > /dev/null && echo "OK  $p"
done

# ④ 계측 어노테이션이 양쪽에 살아 있는지
for o in eks gke; do
  echo "$o java=$(kubectl kustomize overlays/$o | grep -c inject-java) python=$(kubectl kustomize overlays/$o | grep -c inject-python)"
done   # 둘 다 java=3 python=3

# ⑤ 커밋 후 루트 Application 적용
kubectl apply -f 01_bootstrap/root-application-eks.yaml
```

> ⚠️ **`dev-0922` 전환이 먼저다.** 라이브 Argo CD 는 아직 `dev` 를 본다. 전환 순간
> base/overlay 재편 전체가 한 번에 적용되므로, 팀이 전환을 끝낸 뒤 이 브랜치를
> 병합한다. 반대로 하면 관측 변경이 재편 롤백에 휩쓸린다.

### 자리표시자 3곳

```
overlays/eks/observability/grafana.yaml         targetGroupARN  .../boa-grafana-tg/REPLACE_ME
overlays/eks/observability/grafana.yaml         groupID         sg-REPLACE_ME
overlays/eks/observability/collector-gateway.yaml  s3_bucket    boa-telemetry-archive-769413326616
```

S3 버킷 이름은 계정 ID 기반이라 맞을 가능성이 높지만 `terraform output` 으로
확인한다.

---

## 8. 미결 항목

결정 시한 — **발표 1주 전**.

| # | 미결 | 확인 방법 | 영향 |
|---|---|---|---|
| 1 | **A안 vs C안 미결** — 이 코드는 A안(오픈텔레메트리 허브 + 와탭 쿠버네티스 에이전트)이다 | 팀 결정 사항 | C안은 와탭 네이티브 APM 을 더한다. 그러면 어노테이션이 `apm.instrumentation` 으로 바뀌고 이 코드의 `Instrumentation` CR 과 **동시 사용 불가** |
| 2 | `spec.additionalContainers` 가 v1beta1 CRD 에 있는가 | `kubectl explain opentelemetrycollectors.spec --recursive \| grep additionalContainers` | 없으면 와탭 사이드카를 평범한 Deployment 로 만들어야 한다 |
| 3 | **gunicorn 프리포크** — Python 3종 `CMD` 가 `--threads N` 이고 `--workers` 가 없다(기본 1). 마스터가 워커를 포크하므로 포크 전 초기화한 SDK 가 동작하지 않을 수 있다 | 적용 후 와탭에 frontend 트레이스가 실제로 들어오는지 | `gunicorn.conf.py` 의 `post_fork` 훅이 필요하면 **이미지 재빌드 = 앱 코드 수정.** R&R 이 바뀐다 |
| 4 | **`frontend/logging.conf` 의 `propagate=0`** — `[logger_frontend]` 가 루트 로거에 붙는 OTel 핸들러를 타지 않는다 | 와탭·수집기에 frontend 애플리케이션 로그가 들어오는지 | 안 들어오면 `logging.conf` 수정 = **이미지 재빌드.** 대안은 stdout 만 수집 |
| 5 | 수집기 파드 레이블이 NetworkPolicy 의 `app.kubernetes.io/name: otel-collector` 와 일치하는가 | `kubectl -n monitoring get pod --show-labels` | 다르면 OTLP 가 전부 막힌다. 급하면 `podSelector` 를 빼고 `namespaceSelector` 만 남긴다 |
| 6 | **관측용 AppProject 분리** | 3.4항 참조 | 지금은 `boa` 프로젝트 권한을 넓혔다. 앱 Application 도 ClusterRole 을 만들 수 있다 |
| 7 | Helm 차트 버전 3개가 유효한가 | `helm search repo` 또는 Argo CD 동기화 | 존재하지 않는 버전이면 Application 이 `ComparisonError` |
| 8 | 와탭 오퍼레이터 차트의 라이선스 시크릿 필드 이름 | apply 후 `helm show values whatap-operator/whatap-operator` | 차트 버전에 따라 키 이름이 다르다. `valuesObject` 를 고쳐야 할 수 있다 |
| 9 | GKE `otel-collector` SA 의 Workload Identity 바인딩 | `gcloud iam service-accounts get-iam-policy <GSA>` | 없으면 GCP exporter 가 자격증명 없이 실패. **인프라 담당** |
| 10 | GKE 앱 `replicas: 1` vs Terraform 주석 "replicas 0" | 팀 결정 사항 | 대기 사이트 관측 검증 방식이 갈린다 |
| 11 | 노드 용량 — 추가 파드 약 13개 | `kubectl describe node` 의 Allocated resources | `t3.medium` 은 슬롯 17개뿐. 데몬셋이 먼저 찬다 |
| 12 | 계측 후 지연 증가폭 | 계측 전후 `p95` 비교 | 큰 폭이면 샘플러 비율을 1.0 에서 낮춘다 |

---

## 9. 수정 — 2026-09-26 검토에서 나온 결함 2건

런북과 대조하다가 발견한 것이다. 둘 다 **파드는 정상 기동하는데 데이터만 안 들어오는** 유형이라 배포 후에는 찾기 어렵다.

### 9.1 `WhatapAgent` CR 이 없었다 — 경로 4가 통째로 빠졌다

`whatap-operator` 차트는 Application 으로 배포되는데 **CR 이 저장소 어디에도 없었다**(`grep -rn "kind: WhatapAgent"` 0건).

오퍼레이터는 CR 을 감시하다가 그것이 생겨야 에이전트를 만든다. CR 이 없으면 `whatap-monitoring` 에 오퍼레이터 파드 하나만 뜨고 **master-agent 도 node-agent 도 생기지 않는다.** 와탭 쿠버네티스 제품 화면이 비는데, 오퍼레이터가 `Healthy` 라서 Argo CD 상으로는 정상으로 보인다.

추가 — `overlays/{eks,gke}/observability/whatap-agent.yaml` (+2줄 kustomization 등록)

| 설정 | 값 | 이유 |
|---|---|---|
| `masterAgent.enabled` | true | 클러스터 구성 정보 |
| `nodeAgent.enabled` | true | 노드·파드·컨테이너 지표 |
| `nodeAgent.runtime` | containerd | EKS AL2023 · GKE 공통 |
| `nodeAgent.runtimeSocketPath` | `/var/run/containerd/containerd.sock` | 문서 기본값 |
| `gpuMonitoring.enabled` | false | GPU 노드 없음 |
| `apm.instrumentation` | **비워 둠** | `Instrumentation` CR 과 동시 사용 불가 |

**자격증명이 이 네임스페이스만 다르다.** 쿠버네티스 Secret 은 네임스페이스를 넘지 못하는데, `secrets.yaml` 이 만드는 `whatap-observability` 는 `monitoring` 에 있고 에이전트는 `whatap-monitoring` 에 있다. 게다가 Terraform 의 Pod Identity 연결(`aws-modules/observability/iam.tf:168,300`)이 `observability_namespace` 의 `otel-collector` · `grafana` 두 SA 에만 걸려 있어 `whatap-monitoring` 에서는 Secrets Manager 를 읽을 권한 자체가 없다.

그래서 **이 Secret 하나만 사람이 한 번 만든다.** 와탭 공식 설치 절차와 같은 방식이고, 라이선스 키를 Git 에 넣지 않는다는 원칙은 그대로다.

```
kubectl create secret generic whatap-credentials \
  --namespace whatap-monitoring \
  --from-literal WHATAP_LICENSE=<쿠버네티스 제품 라이선스> \
  --from-literal WHATAP_HOST=<수집 서버 주소> \
  --from-literal WHATAP_PORT=6600
```

### 9.2 사이드카 환경변수 이름이 쿠버네티스 에이전트 것이었다

`collector-gateway.yaml` 의 `whatap-otel` 사이드카가 `WHATAP_LICENSE` · `WHATAP_HOST` · `WHATAP_PORT` 를 쓰고 있었다. **값은 맞았다**(`application_license` 를 제대로 참조). 이름이 틀렸다.

| 이전 | 이후 | 비고 |
|---|---|---|
| `WHATAP_LICENSE` | `WHATAP_ACCESSKEY` | 앞은 쿠버네티스 에이전트 변수명 |
| `WHATAP_HOST` | `WHATAP_SERVER_HOST` | 형식이 `1.1.1.1/2.2.2.2` — IP 두 개 |
| `WHATAP_PORT` (시크릿에서) | `WHATAP_OTEL_GRPC_SERVER_PORT: "6600"` (상수) | **의미가 다르다.** 뒤는 사이드카가 *받을* 포트이고 수집 서버 포트가 아니다 |

근거 — `docs.whatap.io/opentelemetry/install-agent` 의 "환경 변수로 설정하기" 절과 같은 문서의 Docker Compose · Kubernetes 예제. 세 곳 모두 `WHATAP_ACCESSKEY` / `WHATAP_SERVER_HOST` / `WHATAP_OTEL_GRPC_SERVER_PORT` 만 쓴다.

### 검증

`kubectl kustomize` 로 확인했다.

| | EKS | GKE |
|---|---|---|
| `observability` 오버레이 리소스 수 | 16 | 12 |
| `kind: WhatapAgent` | 1 | 1 |
| `WHATAP_ACCESSKEY` | 1 | 1 |
| 구 변수명 잔존 | 0 | 0 |
| 상위 오버레이 렌더 | OK | OK |

CRD 스키마 검증은 여전히 하지 않았다 — 오퍼레이터가 설치된 클러스터가 필요하다.

### 미결에 추가

| # | 미결 | 확인 방법 | 영향 |
|---|---|---|---|
| 13 | `whatap-otel` 이 `WHATAP_SERVER_HOST` 에 **단일 IP** 를 받는가 | 사이드카 로그(`log_stdout_enabled=true`). 접속 실패면 `IP1/IP2` 형식으로 시크릿 값을 바꾼다 | 안 되면 사이드카가 와탭에 못 붙는다. 수집기는 정상으로 보인다 |
| 14 | `whatap-monitoring` 의 `whatap-credentials` 를 누가 언제 만드는가 | 9.1의 명령. **클러스터를 다시 만들면 사라진다** | 없으면 에이전트가 `CreateContainerConfigError` |
| 15 | 와탭 콘솔 "APM 자동 설치" 가 꺼진 상태로 설치 파일을 받았는가 | 콘솔 관리 > 에이전트 설치 화면 | 켜져 있으면 CR 에 `apm` 이 들어와 계측이 이중으로 붙는다 |

### 9.3 로그의 CloudWatch 경로를 앱 로그로 좁혔다 — EKS 만

**질문** — 지표와 로그를 이미 와탭이 받는데 CloudWatch Logs 로 또 보낼 이유가 있는가.

**답** — 있다. 다만 대상이 너무 넓었다.

`/aws/eks/boa-eks/application` 은 `awscloudwatchlogs` 가 쓰는 로그 그룹이고, **Terraform 이 이 그룹에만 감사 통제 3층을 걸어 두었다.**

| 층 | 무엇 | 위치 |
|---|---|---|
| 1 | 수집기 `redaction` + `transform` — 쓰기 전 마스킹 | `collector-gateway.yaml` |
| 2 | CloudWatch Logs 데이터 보호 정책 — 읽기 시점 마스킹 | `aws-modules/observability/main.tf:142` |
| 3 | `logs:Unmask` 권한 분리 — 수집기·Grafana 는 `DenyUnmask`, 별도 정책을 의도적으로 붙여야만 원본을 본다 | `iam.tf:74,256,322` |

감사 발견 사항은 별도 로그 그룹(`/aws/logs-data-protection/boa-eks`)으로 빠진다.

**와탭과 S3 에는 이 통제가 없다.** 와탭 쪽 대응물인 콘솔 「사용자 행위」는 조회가 62일로 제한되고, S3 에는 마스킹 해제라는 개념 자체가 없다(마스킹된 것만 저장된다). 즉 **CloudWatch Logs 가 마스킹 해제를 추적할 수 있는 유일한 목적지**다. 경로를 빼면 Terraform 의 통제 3층이 동작할 대상을 잃는다.

그래서 **경로는 유지하고 대상만 좁혔다.**

```yaml
processors:
  filter/app-only:
    error_mode: ignore
    logs:
      log_record:
        - 'resource.attributes["k8s.namespace.name"] != "bank-of-anthos"'

service:
  pipelines:
    logs:                                    # 전량
      exporters: [otlp/whatap, awss3]
    logs/audit:                              # 앱 로그만
      processors: [… redaction, transform, filter/app-only, batch]
      exporters: [awscloudwatchlogs]
```

| | 이전 | 이후 |
|---|---|---|
| CloudWatch Logs 수집 대상 | 앱 + 플랫폼 | **앱만** |
| 와탭 · S3 | 전량 | 전량 (변화 없음) |
| 감사 통제 대상 | 유지 | 유지 |

**프로세서 순서** — `filter` 는 `redaction`·`transform` **뒤**, `batch` **앞**이다. 마스킹은 세 목적지 모두에 걸려야 하므로 필터보다 앞서야 하고, 버릴 것은 배치 전에 버려야 배치가 작아진다.

**GKE 는 해당 없다.** GKE 의 `logs` 파이프라인은 `[otlp/whatap]` 하나뿐이다 — `logging.googleapis.com/kubernetes` 가 이미 컨테이너 stdout 을 Cloud Logging 에 넣고 있어 `googlecloud` exporter 를 애초에 뺐다. **마스킹 규칙은 양쪽이 여전히 동일하다.** 이번에 갈라진 것은 목적지 라우팅이지 마스킹이 아니다.

### 9.4 지표의 CloudWatch 경로(`awsemf`)는 그대로 둔다

빼면 **Grafana 에 앱 지표가 한 개도 안 나온다.** `grafana.yaml` 의 데이터소스가 CloudWatch 하나뿐이다(`type: cloudwatch`, uid `cloudwatch-apne2`). CloudWatch 알람을 걸 수 있는 유일한 경로이기도 하다.

이미 좁혀져 있다 — `dimension_rollup_option: NoDimensionRollup` 에 `metric_declarations` 로 `http.server.*` · `jvm.memory.*` · `jvm.gc.*` · `db.client.*` 4종만 고른다. 차원을 비워 두면 모든 속성이 차원이 되어 사용자 지정 지표가 조합 수만큼 생성되고 **요금이 지표 개수로 곱해진다.**

### 검증 (9.1 ~ 9.4 누적)

`kubectl kustomize` 7개 경로 전부 렌더 성공. `logs/audit` 파이프라인과 `filter/app-only` 가 렌더 결과에 나오고, 계측 어노테이션은 EKS·GKE 모두 `inject-java` 3 · `inject-python` 3 으로 회귀 없음.

---

## 10. Argo CD 첫 배포에서 드러난 Helm 결함 두 건 (2026-09-26)

`dev-0922` 병합 뒤 실제 클러스터에 싱크하니 `boa-observability` 가 **OutOfSync / Missing**
으로 멈췄다. 원인은 둘 다 `applications/observability-platform.yaml` 이었다.

### 10.1 OpenTelemetry 오퍼레이터 — 차트에 없는 values 키

```
admissionWebhooks:
  autoInstrumentationWebhook:     # ← 차트 0.99.0 에 없는 키
    enabled: true
```

차트 `values.schema.json` 의 `admissionWebhooks` 가 **`additionalProperties: false`** 라
스키마 검증에서 막히고, Helm 이 렌더를 시작하지도 못한다. Argo CD 가 보는 증상은
"설치가 시작되지 않음"이다. 저장소·차트 버전 자체는 정상이었다.

**확인한 것** — `opentelemetry-operator-0.99.0.tgz` 를 내려 직접 읽었다.

| | 값 |
|---|---|
| 스키마가 허용하는 `admissionWebhooks` 하위 키 | create · servicePort · failurePolicy · secretName · pods · namePrefix · timeoutSeconds · namespaceSelector · objectSelector · certManager · autoGenerateCert · certFile · keyFile · caFile · serviceAnnotations · secretAnnotations · secretLabels |
| 계측 주입 웹훅을 켜는 스위치 | **없다.** `admissionWebhooks.create`(기본 `true`)면 파드 변경 웹훅 `mpod.kb.io` 가 무조건 생성된다 (`templates/admission-webhooks/operator-webhook-with-cert-manager.yaml:91`) |
| `manager.resources` | 유효하다 (`values.yaml:108`). 이건 문제가 아니었다 |

그래서 잘못된 블록을 **지우는 것이 곧 수정**이다. 기능은 줄지 않는다. 대신 스키마가
지원하는 `admissionWebhooks.pods.failurePolicy: Ignore` 를 명시했다 — 웹훅 파드가
준비되기 전이라도 앱 파드 생성이 막히지 않는다. 트레이드오프는 그 사이에 뜬 파드에
계측이 붙지 않는 것이고, 회피 방법은 앱 파드를 한 번 굴리는 것이다.

### 10.2 와탭 오퍼레이터 — Helm 저장소 주소가 404

`https://whatap-cloud.github.io/whatap-operator` 는 존재하지 않는다. `index.yaml` 이
404 라 차트 다운로드 자체가 실패했다.

**확인한 것** — GitHub 조직 `whatap-cloud` 는 공개 저장소가 없고, 차트는 `whatap/helm`
저장소에 있다. 두 차트 버전의 README 가 모두 같은 주소를 안내한다.

```
helm repo add whatap https://whatap.github.io/helm/     # README.md:13
```

| 항목 | 이전 | 이후 |
|---|---|---|
| `repoURL` | `https://whatap-cloud.github.io/whatap-operator` (404) | `https://whatap.github.io/helm` |
| `targetRevision` | 1.7.6 | **1.9.11** |

**버전을 올린 이유 두 가지.**

1. **1.7.6 은 오퍼레이터 이미지를 `latest` 로 당긴다** (`values.yaml:4`, `pullPolicy: Always`).
   Git 을 안 건드려도 오퍼레이터 바이너리가 바뀔 수 있다는 뜻이고, DR 기준선으로 쓸 수 없다.
   1.9.11 은 `appVersion: 3.0.20` 으로 고정된다.
2. **`nodeAgent.runtimeSocketPath` 가 1.7.6 CRD 에는 없다.** 우리 `WhatapAgent` CR 이 그
   필드를 쓰는데, 구조 스키마 pruning 때문에 **오류 없이 조용히 잘려 나간다.** 1.9.11
   CRD 에는 있다(`crd-whatapagents.yaml:5983`).

1.9.11 이 CRD 3종(`WhatapPodMonitor` · `WhatapServiceMonitor` · `WhatapStaticEndpoint`)을
더 설치하지만 쓰지 않으므로 무해하다. CRD 가 커서 `ServerSideApply=true` 가 필요한데
이미 켜져 있다.

### 10.3 같이 고친 values 오류 — 라이선스 시크릿 참조

```
whatap:
  licenseSecret:            # ← 차트에 없는 키. 아무 일도 하지 않았다
    name: whatap-observability
    key: kubernetes_license
```

와탭 차트에는 `values.schema.json` 이 **없다.** 그래서 이 블록은 렌더를 깨뜨리지 않고
**조용히 무시됐다** — 10.2 를 고쳐 차트가 내려오기 시작하면 그때 문제가 될 자리였다.

차트가 실제로 보는 값은 `credentials.{create,license,host,port}` 하나뿐이고,
**시크릿 이름은 `whatap-credentials` 로 고정되어 있다**
(`templates/secret-whatap-credentials.yaml:6`). values 로 바꿀 수 없다. 키 이름도
`WHATAP_LICENSE` · `WHATAP_HOST` · `WHATAP_PORT` 로 고정이다.

`credentials.create: false` 로 두어 차트가 시크릿을 만들지 않게 했다. 라이선스는
Git 에 들어가지 않고, 사람이 한 번 만든다 —
`overlays/*/observability/whatap-agent.yaml` 머리말의 명령 그대로다.

### 10.4 정정 — 로그 삼중 수집 우려는 근거가 없었다

`observability-platform.yaml` 머리말에 "와탭 노드 에이전트가 컨테이너 로그를 수집하므로
끄지 않으면 같은 로그가 세 번 들어간다"고 적어 두었는데, **틀렸다.**

`WhatapAgent` CRD(1.9.11)에 로그 수집 필드가 **아예 없고**,
`templates/agent-node-configmap.yaml` 이 만드는 `whatap.node.conf` 에도 로그 설정이
없다. 노드 에이전트는 노드·파드·컨테이너 **자원 지표만** 보낸다. 우리 수집기의
`filelog` 와 겹치지 않는다. 주석을 근거와 함께 고쳤다.

### 검증

`kubectl kustomize` EKS·GKE 12개 오버레이 루트 전부 렌더 성공. `WhatapAgent` 렌더 결과에
`runtimeSocketPath` 가 남아 있고, 계측 어노테이션은 `inject-java` 3 · `inject-python` 3
으로 회귀 없음.

**여전히 검증 못 한 것** — 차트 1.9.11 오퍼레이터(이미지 3.0.20)의 실제 동작. 확인
방법은 싱크 후 `kubectl -n whatap-monitoring get deploy,ds` 로 master-agent 1개 ·
node-agent 노드 수만큼이 Ready 인지, 그리고 와탭 쿠버네티스 프로젝트 화면에 노드가
올라오는지 본다.

---

## 11. 시크릿 자동화 — External Secrets Operator 도입 (2026-09-26)

마운트 전용 파드와 수동 `kubectl create secret` 을 둘 다 없앴다. 범위는 **EKS 의 관측 스택만**이다. 앱 시크릿(`overlays/eks/shared/`)은 CSI 를 그대로 쓴다.

### 11.1 왜 바꿨나

Secrets Store CSI 드라이버는 컨트롤러가 아니라 **볼륨 플러그인**이다. "누군가 볼륨을 마운트할 때"만 Secrets Manager 를 읽는다. 그런데 수집기와 Grafana 는 볼륨을 쓰지 않고 `secretKeyRef` 로 env 만 읽는다. 아무도 마운트하지 않으면 Secret 이 영영 생기지 않는다.

그래서 아무 일도 하지 않는 파드(`observability-secret-sync`)를 일부러 띄워 뒀었다. 여기서 세 가지가 따라왔다.

1. 그 파드가 죽으면 Secret 이 갱신되지 않는다.
2. CSI 는 **마운트한 파드의 자격증명**으로 읽는다. 네임스페이스마다 Pod Identity 연결이 필요하고, `whatap-monitoring` 에는 없어서 자동화가 불가능했다.
3. 회전이 기본 꺼짐이라 키를 재발급해도 반영되지 않을 가능성이 있었다.

GKE 는 이미 `SecretSync` **컨트롤러**를 쓰고 있어 이 문제가 없다. EKS 만 격차가 있었다.

### 11.2 무엇이 생기고 사라졌나

| | 이전 | 이후 |
|---|---|---|
| `monitoring` 시크릿 공급 | SecretProviderClass + pause 파드 | `ExternalSecret` 2개 |
| `whatap-credentials` | 사람이 `kubectl create secret` | `ExternalSecret` (자동) |
| 마운트 전용 파드 | 1개 (관측) | 0개 |
| 키 회전 | 불확실 | `refreshInterval: 1h` |

신규 디렉터리 `overlays/eks/bootstrap/` — `Namespace`(whatap-monitoring) · `ClusterSecretStore`(boa-aws) · `ExternalSecret`(whatap-credentials).

신규 Application 2개 — `boa-external-secrets`(wave −28, Helm `external-secrets` 2.11.0) · `boa-observability-bootstrap`(wave −22).

### 11.3 순서가 까다로운 지점

**와탭 오퍼레이터 Deployment 자체가 `whatap-credentials` 를 `secretKeyRef` 로 읽고 `optional` 이 아니다**(차트 1.9.11 `templates/operator-deployment.yaml`). 시크릿이 없으면 오퍼레이터 파드가 기동조차 못 한다. 그 Application 은 wave −15 다.

그래서 시크릿을 만드는 것을 관측 Application(−5)이 아니라 **별도 Application(−22)** 으로 뺐다. `whatap-monitoring` 네임스페이스도 거기서 명시적으로 만든다 — `CreateNamespace=true` 는 −15 라 늦고, 자동 생성된 네임스페이스에는 PSA 라벨을 붙일 수 없다.

**남은 틈** — Argo CD 는 모르는 사용자 정의 리소스를 기본적으로 Healthy 로 친다. `ExternalSecret` 을 적용하자마자 다음 wave 로 넘어가므로 실제 Secret 생성까지의 몇 초는 보장되지 않는다. 그동안 오퍼레이터 파드는 `CreateContainerConfigError` 로 기다리다 kubelet 재시도로 회복한다. 엄밀히 막으려면 `argocd-cm` 에 `ExternalSecret` 헬스 판정을 넣어야 한다(미결).

### 11.4 확인한 것

차트 원본(`external-secrets-2.11.0.tgz`)을 내려 직접 읽었다.

- API 는 **`external-secrets.io/v1`** 이다. `v1beta1` 은 폐기 대상이고 `crds.unsafeServeV1Beta1` 이 기본 `false`.
- `ClusterSecretStore.spec.conditions` 는 `namespaces` · `namespaceRegexes` · `namespaceSelector` 를 받는다. `namespaces` 로 `monitoring` · `whatap-monitoring` 두 곳만 허용했다.
- `serviceAccount.name` 을 명시했다. Pod Identity 연결이 (클러스터, 네임스페이스, SA) **문자열 일치**로만 동작하므로 차트 기본값에 맡기면 어긋났을 때 조용히 실패한다.
- `auth` 블록은 일부러 비웠다. 적지 않으면 컨트롤러 파드의 기본 자격증명 사슬을 쓰고, Pod Identity 가 거기에 붙는다. `auth.secretRef` 를 쓰면 "시크릿을 읽기 위한 시크릿"이 생겨 문제가 원점으로 돌아간다.

### 11.5 같이 고친 결함 — AppProject 의 와탭 저장소 주소

9항에서 Application 의 `repoURL` 을 고쳤는데 **AppProject 의 `sourceRepos` 는 옛 주소 그대로였다**(EKS·GKE 양쪽). 이대로면 Application 이 `repo ... is not permitted in project` 로 막힌다. 두 곳이 문자열로 정확히 같아야 한다. 양쪽 다 `https://whatap.github.io/helm` 로 맞췄다.

AppProject 에 `external-secrets` 네임스페이스와 `ClusterSecretStore`(클러스터 스코프)도 추가했다.

### 11.6 PSA 라벨 — 그리고 정정

`monitoring` 과 `whatap-monitoring` 에 파드 보안 어드미션 라벨을 붙였다. 둘 다 `enforce: privileged` · `audit: baseline` 이다.

**여기서 이전 판단을 정정한다.** 두 네임스페이스를 나눠 두는 근거로 "PSA 로 특권 허용 범위를 한 칸에 가둔다"를 들었는데, **`monitoring` 도 `privileged` 여야 한다.** `otel-agent` DaemonSet 이 `/var/log/pods` 와 `/var/lib/docker/containers` 를 hostPath 로 마운트하고(`collector-agent.yaml`), baseline 수준은 hostPath 볼륨을 금지하기 때문이다. EKS·GKE 양쪽 동일하다.

즉 **PSA 는 두 네임스페이스를 구별해 주지 못한다.** 분리의 근거로 남는 것은 와탭 지원 구성 준수와 RBAC 사고 범위뿐이고, 둘 다 약하다. 다만 ESO 도입으로 분리의 *비용*(수동 시크릿)이 0이 되었으므로 합칠 이유도 없어졌다 — 현상 유지가 합리적이다.

라벨 자체는 값이 있다. `audit: baseline` 이 "지금 아는 그 DaemonSet 말고 다른 것이 baseline 을 어기면" 감사 로그에 남긴다. 열어 둔 것이 **의도된 예외임을 코드로 남기는 것**이 목적이다.

**아직 안 한 것** — `bank-of-anthos` 네임스페이스에는 PSA 라벨을 붙이지 않았다. 앱 파드 6종이 `restricted` 를 통과하는지 확인되지 않았고, 그 파일은 앱 담당 영역이다. 제안은 `warn: restricted` 로 먼저 한 번 돌려 무엇이 걸리는지 보는 것이다. **PSA 가 실제로 무언가를 막을 수 있는 곳은 거기뿐이다.**

### 11.7 이 변경만으로는 동작하지 않는다

**Terraform 변경이 필요하다.** `Infra/aws-modules/observability/iam.tf` 에 다음이 있어야 ESO 컨트롤러가 Secrets Manager 를 읽는다.

- IAM 역할 + 정책 — `secretsmanager:GetSecretValue`·`DescribeSecret` 를 `secret:/boa/observability*` 로 한정
- `aws_eks_pod_identity_association` — ns `external-secrets`, sa `external-secrets`

이관이 끝나면 `boa-eks-otel-collector-policy` 의 `ReadObservabilitySecrets` 문을 **빼야 한다.** 수집기 SA 는 더 이상 Secrets Manager 를 읽을 필요가 없고, 그 SA 는 파드 4종이 공유하므로 빼면 순유출량이 줄어든다.

### 검증

`kubectl kustomize` EKS·GKE 12개 오버레이 루트 + 신규 `bootstrap` 전부 렌더 성공. `SecretProviderClass` 와 pause 파드가 관측 오버레이에서 사라졌고, 계측 어노테이션은 `inject-java` 3 · `inject-python` 3 으로 회귀 없음.

**실행으로만 확인되는 것** — ESO 2.11.0 이 EKS Pod Identity 를 실제로 집는지. 확인 방법 — 싱크 후 `kubectl -n external-secrets logs deploy/external-secrets` 에 자격증명 오류가 없는지, 그리고 `kubectl -n whatap-monitoring get externalsecret whatap-credentials` 가 `SecretSynced` 인지 본다. IRSA 만 지원하는 구성이면 SA 에 IRSA 어노테이션을 다는 경로로 바꿔야 한다.

---

## 12. EKS CloudWatch 전송 임시 비활성화 (2026-09-26)

비용과 데이터 보호 정책 복잡도를 다시 검토할 때까지 OTel Gateway 의 CloudWatch
전송을 중단했다. `awscloudwatchlogs`·`awsemf` exporter와 `logs/audit` 파이프라인을
제거했고, metrics 파이프라인은 `otlp/whatap`만 사용한다.

- trace: Whatap + S3
- metric: Whatap
- log: Whatap + S3

기존 CloudWatch 로그 그룹과 과거 데이터는 삭제하지 않는다. 공통 `redaction`·
`transform` processor도 유지하므로 Whatap과 S3로 나가는 데이터의 사전 마스킹은
계속 적용된다.

배포 브랜치 병합 전에 `boa-observability-bootstrap`의 `targetRevision`도 `HEAD`에서
`dev-0922`로 고정했다. 루트 Application이 추적하는 브랜치와 자식 Application이
읽는 브랜치가 달라 신규 bootstrap 디렉터리를 찾지 못하는 상황을 막기 위해서다.
