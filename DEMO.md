# EKS 시연 실행 순서

코드 서버에서 아래 명령을 위에서부터 순서대로 실행합니다. AWS 자격 증명은 인스턴스
Role 또는 이미 설정된 AWS CLI 자격 증명을 사용하고, private GitHub 저장소를 읽을 수
있는 PAT 하나만 준비합니다.

## 1. 최신 코드 받기

```bash
git -C ~/infra switch dev
git -C ~/infra pull --ff-only origin dev

git -C ~/gitops switch dev
git -C ~/gitops pull --ff-only origin dev
```

## 2. 인프라 생성

```bash
terraform -chdir=~/infra init
terraform -chdir=~/infra fmt -check -recursive
terraform -chdir=~/infra validate
terraform -chdir=~/infra plan -out=dev.tfplan
terraform -chdir=~/infra apply dev.tfplan
```

## 3. GitOps 환경값 렌더링 및 push

첫 번째 명령은 저장소를 변경하지 않는 미리보기입니다.

```bash
cd ~/gitops
./scripts/bootstrap-eks.sh --infra-dir ~/infra --environment dev
./scripts/bootstrap-eks.sh --infra-dir ~/infra --environment dev --render

git add k8s argocd bootstrap environments
git diff --cached --check
git commit -m "chore(gitops): render dev/aws from terraform output"
git push origin dev
```

## 4. EKS 연결 및 private 저장소 등록

PAT 입력은 화면에 표시되지 않으며 Kubernetes의 Argo CD repository Secret으로만
전달됩니다. 기존 클러스터에 이미 등록했다면 자격 증명 등록 명령은 생략할 수 있습니다.

```bash
aws eks update-kubeconfig \
  --name "$(terraform -chdir=~/infra output -raw eks_cluster_name)" \
  --region "$(terraform -chdir=~/infra output -raw aws_region)"

cd ~/gitops
./scripts/register-repo-credentials.sh
```

## 5. Argo CD 및 애플리케이션 배포

이 명령 하나가 Argo CD 설치, root Application 적용, platform add-on 동기화,
DB bootstrap Job 실행, 애플리케이션 배포 및 `Synced/Healthy` 대기까지 수행합니다.

```bash
cd ~/gitops
./scripts/bootstrap-eks.sh \
  --infra-dir ~/infra \
  --environment dev \
  --apply \
  --timeout 1200
```

## 6. 시연 상태 확인

```bash
kubectl get nodes
kubectl -n argocd get applications
kubectl -n bank-of-anthos get job db-bootstrap
kubectl -n bank-of-anthos get pods
kubectl -n bank-of-anthos get ingress project-ingress
```

모든 애플리케이션 Pod가 `Running`, `db-bootstrap` Job이 `Complete`, Argo CD
Application이 `Synced/Healthy`이면 배포가 완료된 상태입니다.
