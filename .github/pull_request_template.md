## 변경 목적

<!-- 이 변경이 필요한 이유와 해결하려는 문제를 적는다. -->

## 승격 대상 브랜치 확인

- [ ] `feature/*` → `dev`
- [ ] `dev` → `release`
- [ ] `release` → `main`
- [ ] 위 허용 방향 외의 PR이 아님을 확인했다 (`Branch Promotion Policy` Check)

## 변경 Cluster

- [ ] EKS (`03_manifests/overlays/eks`)
- [ ] GKE (`03_manifests/overlays/gke`)
- [ ] 수동 배포 (`manual/eks`)
- [ ] Bootstrap / ArgoCD 설정 (`01_bootstrap`)
- [ ] Cluster 영향 없음 (workflow, scripts, docs만 변경)

## 변경 Application

<!-- 예: accounts, ledger, frontend, shared, observability, applications -->

## 이미지 태그

| Application | Cluster | 기존 태그 | 신규 태그 |
|---|---|---|---|
| | | | |

- [ ] 프로젝트 이미지는 `sha-<40자리 Git SHA>` 태그만 사용한다 (latest/dev/main 등 금지)

## Kustomize 검증 결과

- [ ] `GitOps CI Required` Check 성공
- [ ] 변경한 overlay를 로컬에서 `kustomize build`로 확인했다

## ArgoCD 동기화 영향

- [ ] 영향 없음
- [ ] 이미지 교체로 Pod 재시작 (대상 Application)
- [ ] Application / targetRevision / sync 옵션 변경
- [ ] 리소스 삭제 또는 prune 발생 가능 (대상과 사유)

## 롤백

<!-- 되돌릴 Git Commit SHA 또는 이전 이미지 태그를 적는다. -->

- 롤백 Commit:
- 롤백 이미지 태그:
