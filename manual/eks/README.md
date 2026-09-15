# EKS 서비스 수동 설치

이 디렉터리는 **Argo CD 연결 전 최초 배포·검증**에 사용한다. 명령은 저장소
루트에서 실행한다. 현재처럼 `boa-*` Application이 서비스를 이미 관리하는
클러스터에서는 아래 `kubectl apply -k manual/eks`를 다시 실행하지 않는다.
Argo CD가 나중에 읽을 선언은 `03_manifests/eks/`에 따로 있다.

| 파일 | 역할 | 예상 결과 |
| --- | --- | --- |
| `namespace.yaml`, `serviceaccounts.yaml` | 앱 Namespace와 Pod Identity용 계정 | `bank-of-anthos` Namespace, ServiceAccount 2개 |
| `secrets.yaml`, `secret-sync.yaml` | AWS Secrets Manager 값을 CSI로 mount·동기화 | SecretProviderClass 2개, `secret-sync` Deployment, `db-secret` |
| `configmap.yaml`, `0-*.sql`, `db-bootstrap.yaml` | DB 접속 설정·스키마 초기화 | ConfigMap 2개, `db-bootstrap` Job `Complete` |
| `contacts.yaml`, `userservice.yaml`, `balancereader.yaml`, `ledgerwriter.yaml`, `transactionhistory.yaml`, `frontend.yaml` | 서비스 6개 | Deployment/Service 각각 6개, Pod `Running` |
| `hpa.yaml` | CPU 기반 자동 확장 | HPA 6개, 각 `minReplicas=2`, `maxReplicas=3`, CPU 목표 70% |
| `ingress.yaml` | 앱 외부 진입점 | `boa-ingress`와 앱용 ALB 주소 |
| `networkpolicy.yaml` | 서비스 간 통신 제한 | NetworkPolicy 8개 |
| `argocd-exposure/targetgroupbinding.yaml` | Argo CD UI용 Terraform Target Group 연결 | `argocd` Namespace의 TargetGroupBinding 1개 |
| `karpenter/ec2nodeclass.yaml`, `karpenter/nodepool.yaml` | 동적 노드 설정 | EC2NodeClass/NodePool `Ready` |

`kustomization.yaml`은 위 앱 YAML과 두 SQL 파일을 하나의 배포 단위로 묶는다.
SQL에서 ConfigMap을 만들고 Job이 참조할 이름도 맞추므로, 앱 파일들을
`kubectl apply -f *.yaml`로 따로 적용하지 않는다. `argocd-exposure/`와
`karpenter/`는 이 Kustomize 배포에 포함되지 않는다.

## 1. 대상과 선행 조건 확인

```bash
aws sts get-caller-identity --query Account --output text
kubectl config current-context
kubectl get nodes
kubectl get csidriver secrets-store.csi.k8s.io
kubectl get crd secretproviderclasses.secrets-store.csi.x-k8s.io
kubectl get apiservice v1beta1.metrics.k8s.io
kubectl top nodes
kubectl -n argocd get applications 2>/dev/null || true
```

AWS 계정은 `769413326616`, context는
`arn:aws:eks:ap-northeast-2:769413326616:cluster/boa-eks`, 기존 Managed Node는
`Ready`여야 한다. CSI Driver/AWS provider, Pod Identity, RDS, Secrets Manager,
AWS Load Balancer Controller는 이미 설치·설정돼 있어야 한다. Metrics Server의
APIService가 `True`이고 `kubectl top nodes`가 값을 출력해야 HPA CPU 지표가
나온다. `boa-*` Application이 이미 있다면 수동 앱 배포를 중단한다.
자세한 선행 조건은 [통합 런북](../../docs/EKS_APP_ARGO_KARPENTER_HPA_RUNBOOK.md)
0~4장을 따른다.

## 2. DB/JWT Secret 준비

```bash
bash 02_scripts/prepare-database-secret.sh
bash 02_scripts/prepare-jwt.sh
```

두 스크립트가 AWS Secrets Manager의 앱 DB 자격 증명과 JWT 키를 준비한다.
비밀번호나 키 값을 화면에 출력하거나 Git에 저장하지 않는다. Secret 이름과
RDS master ARN이 현재 Terraform 리소스와 일치하는지 통합 런북 3장에서
확인한다.

## 3. 앱·HPA YAML 수동 적용

```bash
kubectl kustomize manual/eks >/dev/null
kubectl apply -f manual/eks/namespace.yaml
kubectl apply --dry-run=server -k manual/eks
kubectl apply -k manual/eks
```

Namespace를 먼저 실제로 만들면 새 클러스터에서도 namespaced 리소스의
server dry-run이 가능하다. 마지막 명령은 Service, Deployment 7개(앱 6개와
`secret-sync`), HPA 6개, DB Job, Ingress 등을 생성·갱신한다.
`sync-wave`/`hook` annotation은 수동 `kubectl apply`의 실행 순서를 제어하지
않는다. Pod가 SecretProviderClass/`db-secret`/DB 스키마 준비 전 잠시 재시도할
수 있으므로 아래 최종 상태를 확인한다.

## 4. 동작 확인

```bash
kubectl -n bank-of-anthos rollout status deployment/bank-of-anthos-secret-sync --timeout=5m
kubectl -n bank-of-anthos get secret db-secret
kubectl -n bank-of-anthos wait --for=condition=complete job/db-bootstrap --timeout=10m
for app in contacts userservice balancereader ledgerwriter transactionhistory frontend; do
  kubectl -n bank-of-anthos rollout status "deployment/$app" --timeout=10m
done
kubectl -n bank-of-anthos get deployments,services,pods,jobs,ingress,hpa
kubectl -n bank-of-anthos get hpa -o wide
```

예상 결과는 `secret-sync`와 앱 Pod가 `Running/Ready`, `db-secret`이 `Opaque`
및 키 2개, `db-bootstrap`이 `Complete`, 서비스 Deployment 6개가 rollout
완료인 것이다. `boa-ingress`의 ADDRESS에는 AWS Load Balancer Controller가
만든 앱 ALB DNS가 나타난다. HPA는 6개여야 하고 TARGETS가 지속적으로
`<unknown>`이면 Metrics Server 또는 Pod CPU request를 확인한다. Pod 수는
부하에 따라 2~3개다. CPU가 낮아도 최소 2개 미만으로 줄지 않는다.

`db-secret`은 CSI mount Pod가 있을 때 동기화되는 Kubernetes Secret이다.
앱 Pod가 모두 내려가면 사라질 수 있다. 여기서는 `secret-sync` Pod가 계속
mount해서 유지한다. Secret 값을 조회할 때 `-o yaml`이나 `-o json`으로
데이터를 출력하지 않는다. 문제 조사에는 다음 명령을 사용한다.

```bash
kubectl -n bank-of-anthos describe deployment bank-of-anthos-secret-sync
kubectl -n bank-of-anthos get secretproviderclasspodstatus
kubectl -n bank-of-anthos describe job db-bootstrap
kubectl -n bank-of-anthos describe hpa frontend-hpa
```

## 5. 별도 수동 YAML: Argo CD UI와 Karpenter

앱 설치와 별개로 Argo CD를 Helm으로 설치한 **뒤**, 외부 UI를 사용한다면
TargetGroupBinding을 적용한다. Terraform이 만든 ops ALB/Target Group은
유지된다. 이 리소스는 앱 Kustomize와 Argo CD Application에 포함되지 않는다.

```bash
bash 02_scripts/install-argocd.sh
kubectl apply -f manual/eks/argocd-exposure/targetgroupbinding.yaml
kubectl -n argocd get targetgroupbinding argocd-server
```

Karpenter Controller/CRD는 먼저 Helm으로 설치한다. Controller가 Ready이고
`boa-eks-node-role`, Subnet/SG discovery 태그, Pod Identity가 준비됐을 때만
아래 두 YAML을 순서대로 적용한다. Controller 설치 명령과 선행 조건은
통합 런북 6장을 따른다.

```bash
kubectl get crd ec2nodeclasses.karpenter.k8s.aws nodepools.karpenter.sh
kubectl apply --dry-run=server -f manual/eks/karpenter/ec2nodeclass.yaml
kubectl apply -f manual/eks/karpenter/ec2nodeclass.yaml
kubectl wait --for=condition=Ready ec2nodeclass/default --timeout=5m
kubectl apply --dry-run=server -f manual/eks/karpenter/nodepool.yaml
kubectl apply -f manual/eks/karpenter/nodepool.yaml
kubectl wait --for=condition=Ready nodepool/default --timeout=5m
kubectl get ec2nodeclass,nodepool,nodeclaim
```

예상 결과는 EC2NodeClass와 NodePool이 `Ready`인 것이다. Pending Pod가
없으면 NodeClaim은 0개여도 정상이다. 실제 scale-out/in 시험은 통합 런북
8장을 따른다.

## 6. Argo CD 인수

수동 앱·HPA 검증이 끝난 뒤 Argo CD 저장소를 연결하고 Root Application을
적용한다. Root/Child Application은 `feat/manual-yaml`의
`03_manifests/eks/` YAML을 읽고, 같은 이름의 기존 리소스를 인수한다. 인수 후
앱·HPA를 `manual/eks`로 다시 적용하지 않는다. 두 YAML 경로의 이미지,
SecretProviderClass, Ingress, HPA 설정이 다른 경우 Argo CD가 Git 쪽 값으로
변경할 수 있으므로 Root Sync 전 Diff를 확인한다.

```bash
bash 02_scripts/bootstrap.sh apply-root
kubectl -n argocd get applications \
  -o custom-columns=NAME:.metadata.name,BRANCH:.spec.source.targetRevision,SYNC:.status.sync.status,HEALTH:.status.health.status
kubectl -n bank-of-anthos get hpa -o wide
```

예상 결과는 Root와 `boa-shared`, `boa-accounts`, `boa-ledger`, `boa-frontend`가
모두 `feat/manual-yaml`에서 `Synced/Healthy`이고, HPA 6개가 `boa-shared`의
관리 리소스로 잡히는 것이다. Argo CD UI 노출 TargetGroupBinding과
Karpenter는 계속 수동 관리한다. 서비스 삭제 순서는 통합 런북 1장을 따른다.
