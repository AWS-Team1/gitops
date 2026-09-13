# Karpenter (비활성)

`infra/boa/k8s/karpenter/` 에서 이관한 매니페스트입니다. **어떤 kustomization 에도
연결되어 있지 않고 Argo CD 가 배포하지 않습니다.**

활성화하려면 먼저 아래가 필요합니다.

1. Karpenter 컨트롤러 설치 — `argocd/platform/` 에 Application 추가
2. `EC2NodeClass.spec.role` 이 가리키는 `project-eks-karpenter-node-role` IAM Role
   생성 (현재 Terraform 에 없음. `modules/eks/iam.tf` 에 Karpenter 컨트롤러 Role 과
   Pod Identity 는 있지만 노드 Role 은 없습니다.)
3. 서브넷과 보안그룹에 `karpenter.sh/discovery: project-eks` 태그 추가
   (`modules/network`, `modules/security`)

위 세 가지가 갖춰지기 전에 적용하면 노드가 생성되지 않습니다. IAM 과 태그는 infra,
Kubernetes 선언은 이 저장소가 소유하는 분리 원칙을 따릅니다.
