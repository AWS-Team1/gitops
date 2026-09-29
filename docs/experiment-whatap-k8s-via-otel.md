# 실험 — 와탭 쿠버네티스 화면을 OTel 로 채울 수 있는가

`master-agent`·`node-agent` 를 뺄 수 있는지 판정한다.
**브랜치 `exp/whatap-k8s-via-otel`. 발표 전에는 적용하지 않는다.**

## 왜 하는가

클러스터 데이터를 두 경로가 따로 모은다.

```
OTel   : otel-agent(kubeletstats·hostmetrics) + otel-cluster(k8s_cluster)
         → 게이트웨이 → whatap-otel(6601) → 와탭 애플리케이션 프로젝트
와탭   : master-agent · node-agent → 와탭 쿠버네티스 프로젝트 (게이트웨이 우회)
```

같은 사실을 두 번 모아 두 번 보낸다. 전송량도 두 몫이다.

### 마스킹은 이 판단의 근거가 아니다

한때 "와탭 에이전트 경로가 마스킹을 우회한다"를 제거 근거로 적었으나 **철회한다.**

- 와탭 문서가 밝힌 에이전트 수집 범위는 **"컨테이너의 CPU, Memory, Disk(Volume), Network"** 와 **"Namespace, Deployment, ReplicaSet, Pod 등 클러스터 구성 요소"** 다. 계좌번호·JWT 가 들어갈 자리가 없다. 컨테이너 로그 수집은 별개 기능이고 우리는 켜지 않았다.
- 게다가 **우리 게이트웨이도 metrics 파이프라인에는 마스킹을 걸지 않는다.** `redaction`·`transform` 은 traces·logs 에만 있다. 지표는 값 자체에 민감정보가 없어 대상이 아니다.

즉 양쪽 모두 같은 종류의 데이터를 같은 방식으로 보낸다. 에이전트를 빼도 닫히는 구멍이 없다.
**제거 근거는 중복 제거와 구성 단순화뿐이다.**

### 수집 범위는 이미 OTel 이 덮는다

| 와탭 문서의 수집 범위 | OTel 대응 |
|---|---|
| 컨테이너 CPU · Memory | `kubeletstats` `metric_groups: [node, pod, container]` |
| Disk(Volume) | `kubeletstats` + `hostmetrics.disk`·`filesystem` |
| Network | `hostmetrics.network` |
| Namespace·Deployment·ReplicaSet·Pod 등 | `k8s_cluster` |

OTel 이 더 넓은 지점도 있다 — `node_conditions_to_report` 에 `MemoryPressure`·`DiskPressure`·`PIDPressure`, `k8sobjects` 의 `type=Warning` 이벤트(`OOMKilled`·`FailedScheduling`), `hostmetrics` 의 노드 OS 지표.

**그래서 남은 질문은 하나다 — 와탭이 OTLP 로 받은 `k8s.*` 지표로 쿠버네티스 화면을 그려 주는가.**

## 무엇이 바뀌었나

| 파일 | 변경 |
|---|---|
| `overlays/eks/observability/secrets.yaml` | `whatap-observability` 에 `kubernetes_license` 추가 |
| `overlays/eks/observability/collector-gateway.yaml` | 사이드카 `whatap-otel-k8s`(6602) · exporter `otlp/whatap_k8s` · 프로세서 `filter/k8s_only` · 파이프라인 `metrics/k8s` |

기존 `metrics` 파이프라인은 **건드리지 않았다.** 실험 중에는 인프라 지표가 두 프로젝트로 모두 간다 — 기존 화면이 살아 있어야 비교가 된다.

사이드카가 둘인 이유는 `WHATAP_ACCESSKEY` 가 단수여서다. 프로젝트가 둘이면 컨테이너도 둘이다.

```
6601 = 애플리케이션 프로젝트 (트레이스·지표·로그 전량)
6602 = 쿠버네티스 프로젝트   (filter 로 거른 k8s.*·container.*·system.* 만)
```

`filter` 가 없으면 `jvm.*`·`http.server.*` 같은 앱 런타임 지표까지 쿠버네티스 프로젝트로 간다. 파이프라인이 출처가 아니라 신호 종류로 나뉘기 때문이다.

## 순서 — 거꾸로 하면 판정이 안 된다

```
1. 브랜치 적용                     에이전트는 켜 둔 채
2. otc-container 로그 확인          filter 구문이 받아들여졌는지
3. 사이드카 로그 확인               6602 접속이 성립했는지
4. 10분 대기 후 와탭 두 프로젝트 비교
5. nodeAgent.enabled: false 로 기준선 분리
6. 10분 더 관찰 → 판정
```

**5번을 1번 앞에 두면 안 된다.** 에이전트를 먼저 끄면 화면이 비었을 때 그게 OTel 이 못 채워서인지 에이전트를 꺼서인지 구분되지 않는다.

### 2. 수집기가 기동하는지 — 가장 먼저

```bash
kubectl -n monitoring logs deploy/otel-gateway-collector -c otc-container --tail=50
```

`filter` 의 `include`/`match_type` 구문이 이 수집기 버전(0.137.0)에서 받아들여지는지 **실행으로 확인하지 않았다.** 거부되면 파이프라인 구성 단계에서 실패해 수집기가 통째로 안 뜬다 — 변경 내역 19항의 RE2 사고와 같은 종류다.

거부되면 OTTL 형식으로 바꾼다.

```yaml
      filter/k8s_only:
        error_mode: ignore
        metrics:
          metric:
            - 'not IsMatch(name, "^(k8s|container|system)\\.")'
```

### 3. 사이드카가 붙는지

```bash
kubectl -n monitoring logs deploy/otel-gateway-collector -c whatap-otel-k8s --tail=50
```

액세스 키가 쿠버네티스 프로젝트 것이라 거부될 수 있다 — 그게 이 실험의 핵심 가설이다.
거부 메시지가 나오면 **그 자리에서 실패 판정**이고 4~6번은 하지 않는다.

### 4·6. 무엇을 보는가

와탭 콘솔 → 쿠버네티스 프로젝트 `boa-aws-eks`(코드 51071)

| 보는 곳 | 판정 |
|---|---|
| 노드·파드 목록이 채워지나 | 채워지면 성공 |
| 리소스 사용량 그래프에 값이 오나 | 값이 없으면 스키마 불일치 |
| 5번 이후에도 유지되나 | 유지되면 OTel 이 채운 것이 확정 |

## 결과에 따라

**성공** — `whatap-agent.yaml` 에서 두 에이전트를 끄고, `whatap-monitoring` 네임스페이스·오퍼레이터·`whatap-bootstrap` 의 ExternalSecret 을 정리한다. 기존 `metrics` 파이프라인에서 `k8s.*` 를 빼 중복도 없앤다. 구성도와 계층 구성표도 같이 고친다.

**실패** — 이 브랜치의 변경을 통째로 되돌린다. 사이드카·exporter·filter·파이프라인·`kubernetes_license` 항목 전부. 그리고 **이중 수집은 와탭 제품 구조상 불가피하다**고 설계 문서에 못 박는다 — 그때는 "몰라서 둔 것"이 아니라 "확인하고 둔 것"이 된다.

## 되돌리기

```bash
git revert --no-commit <이 브랜치의 커밋>
```

또는 Argo CD 에서 `boa-monitoring` 을 `dev` 기준으로 재동기화한다. 실험 변경은 전부 `overlays/eks/observability` 안에 있고 앱 매니페스트는 건드리지 않았다.
