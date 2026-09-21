# AWS/GCP Argo CD 원클릭 배포와 Redis 준비 조건

## 결론

- 실행 위치는 노트북, AWS EC2, GitHub Actions 중 어디든 상관없다. 대상 클러스터에 접근 가능한 `kubectl`, `helm`, kubeconfig만 필요하다.
- `bootstrap-argocd-platform.sh` 한 번으로 Argo CD 설치/업그레이드, 비공개 Git 저장소 등록, root Application 적용, 최종 상태 검증까지 수행한다.
- EKS는 6개 서비스를 실제 기동하고, GKE는 DR standby 정책에 따라 동일 리소스를 동기화하되 Deployment 6개의 `replicas=0`을 검증한다.
- GKE는 전용 글로벌 IP `boa-gke-argocd-ip`를 사용하는 External Application Load Balancer와 `argocd-gcp.bespinglobal.site` 관리형 인증서도 적용한다.
- AWS/GCP 모두 관리형 Valkey endpoint를 Secret으로 동기화하고 GitOps가 애플리케이션에 주입한다.

## 실행 전 준비

1. 실행 주체가 대상 EKS 또는 GKE의 Kubernetes API에 접근할 수 있어야 한다. EKS runner에는 AWS CLI, GKE runner에는 gcloud와 `gke-gcloud-auth-plugin`도 필요하다.
2. `kubectl`, `helm`이 설치되어 있어야 한다. Helm은 클러스터 안이 아니라 실행 머신에 설치하는 CLI다.
3. kubeconfig의 현재 context 이름에 대상 클러스터 이름 `boa-eks` 또는 `boa-gke`가 포함되어야 한다.
4. 비공개 Git 저장소를 계속 읽을 수 있는 PAT 또는 전용 계정을 준비한다. GitHub Actions의 짧게 만료되는 기본 `GITHUB_TOKEN`은 지속적인 Argo CD 동기화 자격 증명으로 사용하지 않는다.
5. Terraform이 EKS의 Secrets Store CSI/AWS provider와 AWS Load Balancer Controller를, GKE의 Secret Manager/Secret Sync add-on을 먼저 생성해야 한다. 스크립트는 이 CRD와 컨트롤러가 없으면 배포 전에 중단한다.

GKE Secret Sync는 `Infra/gcp-modules/gke/main.tf`의 `secret_manager_config`로 선언한다. 따라서 GKE를 재생성해도 SecretSync CRD가 다시 준비된다.

## 한 번에 설치 및 배포

```bash
export ARGOCD_REPO_USERNAME='<github-user-or-bot>'
read -rs ARGOCD_REPO_PASSWORD && export ARGOCD_REPO_PASSWORD

# AWS
./02_scripts/bootstrap-argocd-platform.sh eks

# GCP
./02_scripts/bootstrap-argocd-platform.sh gke
```

최초 실행 결과:

- Argo CD Helm chart `10.4.0`이 `argocd` namespace에 설치된다.
- `gitops-repo` Secret과 플랫폼별 root Application이 생성된다.
- root, shared, accounts, ledger, frontend 총 5개 Application이 `Synced/Healthy`가 아니면 명령이 실패한다.
- EKS는 6개 Deployment의 rollout 완료를 확인한다.
- GKE는 6개 Deployment가 모두 0 replica이고 HPA가 없는지 확인한다.
- GKE Argo CD UI는 DNS와 관리형 인증서가 준비된 뒤 `https://argocd-gcp.bespinglobal.site`에서 확인한다.

재실행 결과:

- 기존 Argo CD와 저장소 Secret을 재사용하고 선언 상태로 수렴한다.
- Secret 값을 교체하려면 `gitops-repo` Secret을 갱신한 뒤 다시 실행한다.

GCP Argo CD ALB의 소유권은 다음처럼 나눈다.

- `Infra/gcp-ops`: 글로벌 고정 IP `boa-gke-argocd-ip`, Route 53 A 레코드
- `gitops/01_bootstrap`: GKE BackendConfig, ManagedCertificate, FrontendConfig, Ingress
- GKE Ingress controller: URL map, proxy, forwarding rule, backend service 등 ALB 구성요소

## Redis/Valkey 연결

현재 코드 동작:

| 서비스 | Redis 용도 | Redis 장애 시 동작 |
|---|---|---|
| `userservice` | `signup:<username>` 분산 락 | 회원가입 503; 중복 가입 경쟁을 허용하지 않음 |
| `frontend` | `session:<jti>` 세션 등록 및 로그아웃 삭제 | JWT 서명 검증으로 계속 동작; 즉시 로그아웃 무효화는 보장되지 않음 |

1. AWS `aws-cache`가 ElastiCache Valkey와 credentials/runtime endpoint Secret을 만든다.
2. GCP `gcp-cache`가 Memorystore for Valkey, 전용 PSC Subnet, endpoint Secret을 만든다.
3. CSI/SecretSync가 플랫폼별 Secret을 `valkey-secret`으로 동기화한다.
4. 6개 서비스가 `VALKEY_*` 환경 변수를 사용하고 NetworkPolicy가 TCP 6379를 허용한다.
5. 클러스터 내부에서 `PING`, 동시 회원가입, 로그인/로그아웃, 캐시 무효화를 검증한다.

GCP는 private PSC에서 auth/TLS 없이 연결한다. IAM/token auth와 TLS가 필요하면 애플리케이션에
토큰 갱신 및 Google 관리 CA trust를 먼저 추가한다.

## CI와 CD의 경계

이 스크립트가 보장하는 범위는 Argo CD 기반 CD다. 애플리케이션 저장소에서 이미지를 빌드하고 ECR/Artifact Registry에 push한 뒤 GitOps 이미지 태그를 변경하는 CI workflow와 AWS/GCP용 GitHub OIDC 권한은 별도 준비가 필요하다.
