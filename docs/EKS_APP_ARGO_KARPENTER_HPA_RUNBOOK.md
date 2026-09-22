# EKS 내부 서비스 정리 → 새 Git clone → 앱·Argo CD·Karpenter·HPA 검증

범위는 기존 `boa-eks` 안의 이 프로젝트 서비스(Kubernetes/Helm 설치물)를
정리하고, GitHub에서 새로 clone한 브랜치로 다시 배포하는 것이다. EKS 클러스터,
Managed Node 및 Terraform 소유 인프라는 유지하며 `terraform apply/destroy`는
실행하지 않는다. AWS 계정은 `769413326616`, 리전은 `ap-northeast-2`다.

다만 앱 Ingress가 만든 ALB와 Karpenter가 만든 NodeClaim/EC2는 서비스에
종속된 동적 리소스라 서비스 삭제 후 회수 여부를 확인한다. Terraform이 만든
Argo CD ops ALB나 EKS 기반 인프라는 삭제하지 않는다.

아래 명령은 **code server의 `karfa`처럼 해당 계정·클러스터 권한이 있는 환경**에서
실행한다. 이 런북은 현재 EKS에 직접 실행된 것이 아니며, 비용이 발생하는 Karpenter
scale-out 시험과 삭제 명령은 대상 확인 후 실행한다.

## 0. 공통 대상 확인

```bash
for tool in aws kubectl helm git jq openssl; do command -v "$tool" || exit 1; done
ACCOUNT=$(aws sts get-caller-identity --query Account --output text)
test "$ACCOUNT" = 769413326616 || { echo "잘못된 AWS 계정: $ACCOUNT" >&2; exit 1; }
aws eks describe-cluster --name boa-eks --region ap-northeast-2 \
  --query 'cluster.{name:name,status:status,version:version}'
aws eks update-kubeconfig --name boa-eks --region ap-northeast-2
EXPECTED_ENDPOINT=$(aws eks describe-cluster --name boa-eks --region ap-northeast-2 \
  --query cluster.endpoint --output text)
CURRENT_ENDPOINT=$(kubectl config view --minify -o jsonpath='{.clusters[0].cluster.server}')
test "$CURRENT_ENDPOINT" = "$EXPECTED_ENDPOINT" || { echo '잘못된 kubectl 대상' >&2; exit 1; }
kubectl config current-context
kubectl get nodes -o wide
```

계정·클러스터가 다르거나 기존 Managed Node가 Ready가 아니면 중단한다.

## 1. 현재 EKS 설치물 정리 (새 clone 전, 기존 checkout에서)

현재 checkout에 `02_scripts/teardown-cluster.sh`가 있어야 한다. 위치를 먼저
명시하고, 다른 팀 리소스가 없는지 목록을 확인한다.

```bash
CURRENT_GITOPS=/absolute/path/to/current/gitops
test -f "$CURRENT_GITOPS/02_scripts/teardown-cluster.sh"
grep -q 'APP_INGRESS' "$CURRENT_GITOPS/02_scripts/teardown-cluster.sh" || {
  echo '옛 정리 스크립트입니다. feat/manual의 스크립트를 먼저 가져오세요.' >&2
  exit 1
}
cd "$CURRENT_GITOPS"
helm list -A
kubectl -n argocd get applications
kubectl -n bank-of-anthos get hpa,deployments,ingress
kubectl get nodepools,nodeclaims,ec2nodeclasses
kubectl get ingress -A
```

삭제 대상이 이 프로젝트만인지 확인한다. Argo CD가 앱을 다시 만들지 않도록
Ingress/ALB 정리 스크립트를 실행하고, Karpenter Controller는 NodeClaim/EC2
회수 완료 전까지 유지한다.

```bash
kubectl delete namespace karpenter-test --ignore-not-found
kubectl delete nodepool default --ignore-not-found --wait=false
kubectl get nodeclaims,nodes -w
kubectl get nodeclaims
kubectl get nodes -l karpenter.sh/nodepool=default
```

NodeClaim과 Karpenter Node가 **모두 없어질 때까지** 기다린다. 남아 있으면
Karpenter 로그·이벤트를 조사하고 finalizer를 강제로 지우지 않는다.

```bash
bash 02_scripts/teardown-cluster.sh --confirm
```

이 스크립트는 AWS 계정/EKS endpoint를 확인하고 Argo CD 자동 재생성을 멈춘 뒤
`bank-of-anthos/boa-ingress`와 그 Ingress가 만든 앱 ALB만 정리한다. Terraform
소유 ops ALB는 기다리거나 삭제하지 않는다. 실패하면 다음 삭제로 진행하지 않는다.
이후 HPA·앱·Argo CD를 제거한다.

```bash
kubectl -n bank-of-anthos delete hpa \
  contacts-hpa userservice-hpa frontend-hpa \
  balancereader-hpa ledgerwriter-hpa transactionhistory-hpa \
  --ignore-not-found
kubectl delete ec2nodeclass default --ignore-not-found
helm uninstall karpenter -n karpenter                 # release가 있을 때만
kubectl delete namespace karpenter --ignore-not-found

kubectl -n argocd delete applications \
  boa-eks-root boa-shared boa-accounts boa-ledger boa-frontend \
  --ignore-not-found
kubectl delete namespace bank-of-anthos --ignore-not-found
kubectl -n argocd delete targetgroupbinding argocd-server --ignore-not-found
helm uninstall argocd -n argocd                       # release가 있을 때만
kubectl delete namespace argocd --ignore-not-found
```

Application 삭제가 finalizer 때문에 멈추면 Argo CD Controller를 제거하기 전에
상태를 조사한다. Metrics Server는 다른 HPA가 쓸 수 있어 **이 프로젝트가 직접
설치한 Helm release임이 확인될 때만**, 모든 HPA 제거 후
`helm uninstall metrics-server -n kube-system`을 실행한다.

```bash
kubectl get nodeclaims
kubectl get nodes -l karpenter.sh/nodepool=default
kubectl get namespace argocd karpenter bank-of-anthos
kubectl get nodes -o wide                              # 기존 Managed Node는 유지
```

Terraform이 관리하는 EKS/VPC/RDS/IAM/Pod Identity, Secrets Manager 및
`argocd-exposure/`의 AWS ops ALB는 이 런북에서 삭제하지 않는다.

## 2. GitHub에서 새 clone하고 브랜치 pull

이 정리·런북·`manual/eks/karpenter/` 및 HPA 파일이 올라간 브랜치를 clone한다.

```bash
BRANCH=feat/manual-yaml            # 다음 시험에서 다른 브랜치를 쓰면 여기만 먼저 변경
mkdir -p ~/work-dir
cd ~/work-dir
git clone --branch "$BRANCH" \
  https://github.com/AWS-TEAM1-DEV/gitops.git gitops
cd gitops
git pull --ff-only origin "$BRANCH"
git status --short
git rev-parse HEAD
```

`~/work-dir/gitops`가 이미 있다면 덮어쓰거나 삭제하지 않는다. 다른 작업
디렉터리 이름을 지정하고 새로 clone한다.

Root와 모든 Child Application의 Git `targetRevision`이 `$BRANCH`와 일치해야
Argo CD가 방금 clone한 브랜치를 읽는다. 현재 파일은 `feat/manual-yaml`을 가리킨다.

```bash
grep -R 'targetRevision:' \
  01_bootstrap/root-application-eks.yaml \
  03_manifests/eks/applications
test -f manual/eks/karpenter/ec2nodeclass.yaml
test -f manual/eks/karpenter/nodepool.yaml
kubectl kustomize 03_manifests/eks >/dev/null
kubectl kustomize 03_manifests/eks/applications >/dev/null
```

다른 브랜치라면 Root와 Git Child Application의 `targetRevision`을 그 브랜치로
수정해 **원격에 게시한 뒤** Root를 적용한다. Helm chart의
`targetRevision: 1.14.1` 같은 값은 Git 브랜치로 바꾸지 않는다.

## 3. AWS 런타임 값과 JWT 준비

Terraform을 적용하지는 않지만, 이미 만든 AWS 리소스의 ARN/ID가 Git 선언과
일치해야 한다. ALB/SG/RDS를 재생성했다면 `docs/ARGOCD_EKS_RUNBOOK.md` 5장의
수동 갱신 목록을 반영하고, diff를 검토해 해당 브랜치에 commit/push한다.

```bash
git diff --check
bash 02_scripts/prepare-jwt.sh
```

Secret 값은 화면이나 Git에 저장하지 않는다. `aws-cd-bootstrap`의 DB Secret,
Pod Identity, private DNS가 선행되어 있어야 한다.

## 4. Metrics Server 확인

```bash
kubectl get apiservice v1beta1.metrics.k8s.io
kubectl top nodes
```

이미 정상이라면 그대로 사용한다. 없는 경우에만
[공식 Metrics Server Helm chart](https://github.com/kubernetes-sigs/metrics-server/blob/master/charts/metrics-server/README.md)로 설치한다.

```bash
helm repo add metrics-server https://kubernetes-sigs.github.io/metrics-server/
helm repo update metrics-server
helm upgrade --install metrics-server metrics-server/metrics-server \
  -n kube-system --wait --timeout 10m
kubectl top nodes
```

기존 YAML/다른 Helm release 소유 Metrics Server를 중복 설치하지 않는다.

## 5. 서비스·HPA 수동 배포 → Argo CD 인수

팀 운영 순서에 따라 Argo CD 설치 전에 서비스와 HPA를 먼저 배포하고 동작을
확인한다. 앱 Secret/JWT와 CSI CRD는 이 단계 전에 준비되어 있어야 한다.

```bash
kubectl apply -f manual/eks/namespace.yaml
kubectl apply --dry-run=server -k manual/eks
kubectl apply -k manual/eks
kubectl -n bank-of-anthos get deployments,pods,jobs,ingress,hpa
kubectl -n bank-of-anthos wait --for=condition=complete job/db-bootstrap --timeout=10m
kubectl -n bank-of-anthos rollout status deployment/frontend --timeout=10m
```

서비스와 HPA가 정상 동작하는 것을 확인한 뒤 Argo CD를 설치한다. 수동 설치는
`manual/eks`의 독립 YAML을 사용하고 Argo CD는 `03_manifests/eks`의 독립 YAML을
source로 읽는다. 두 폴더의 앱 설정은 동일하게 유지해야 한다. 아래 명령은
Argo CD 자체와 UI 노출만 설치하며 앱을 다시 `kubectl apply`하지 않는다.

```bash
bash 02_scripts/install-argocd.sh          # Helm chart 10.4.0
kubectl apply -f manual/eks/argocd-exposure/targetgroupbinding.yaml
kubectl -n argocd get pods,targetgroupbinding
```

`03_manifests/eks/argocd/`와 `03_manifests/eks/argocd-exposure/`의 예전 경로는
사용하지 않는다. UI TargetGroupBinding은 `manual/eks/argocd-exposure/`에서 수동 관리한다.
기존 `docs/ARGOCD_EKS_RUNBOOK.md` 7~8장처럼 Argo CD UI에서 private
`https://github.com/AWS-TEAM1-DEV/gitops.git` 저장소를 연결한다.
Project는 비우고 연결 결과 `Successful`을 확인한다. PAT는 Git에 넣지 않는다.

```bash
bash 02_scripts/bootstrap.sh apply-root
kubectl -n bank-of-anthos wait --for=condition=complete job/db-bootstrap --timeout=10m
kubectl -n bank-of-anthos rollout status deployment/frontend --timeout=10m
kubectl -n bank-of-anthos get deployments,pods,jobs,ingress
kubectl -n argocd get applications \
  -o custom-columns=NAME:.metadata.name,SYNC:.status.sync.status,HEALTH:.status.health.status,REVISION:.status.sync.revision
bash 02_scripts/verify-argocd.sh
```

Root 포함 5개 Application이 `Synced/Healthy`이고 revision이 `$BRANCH`의
최신 commit인지 확인한다. 최초 Sync 전에 이미지/Ingress/SecretProviderClass
ARN 및 prune 대상의 Diff를 읽는다. 기존 수동 리소스를 Argo CD가 인수하며,
`boa-accounts`, `boa-ledger`,
`boa-frontend`는
[`ignoreDifferences` + `RespectIgnoreDifferences`](https://argo-cd.readthedocs.io/en/stable/user-guide/sync-options/#respect-ignore-differences-configs)로
Deployment `/spec/replicas`를 HPA에 맡긴다.

## 6. Karpenter는 수동 Helm/YAML 설치

Karpenter는 Argo CD에 등록하지 않는다. Terraform이 만든
`boa-eks-node-role`, Subnet/SG `karpenter.sh/discovery=boa-eks` 태그,
`karpenter/karpenter` Pod Identity를 확인한다.

```bash
aws iam get-role --role-name boa-eks-node-role --query Role.RoleName --output text
aws ec2 describe-subnets --region ap-northeast-2 \
  --filters Name=tag:karpenter.sh/discovery,Values=boa-eks \
  --query 'Subnets[].SubnetId' --output text
aws ec2 describe-security-groups --region ap-northeast-2 \
  --filters Name=tag:karpenter.sh/discovery,Values=boa-eks \
  --query 'SecurityGroups[].GroupId' --output text
aws eks list-pod-identity-associations --cluster-name boa-eks --region ap-northeast-2
```

비어 있으면 중단한다. Helm Controller/CRD가 먼저, EC2NodeClass가 다음,
NodePool이 마지막이다. Chart는 [공식 Karpenter Helm chart](https://github.com/aws/karpenter-provider-aws/blob/main/charts/karpenter/README.md)
`1.14.1`을 사용한다.

```bash
helm upgrade --install karpenter oci://public.ecr.aws/karpenter/karpenter \
  --version 1.14.1 -n karpenter --create-namespace \
  --set settings.clusterName=boa-eks \
  --set serviceAccount.create=true --set serviceAccount.name=karpenter \
  --set replicas=2 --wait --timeout 10m
kubectl -n karpenter rollout status deployment/karpenter --timeout=10m
kubectl get crd nodepools.karpenter.sh nodeclaims.karpenter.sh \
  ec2nodeclasses.karpenter.k8s.aws
kubectl apply --dry-run=server -f manual/eks/karpenter/ec2nodeclass.yaml
kubectl apply -f manual/eks/karpenter/ec2nodeclass.yaml
kubectl wait --for=condition=Ready ec2nodeclass/default --timeout=5m
kubectl apply --dry-run=server -f manual/eks/karpenter/nodepool.yaml
kubectl apply -f manual/eks/karpenter/nodepool.yaml
kubectl wait --for=condition=Ready nodepool/default --timeout=5m
kubectl get ec2nodeclass,nodepool,nodeclaim
```

## 7. HPA를 Argo CD로 검증

`feat/hpa-metrics`의 HPA 커밋을 이 브랜치에 cherry-pick했다. 6개 HPA는
`03_manifests/eks/shared/hpa.yaml`에 있고 `boa-shared` Application이 관리한다.
모두 CPU 목표 70%, 최소 2개/최대 3개 Pod다. Ledger 3개 Deployment의
HikariCP 최대 연결 풀은 3으로 제한했고, Deployment의 `spec.replicas`는
Git에서 지정하지 않는다. Argo CD는 앱 Deployment의 replicas 차이를 무시한다.
**HPA는 별도로 `kubectl apply`하지 않는다.**

```bash
kubectl kustomize 03_manifests/eks/shared >/dev/null
kubectl -n bank-of-anthos get hpa -o wide
kubectl -n argocd get applications boa-shared boa-accounts boa-frontend boa-ledger
kubectl -n bank-of-anthos describe hpa frontend-hpa userservice-hpa contacts-hpa \
  ledgerwriter-hpa balancereader-hpa transactionhistory-hpa
```

HPA 6개가 보이고 `ScalingActive=True`, CPU TARGETS가 `<unknown>`이 아닌지
확인한다. `minReplicas: 2`라서 1개로 줄지 않는 것이 정상이며
[Kubernetes HPA](https://kubernetes.io/docs/concepts/workloads/autoscaling/horizontal-pod-autoscale/)의
기본 downscale 안정화 창도 고려한다.

## 8. Karpenter scale-out / scale-in 시험

시험 Pod는 실제 EC2를 만들어 비용이 발생한다. NodePool 라벨로 시험 Pod를
Karpenter Node에만 배치한다.

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

NodeClaim/새 Node와 Pending → Running을 확인한다. 시험 제거 후 빈 Node가
`consolidateAfter: 10m` 이후 사라져야 한다.

```bash
kubectl delete namespace karpenter-test
kubectl get nodeclaims,nodes -w
```

HPA가 앱 Pod를 줄여도 Karpenter Node에 다른 Pod가 남으면 `WhenEmpty`에서는
그 Node가 회수되지 않는다. 다음 반복 실험을 위한 삭제는 다시 **1장**을 따른다.

