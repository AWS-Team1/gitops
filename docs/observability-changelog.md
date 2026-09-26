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
