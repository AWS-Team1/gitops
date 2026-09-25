# AWS S3/SQS/Argo Workflow 배포 설계와 전환 런북

## 목적과 경계

AWS 애플리케이션 desired state의 정본은 계속 이 GitOps 저장소다. `dev` commit을
immutable revision으로 사용하며, EKS 내부 런타임은 GitHub를 clone·polling하지 않는다.

```text
서비스 CI → GitOps dev commit
→ GitHub Actions가 03_manifests/eks render/검증
→ immutable S3 object 생성
→ FIFO SQS event 발행
→ Argo Events EventSource/Sensor
→ WorkflowTemplate
→ S3 download/checksum 확인
→ Kubernetes API apply/검증
```

GitHub Actions는 EKS API에 접근하지 않고 GitOps 저장소에 다시 commit/push하지 않는다.
S3가 artifact 저장소이고 SQS는 배포 시작 event다. Workflow는 S3를 polling하지 않는다.

## Canonical AWS render

Canonical target은 `03_manifests/eks`다.

```bash
kubectl kustomize 03_manifests/eks
bash 02_scripts/render-aws-deployment-artifact.sh /tmp/manifest.yaml
```

현재 snapshot은 `bank-of-anthos` Namespace 하나와 그 안의 workload 37개를 render한다.
Namespace lifecycle은 bootstrap이 담당한다. Workflow는 artifact의 Namespace가 정확히
`bank-of-anthos`인지 확인하지만 생성·수정하지 않고 나머지 namespaced resource만 적용한다.
`03_manifests/eks/applications`의 기존 Argo CD Application은 artifact 대상이 아니다.

Artifact에는 SecretProviderClass와 Secret 이름/ARN reference가 들어갈 수 있지만 실제
credential value나 Kubernetes Secret은 들어가면 안 된다. Render guard는 Kubernetes
Secret과 명백한 access key/private key material을 거부한다.

## GitHub Actions와 artifact contract

필수 Repository 또는 Environment variable:

| 이름 | 의미 |
|---|---|
| `AWS_ROLE_ARN` | GitHub OIDC publish role |
| `AWS_REGION` | `ap-northeast-2` |
| `DEPLOY_ARTIFACT_BUCKET` | immutable manifest bucket |
| `DEPLOY_QUEUE_URL` | 반드시 FIFO queue URL |
| `DEPLOY_ENV` | 현재 `aws-dev` |

Object key는 commit마다 고유하다.

```text
deployments/aws-dev/<40-character GitOps commit SHA>/manifest.yaml
```

`PutObject`는 `If-None-Match: *` 조건을 사용하므로 같은 key를 덮어쓰지 않는다. Upload와
`HeadObject`가 성공한 뒤에만 SQS event를 보낸다.

```json
{
  "environment": "aws-dev",
  "revision": "<gitops commit SHA>",
  "sequence": "<GitHub workflow run number>",
  "bucket": "<artifact bucket>",
  "key": "deployments/aws-dev/<commit>/manifest.yaml",
  "sha256": "<lowercase manifest sha256>"
}
```

FIFO 설정은 다음을 사용한다.

```text
MessageGroupId = aws-dev
MessageDeduplicationId = GitOps commit SHA
```

FIFO는 producer가 SQS에 보낸 순서만 보장한다. 서로 다른 commit의 GitHub run 완료 순서가
뒤집힐 가능성까지 막기 위해 `sequence`를 함께 보내고, Workflow는
`bank-of-anthos/boa-deployment-revision` ConfigMap의 마지막 성공 sequence보다 오래된
event를 apply하지 않는다. Workflow mutex가 한 번에 하나의 deployment만 실행한다.

## Argo Events와 Workflow

`manual/eks/argo-workflow-trigger`에는 다음 준비 manifest가 있다.

- JetStream `EventBus/default`
- Pod Identity를 사용하는 `EventSource/boa-deployment-queue`
- payload를 Workflow arguments로 전달하는 `Sensor/boa-deployment`
- `WorkflowTemplate/boa-s3-manifest-deploy`
- ServiceAccount와 최소 RBAC

EventSource의 `REPLACE_WITH_AWS_DEV_FIFO_QUEUE_NAME.fifo`는 실제 Infra queue name으로
bootstrap 전에 바꿔야 한다. Static access key Secret은 사용하지 않는다. Infra가
`argo-events/boa-deploy-eventsource` ServiceAccount에 Pod Identity를 연결한다.

Workflow는 다음을 수행한다.

1. environment/revision/sequence/key/checksum contract 검증
2. 전달받은 S3 object 한 개 다운로드
3. SHA-256 일치 확인
4. Namespace 외 cluster-scoped resource가 없음을 확인
5. Kubernetes server-side dry-run
6. 기존 sync-wave 순서대로 SecretProviderClass/ServiceAccount, secret-sync, ConfigMap 적용
7. secret-sync Ready 확인 후 exact `db-bootstrap` Job만 재생성·완료 대기
8. application resource 적용 및 6개 Deployment rollout 확인
9. 성공 revision/sequence/checksum 기록

이 초기 구현은 apply/update를 담당하며 삭제된 object를 자동 prune하지 않는다. 안전한
inventory label과 allowlist 기반 prune 정책을 별도로 검증하기 전에는 광범위한 prune을
추가하지 않는다.

## Kubernetes RBAC

- Sensor: `argo-events`에서 Workflow create/get/list/watch, WorkflowTemplate get
- Workflow executor: `workflowtaskresults` create/patch
- Manifest applier: `bank-of-anthos`에서 ConfigMap, ServiceAccount, Service, Deployment,
  Job, Ingress, NetworkPolicy, HPA, SecretProviderClass의 필요한 CRUD만 허용
- Job 재실행을 위해 Job delete만 추가 허용
- Cluster scope: `Namespace/bank-of-anthos` get만 허용
- Secret write와 cluster-admin은 부여하지 않음

## Outbound 0 사전 조건과 현재 blocker

현재 저장소에는 배포 도구용 내부 image가 없다. 아래 image를 private ECR에 먼저 만들고
WorkflowTemplate의 `bootstrap-required` tag를 immutable digest로 바꾸기 전에는 runtime
manifest를 적용하면 안 된다.

```text
boa-gitops-deployer: aws-cli v2 + kubectl + yq v4 + sha256sum + bash
```

Argo Workflows, Argo Events, JetStream/EventBus가 사용하는 controller/executor/NATS image도
모두 private ECR mirror와 digest pinning이 필요하다. 또한 현재 canonical workload에는
`public.ecr.aws/docker/library/busybox:1.36.1`과 `postgres:16`이 남아 있으므로 이 두 image도
private ECR로 mirror하기 전에는 완전한 internet outbound 0가 아니다. 이 branch에서는
기존 desired state image를 임의로 변경하지 않는다.

## Infra repository가 제공해야 하는 contract

이번 작업에서는 다음 리소스를 생성하지 않는다.

### S3

- 전용 deployment artifact bucket
- public access block, encryption, versioning 권장
- `deployments/aws-dev/*` prefix로 policy 제한
- immutable key와 conditional put 사용

### SQS

- FIFO queue와 DLQ
- queue name은 `.fifo`
- visibility/redrive 정책과 CloudWatch alarm
- 동일 environment는 하나의 message group 사용

### GitHub OIDC role

Trust는 `AWS-Team1/gitops`의 `refs/heads/dev`로 제한한다.

- `s3:PutObject` — artifact prefix
- `s3:GetObject` — upload 후 `HeadObject`
- `sqs:SendMessage` — 정확한 deployment queue ARN

### EKS Pod Identity

`argo-events/boa-deploy-eventsource`:

- `sqs:GetQueueUrl`
- `sqs:GetQueueAttributes`
- `sqs:ReceiveMessage`
- `sqs:DeleteMessage`
- `sqs:ChangeMessageVisibility`

`argo-events/boa-deploy-workflow`:

- `s3:GetObject` — `deployments/aws-dev/*`만

### Private EKS endpoint

- S3 Gateway endpoint
- SQS Interface endpoint
- ECR API/DKR Interface endpoints와 ECR layer용 S3 endpoint
- EKS Pod Identity용 EKS Auth Interface endpoint
- endpoint security group/DNS 및 private ECR image mirror

## 최초 bootstrap 순서

실제 명령 실행 전 private image와 Infra contract를 모두 준비한다.

1. Argo Workflows controller/CRD를 private image 설정으로 설치
2. Argo Events controller/CRD를 private image 설정으로 설치
3. `argo-events` namespace와 EventBus image가 private ECR을 쓰는지 확인
4. EventSource/Workflow ServiceAccount에 Pod Identity 연결
5. S3/SQS/VPC Endpoint와 exact IAM policy 준비
6. queue placeholder와 deployer image digest 갱신
7. `manual/eks/argo-workflow-trigger`의 EventBus/EventSource/Sensor/WorkflowTemplate/RBAC 적용
8. 수동 test manifest를 immutable S3 key에 업로드
9. contract와 동일한 FIFO SQS event 전송
10. Workflow 생성, checksum, dry-run/apply, rollout, revision ConfigMap 확인

이 branch 작업에서는 위 설치·upload·event 전송·apply를 실행하지 않는다.

## 기존 Argo CD 전환

기존 `01_bootstrap`, `03_manifests/eks/applications`, Argo CD 설치 스크립트는 그대로
보존한다. 현재 Argo CD와 신규 Workflow가 같은 resource를 동시에 reconcile하면 소유권과
desired state가 충돌한다.

전환 순서:

1. 신규 S3/SQS/Argo 경로와 private image 사전 준비
2. 기존 Argo CD application-controller replica 수 기록
3. Argo CD reconciliation 중지
4. test artifact/event로 신규 path와 rollback 검증
5. 서비스 CI의 GitOps commit으로 end-to-end 검증
6. 안정화 후 기존 Application/Root Application 및 Argo CD runtime 제거
7. 실패 시 신규 Sensor를 중지하고 기록한 replica 수로 Argo CD 복구

Argo CD 제거는 별도 승인 작업이며 이 feature branch에서는 수행하지 않는다.
