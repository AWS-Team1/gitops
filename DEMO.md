# EKS 시연 순서

```bash
git switch dev
git pull --ff-only origin dev

aws eks update-kubeconfig --name boa-eks --region ap-northeast-2

# Terraform 선행 리소스와 ECR 이미지가 준비된 뒤 실행
kubectl apply -k 03_manifests/eks
kubectl apply -k 03_manifests/eks/argocd

bash 02_scripts/register-repo.sh
kubectl apply -f 01_bootstrap/root-application-eks.yaml

kubectl -n argocd get applications
kubectl -n bank-of-anthos get pods,job,ingress
```
