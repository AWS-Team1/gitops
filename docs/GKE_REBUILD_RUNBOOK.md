# GKE 단독 재구축 런북

`gcp-core`, Cloud SQL, `gcp-ops`와 Secret Manager는 보존하고 `gcp-gke`만 다시 만드는 절차다.
모든 명령은 코드서버의 `/home/karfa/work-dir`에서 실행한다.

## 현재 확인된 상태

- `Infra/gcp-gke` Terraform state는 비어 있다.
- `terraform plan -refresh=false` 결과는 `7 to add, 0 to change, 0 to destroy`다.
- `gcp-ops`의 `boa-gke-argocd-ip`는 보존되어 있다.
- Argo CD 고정 IP는 `136.68.183.159`다.
- GKE 마스터 접근 허용 주소는 코드서버 `15.165.176.99/32`다.
- GKE 앱 6개의 Git desired replicas는 각각 `1`이다.
- 코드서버의 gcloud 로그인이 만료되어 있으므로 재로그인이 필요하다.

> 현재 GKE는 이미 삭제됐다. 지금은 teardown 명령을 다시 실행하지 않는다.

## 0. 노출된 GitHub PAT 폐기

채팅이나 로그에 노출된 PAT는 즉시 GitHub에서 폐기하고 새 PAT를 발급한다.
PAT 값을 셸 명령, Git 또는 이 문서에 직접 기록하지 않는다.

## 1. GCP 로그인과 Git 최신화

```bash
cd /home/karfa/work-dir

gcloud auth login --no-launch-browser
gcloud config set project kdt4-1-506106
gcloud auth list --filter=status:ACTIVE

# 클러스터는 없어야 하고 Argo CD 고정 IP는 존재해야 한다.
gcloud container clusters describe boa-gke \
  --region asia-northeast2 --project kdt4-1-506106
gcloud compute addresses describe boa-gke-argocd-ip \
  --global --project kdt4-1-506106

# Terraform state가 비어 있으므로 노드 서비스 계정도 없어야 한다.
gcloud iam service-accounts describe \
  boa-gke-node@kdt4-1-506106.iam.gserviceaccount.com \
  --project kdt4-1-506106

git -C gitops status --short
git -C gitops switch dev-0922
git -C gitops pull --ff-only origin dev-0922
```

`git status --short`에 출력이 있으면 pull하기 전에 변경 내용을 확인한다.

첫 번째와 세 번째 `describe`는 `NOT_FOUND`, 고정 IP 조회는 `136.68.183.159`가 정상이다. 클러스터나 노드 서비스 계정이 존재하면 state 밖의 orphan일 수 있으므로 apply하지 않는다.

## 2. GKE Terraform 재생성

```bash
terraform -chdir=Infra/gcp-gke init -upgrade
terraform -chdir=Infra/gcp-gke validate
terraform -chdir=Infra/gcp-gke plan
```

plan의 마지막 줄이 다음과 같은지 확인한다.

```text
Plan: 7 to add, 0 to change, 0 to destroy.
```

다른 리소스의 변경이나 삭제가 표시되면 apply하지 않는다. 정상이면 실행한다.

```bash
terraform -chdir=Infra/gcp-gke apply
```

확인 질문에는 `yes`를 입력한다.

## 3. 새 GKE 연결과 JWT 준비

```bash
cd /home/karfa/work-dir/gitops

bash 02_scripts/gcp-connect-cluster.sh
kubectl config current-context
kubectl get nodes

bash 02_scripts/gcp-prepare-jwt.sh
```

현재 context에 `boa-gke`가 포함되고 노드가 `Ready`인지 확인한다.

## 4. Argo CD 설치와 외부 노출

```bash
bash 02_scripts/argocd-install.sh gcp
bash 02_scripts/gcp-install-argocd-exposure.sh
```

Argo CD Ingress는 보존한 고정 IP를 다시 사용한다.

```bash
kubectl -n argocd get ingress argocd-gcp
kubectl -n argocd get managedcertificate argocd-gcp
```

GCE Ingress와 인증서 반영에는 수 분 이상 걸릴 수 있다.

## 5. 비공개 Git 저장소 연결

새로 발급한 PAT를 프롬프트에서만 입력한다.

```bash
read -rp "GitHub username: " ARGOCD_REPO_USERNAME
read -srp "GitHub PAT: " ARGOCD_REPO_PASSWORD
printf '\n'
export ARGOCD_REPO_USERNAME ARGOCD_REPO_PASSWORD

bash 02_scripts/argocd-register-repository.sh gcp
```

## 6. Root Application 배포와 검증

```bash
bash 02_scripts/argocd-apply-root.sh gcp
bash 02_scripts/argocd-verify.sh gcp
```

최종 상태를 확인한다.

```bash
kubectl -n argocd get applications
kubectl -n bank-of-anthos get deployments,pods,ingress
```

앱 Deployment 6개는 각각 replicas `1`이어야 한다. Frontend GCE Ingress는 고정 IP를 사용하지 않으므로 재생성 후 주소가 달라질 수 있다.
Argo CD Application은 root 1개와 child 9개, 총 10개가 `Synced/Healthy`여야 한다.

## 7. Argo CD 관리자 비밀번호 확인과 환경변수 제거

```bash
kubectl -n argocd get secret argocd-initial-admin-secret \
  -o jsonpath='{.data.password}' | base64 -d
printf '\n'

unset ARGOCD_REPO_USERNAME ARGOCD_REPO_PASSWORD
```

## 다음 GKE 삭제 시 사용할 순서

Argo CD가 Ingress를 다시 만들지 못하도록 controller를 먼저 멈춘다.

```bash
cd /home/karfa/work-dir/gitops
bash 02_scripts/gcp-connect-cluster.sh

kubectl -n argocd scale statefulset argocd-application-controller --replicas=0
kubectl -n bank-of-anthos delete ingress boa-ingress \
  --ignore-not-found --wait --timeout=15m

bash 02_scripts/gcp-teardown.sh --confirm
kubectl get ingress -A
```

Ingress가 모두 사라진 뒤 GKE만 제거한다.

```bash
cd /home/karfa/work-dir
terraform -chdir=Infra/gcp-gke plan -destroy
terraform -chdir=Infra/gcp-gke destroy
```

`gcp-core`, `gcp-cloudsql`, `gcp-ops`는 destroy하지 않는다.
