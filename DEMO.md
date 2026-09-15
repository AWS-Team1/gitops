# EKS 시연 순서

현재 배포 기준은 `feat/manual` 브랜치와
[`docs/EKS_APP_ARGO_KARPENTER_HPA_RUNBOOK.md`](docs/EKS_APP_ARGO_KARPENTER_HPA_RUNBOOK.md)입니다.
Argo CD는 `01_bootstrap/argocd-values.yaml`을 사용해 Helm chart `10.4.0`으로
설치하고, 앱은 Root Application 이후 Argo CD가 관리합니다.

기존 EKS 설치물을 정리할 때는 통합 런북 0~1장을 먼저 실행합니다. 새 배포는
브랜치를 지정해 GitHub에서 다시 clone하는 단계부터 시작합니다.

```bash
BRANCH=feat/manual
mkdir -p ~/work-dir
cd ~/work-dir
git clone --branch "$BRANCH" https://github.com/AWS-TEAM1-DEV/gitops.git gitops
cd gitops
git pull --ff-only origin "$BRANCH"
```

이후 Secret 준비 → 앱/HPA YAML dry-run → Argo CD Helm 설치 및 앱/HPA Sync →
Karpenter 수동 설치 → scale-out/in 시험은
통합 런북 3~8장을 따릅니다. 새 브랜치를 쓰면 Root/Child Application의
`targetRevision`도 그 브랜치로 맞춘 뒤 원격에 게시합니다.

`argocd-exposure/`는 UI 노출에 계속 사용합니다. 앱 전체에
`kubectl apply -k 03_manifests/eks`를 실행하지 마세요.
