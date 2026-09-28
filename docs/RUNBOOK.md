# GitOps 실행 런북

이 문서가 AWS/GCP GitOps 설치의 기준 실행 순서입니다. 모든 명령은 GitOps 저장소
루트에서 한 줄씩 실행합니다. 각 스크립트는 한 가지 작업만 수행하므로 실패한 단계만
다시 실행할 수 있습니다.

## 사전 조건

- checkout branch: `dev`
- AWS Terraform 적용이 끝났고 코드 서버 역할에 EKS Access Entry가 설정되어 있어야 함
- GCP Terraform 적용이 끝났고 현재 gcloud 계정에 GKE/Secret Manager 권한이 있어야 함
- `aws`, `gcloud`, `terraform`, `kubectl`, `helm`, `openssl` 중 해당 플랫폼 도구 설치
- Argo CD가 읽는 manifest의 `targetRevision`은 `dev`

## 스크립트 목록

| 스크립트 | 목적 | 주요 입력 | 결과물 |
|---|---|---|---|
| `aws-connect-cluster.sh` | kubectl을 EKS에 연결 | AWS 자격 증명 | `boa-eks` kubeconfig context |
| `gcp-connect-cluster.sh` | kubectl을 GKE에 연결 | gcloud 활성 계정 | `boa-gke` kubeconfig context |
| `aws-render-runtime.sh` | Terraform의 AWS 동적 값을 manifest에 렌더링 | `--infra-root` | Argo CD·Grafana Target Group/SG, RDS Secret ARN이 갱신된 YAML 4개 |
| `aws-prepare-jwt.sh` | AWS JWT 키 준비 | AWS 자격 증명 | Secrets Manager JWT 키 2개 |
| `gcp-prepare-jwt.sh` | GCP JWT 키 준비 | gcloud 활성 계정 | Secret Manager JWT 키 2개와 접근 권한 |
| `aws-install-metrics-server.sh` | Metrics Server 설치 | EKS context | 사용 가능한 Metrics API |
| `argocd-install.sh` | Argo CD 설치 | `aws` 또는 `gcp` | Ready 상태의 Argo CD |
| `aws-install-argocd-exposure.sh` | AWS Argo CD 노출 연결 | 렌더링된 manifest | TargetGroupBinding |
| `gcp-install-argocd-exposure.sh` | GCP Argo CD 외부 노출 | GKE context | GCP Ingress 관련 리소스 |
| `aws-install-karpenter.sh` | Karpenter 설치 | EKS context | Controller, EC2NodeClass, NodePool |
| `argocd-register-repository.sh` | 비공개 Git 저장소 등록 | 플랫폼, GitHub 사용자명/PAT | `argocd/gitops-repo` Secret |
| `argocd-apply-root.sh` | Root Application 적용 | `aws` 또는 `gcp` | 플랫폼 Root Application |
| `argocd-verify.sh` | Argo CD 배포 상태 검증 | `aws` 또는 `gcp` | Application 및 workload 검증 결과 |
| `aws-teardown.sh` | EKS 삭제 전 앱 ALB 정리 | `--confirm` | 앱 Ingress/ALB 제거 |
| `gcp-teardown.sh` | GKE 삭제 전 외부 LB 정리 | `--confirm` | GKE 컨트롤러 소유 LB 리소스 제거 |

## AWS 실행 순서

1. EKS에 연결합니다. 결과로 현재 context와 노드 목록이 출력됩니다.

   ```bash
   bash 02_scripts/aws-connect-cluster.sh
   ```

2. Terraform output을 AWS manifest에 렌더링합니다.

   ```bash
   bash 02_scripts/aws-render-runtime.sh --infra-root /home/karfa/work-dir/Infra
   ```

3. 렌더링 결과를 검토해 `dev`에 commit/push합니다. Argo CD는 원격 Git의 값을
   읽으므로 이 단계가 필요합니다.

   ```bash
   git diff -- manual/eks/argocd-exposure/targetgroupbinding.yaml manual/eks/secrets.yaml 03_manifests/overlays/eks/shared/secrets.yaml 03_manifests/overlays/eks/observability/grafana.yaml
   ```

4. AWS Secrets Manager의 JWT 키를 준비합니다.

   ```bash
   bash 02_scripts/aws-prepare-jwt.sh
   ```

5. EKS Metrics Server를 설치합니다.

   ```bash
   bash 02_scripts/aws-install-metrics-server.sh
   ```

6. Argo CD를 설치합니다.

   ```bash
   bash 02_scripts/argocd-install.sh aws
   ```

7. Argo CD Service를 AWS Target Group에 연결합니다.

   ```bash
   bash 02_scripts/aws-install-argocd-exposure.sh
   ```

8. Karpenter를 설치합니다.

   ```bash
   bash 02_scripts/aws-install-karpenter.sh
   ```

9. GitHub 자격 증명을 환경변수로 넣고 저장소만 등록합니다.

   ```bash
   read -rp "GitHub username: " ARGOCD_REPO_USERNAME

   read -srp "GitHub PAT: " ARGOCD_REPO_PASSWORD

   printf '\n'

   export ARGOCD_REPO_USERNAME ARGOCD_REPO_PASSWORD

   bash 02_scripts/argocd-register-repository.sh aws
   ```

10. AWS Root Application만 적용한 뒤 별도 스크립트로 상태를 검증합니다.

    ```bash
    bash 02_scripts/argocd-apply-root.sh aws

    bash 02_scripts/argocd-verify.sh aws

    unset ARGOCD_REPO_USERNAME ARGOCD_REPO_PASSWORD
    ```

11. ArgoCD 비밀번호 조회

   ```bash
   kubectl -n argocd get secret argocd-initial-admin-secret -o jsonpath="{.data.password}" | base64 -d
   ```

## GCP 실행 순서

GCP에는 Terraform output을 GitOps YAML로 치환할 값과 Karpenter/Metrics Server가 없으므로
빈 대응 스크립트를 두지 않습니다.

1. GKE에 연결하고 JWT 키를 준비합니다.

   ```bash
   gcloud auth login --no-launch-browser

   bash 02_scripts/gcp-connect-cluster.sh

   bash 02_scripts/gcp-prepare-jwt.sh
   ```

2. Argo CD를 설치하고 GCP 외부 노출 manifest를 적용합니다.

   ```bash
   bash 02_scripts/argocd-install.sh gcp

   read -srp "Slack Webhook URL: " SLACK_WEBHOOK_URL

   printf '\n'

   kubectl -n argocd create secret generic argocd-notifications-secret \
     --from-literal=slack-webhook-url="$SLACK_WEBHOOK_URL" \
     --dry-run=client -o yaml | kubectl apply -f -

   unset SLACK_WEBHOOK_URL

   bash 02_scripts/gcp-install-argocd-exposure.sh
   ```

3. GitHub 자격 증명을 환경변수로 넣고 저장소만 등록합니다.

   ```bash
   read -rp "GitHub username: " ARGOCD_REPO_USERNAME

   read -srp "GitHub PAT: " ARGOCD_REPO_PASSWORD

   printf '\n'

   export ARGOCD_REPO_USERNAME ARGOCD_REPO_PASSWORD

   bash 02_scripts/argocd-register-repository.sh gcp
   ```

4. GCP Root Application만 적용한 뒤 별도 스크립트로 상태를 검증합니다.

   ```bash
   bash 02_scripts/argocd-apply-root.sh gcp

   bash 02_scripts/argocd-verify.sh gcp

   unset ARGOCD_REPO_USERNAME ARGOCD_REPO_PASSWORD
   ```

## 클러스터 삭제 전 LB 정리

이 명령은 Terraform destroy를 실행하지 않습니다. 각 클라우드 컨트롤러가 만든 외부 LB
리소스만 정리합니다.

```bash
bash 02_scripts/aws-teardown.sh --confirm

bash 02_scripts/gcp-teardown.sh --confirm
```

GCP Secret Manager의 기존 값을 CLI로 옮겨야 한다면
[`GKE_SECRET_MANAGER_CLI_RUNBOOK.md`](GKE_SECRET_MANAGER_CLI_RUNBOOK.md)를 참고합니다.
