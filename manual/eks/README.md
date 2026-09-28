# EKS 수동 manifest

EKS 초기 설정과 AWS 전용 리소스에 사용하는 manifest입니다. 전체 실행 순서는
[`docs/RUNBOOK.md`](../../docs/RUNBOOK.md)를 따릅니다.

| 경로 | 역할 | 적용 스크립트 |
|---|---|---|
| `argocd-exposure/targetgroupbinding.yaml` | Argo CD Service를 AWS Target Group에 연결 | `aws-install-argocd-exposure.sh` |
| `karpenter/ec2nodeclass.yaml`, `karpenter/nodepool.yaml` | Karpenter 노드 정책 | `aws-install-karpenter.sh` |
| `secrets.yaml` | AWS Secrets Manager CSI 설정 참고본 | 직접 적용하지 않음 |
| 나머지 manifest | EKS workload 참고본 | 직접 적용하지 않음 |

동적 AWS 값은 다음 명령으로 렌더링합니다.

```bash
bash 02_scripts/aws-render-runtime.sh --infra-root /home/karfa/work-dir/Infra
```

렌더링 후 변경된 manifest를 검토하고 `dev`에 commit/push해야 Argo CD가 같은
값을 읽습니다.
