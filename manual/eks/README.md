# EKS 서비스 수동 설치 YAML

이 디렉터리는 Argo CD 연결 전 최초 앱 배포·검증에 사용한다. Argo CD가 인수한 뒤에는
`kubectl apply -k manual/eks`를 다시 실행하지 않는다. GitOps 정본은
`03_manifests/eks/`다.

## 권장 실행

저장소별 스크립트와 자잘한 kubectl 명령은 `bootstrap.sh`가 순서대로 실행한다.

```bash
# Terraform 적용과 runtime 렌더가 끝난 뒤 실행
bash gitops/02_scripts/bootstrap.sh all
```

UI 연결 전 이 디렉터리의 YAML부터 다시 배포할 때만 다음을 실행한다.

```bash
bash gitops/02_scripts/bootstrap.sh manual
```

두 모드 모두 AWS 계정 `769413326616`을 확인한다. Terraform과 runtime 렌더는 bootstrap
범위가 아니다. `all`은 다음 작업을 포함한다.

- JWT와 Metrics Server 준비
- 이 디렉터리의 Kustomize 적용, DB Job과 앱 6개 rollout/HTTP 확인
- Argo CD, TargetGroupBinding, Karpenter 설치
- UI 저장소 연결 후 Root Application 적용
- Application 5개, HPA 6개, Karpenter 최종 검증

frontend는 별도 도메인 없이 `boa-ingress`가 만든 앱 ALB DNS를 사용한다.
`argocd.bespinglobal.site`는 별도 ops ALB에 연결된 Argo CD UI 전용 주소다.

신규 환경은 이 수동 흐름 대신
[Dev EKS/GKE 최초 구축 런북](../../docs/DEV_MULTI_CLOUD_BOOTSTRAP_RUNBOOK.md)을 따른다.

## 파일 역할

| 파일 | 역할 |
|---|---|
| `namespace.yaml`, `serviceaccounts.yaml` | 앱 Namespace와 Pod Identity용 계정 |
| `secrets.yaml`, `secret-sync.yaml` | Secrets Manager 값을 CSI로 mount·동기화 |
| `configmap.yaml`, `0-*.sql`, `db-bootstrap.yaml` | DB 접속 설정과 스키마 초기화 |
| 서비스 YAML 6개 | 앱 Deployment/Service |
| `hpa.yaml` | 앱 6개의 CPU HPA |
| `ingress.yaml` | 앱 ALB Ingress |
| `networkpolicy.yaml` | 서비스 간 통신 제한 |
| `argocd-exposure/targetgroupbinding.yaml` | Argo CD UI용 Target Group 연결 |
| `karpenter/*.yaml` | EC2NodeClass와 NodePool |

`kustomization.yaml`은 앱 YAML과 SQL 파일을 하나의 배포 단위로 묶는다.
`argocd-exposure/`와 `karpenter/`는 bootstrap이 별도 순서로 적용한다.

## 장애 확인

```bash
kubectl -n bank-of-anthos get deployments,services,pods,jobs,ingress,hpa
kubectl -n bank-of-anthos get events --sort-by=.lastTimestamp
kubectl -n bank-of-anthos describe deployment bank-of-anthos-secret-sync
kubectl -n bank-of-anthos describe job db-bootstrap
kubectl -n argocd get applications
kubectl get ec2nodeclass,nodepool,nodeclaim
```

Secret 값을 `-o yaml`/`-o json`으로 출력하지 않는다. 로그와 이벤트로 원인을 확인한다.
