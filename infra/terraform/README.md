# Terraform IaC — Jenkins on AWS Spot

`infra/aws-setup.md` 런북의 모든 리소스를 선언적으로 옮긴 모듈입니다. CLI로 한 번 손에 익힌 후 IaC로 옮기는 흐름 그대로.

DNS·HTTPS는 사용하지 않습니다 — ALB의 자동 할당 DNS를 그대로 사용해 학습 비용을 0으로. webSocket은 ws:// (HTTP)로 동작 (JEP-222가 HTTP/HTTPS 모두 지원).

## 구조

```
infra/terraform/
├── versions.tf              # AWS provider ~> 6.0 고정
├── providers.tf             # region + default_tags
├── variables.tf             # 입력값
├── network.tf               # 기본 VPC data + SG 3개 (50000 인바운드 없음, webSocket)
├── storage.tf               # 영속 EBS gp3 (prevent_destroy)
├── secrets.tf               # JENKINS_URL을 SSM에 자동 등록 (ALB DNS 파생)
├── iam.tf                   # controller / agent / DLM 역할
├── compute.tf               # Launch Template + ASG (mixed Spot, capacity rebalance)
├── alb.tf                   # ALB + TG + 80 리스너 (HTTP only, idle_timeout 3600)
├── dlm.tf                   # daily snapshot
├── outputs.tf               # URL, ARN, next_steps 가이드
├── templates/
│   ├── userdata-controller.sh.tftpl  # LT user_data 템플릿
│   └── userdata-agent.sh.tftpl
├── terraform.tfvars.example
└── .gitignore               # state·tfvars 제외
```

## 사전 준비 (Terraform 외부)

1. **AWS 계정 + CLI 로그인** — `aws sts get-caller-identity` 통과
2. **리포 접근** — `jenkins_repo_url`이 public이면 별도 처리 불필요. private이면 user-data에 토큰 주입 필요 (현재 모듈은 public 가정)

> ❌ 도메인·Route53·ACM 인증서는 **불필요**. ALB가 발급하는 DNS를 그대로 사용.

## 사용

```bash
cd infra/terraform
cp terraform.tfvars.example terraform.tfvars
$EDITOR terraform.tfvars   # jenkins_repo_url 등 채우기

terraform init
terraform fmt -check
terraform validate
terraform plan -out plan.bin
terraform apply plan.bin
```

apply 후 `outputs.tf`의 `next_steps`를 확인 — 시크릿 SSM 등록 + 에이전트 secret 부트스트랩 절차가 출력됩니다.

## 무엇이 Terraform 밖에서 관리되나

| 항목 | 이유 |
|---|---|
| **시크릿 SSM 값** (`JENKINS_ADMIN_PASSWORD`, `GITHUB_PAT`, `SLACK_TOKEN`) | state 파일·plan 출력에 노출되지 않도록. user-data가 IMDS 토큰으로 fetch. |
| **에이전트 secret 부트스트랩** (`AGENT_SECRET_1`) | JCasC가 노드를 만들 때 controller가 자동 생성 → UI에서 한 번 복사해 SSM에 저장 (1회성) |
| **리포 자체** | Terraform은 인프라만 관리. compose/JCasC 파일은 git 위에서 변화 |

`JENKINS_URL`은 ALB DNS에서 파생되므로 (시크릿 아님) Terraform이 SSM에 자동 등록.

## AMI bake 토글 (cold start 최적화)

기본값 `use_baked_ami = false` 로는 인스턴스가 매번 AL2023 + Docker + Compose + Jenkins 이미지를 처음부터 설치 → 부팅 ~5분.

`infra/packer` 로 한 번 AMI 를 빌드한 뒤 `use_baked_ami = true` 로 켜면 부팅 ~60초:

```hcl
# terraform.tfvars
use_baked_ami = true
```

baked AMI 가 없을 때 `true` 로 두면 plan 에서 data source 매칭 0건으로 실패하므로, 먼저 `cd ../packer && packer build jenkins-controller.pkr.hcl` 으로 빌드.

## 학습용 비용 토글

학습 안 할 때 비용 줄이려면:

```bash
# 완전 멈춤 (EBS만 살아 있음 → 월 ~$2.4)
terraform destroy

# 다시 시작
terraform apply

# 또는 간단히 ASG만 0으로 (ALB·EBS 유지)
aws autoscaling set-desired-capacity --auto-scaling-group-name $(terraform output -raw controller_asg_name) --desired-capacity 0
aws autoscaling set-desired-capacity --auto-scaling-group-name $(terraform output -raw agent_asg_name)      --desired-capacity 0
```

> EBS는 `prevent_destroy = true`라 `terraform destroy`는 그 자원에서 멈춥니다. 데이터 보존 목적이며, 진짜 지우려면 lifecycle 블록을 일시 해제해야 함.

## 변경 시 주의

- `aws_ebs_volume.jenkins_data`는 `lifecycle.prevent_destroy = true`. destroy 하려면 lifecycle 블록을 풀거나 `terraform state rm` 후 수동 삭제.
- `controller_subnet_id` 변경은 EBS와의 AZ mismatch를 유발할 수 있음. 변경 전 EBS 마이그레이션 필요.
- agent_min_size를 0으로 두면 빌드 처리 능력은 0이지만 Controller·UI는 정상.

## ⚠️ HTTPS·DNS가 필요해질 때

지금은 ALB DNS + HTTP만. 다음 경우엔 HTTPS·DNS 추가가 필요합니다:
- GitHub Webhook을 받아 자동 빌드 (HTTPS 필수)
- 외부 사용자에게 안정 도메인 제공
- 브라우저의 Mixed Content 경고 회피

추가 시 필요한 것: ACM 인증서 발급 → `aws_acm_certificate` data source → 443 HTTPS 리스너 + 80→443 redirect → Route53 alias record. 한 PR로 추가 가능.

## 관련 문서

- 토폴로지·비용·배경: `infra/aws-setup.md` (CLI 런북, Terraform과 동일 결과)
- 보안·트레이드오프 결정 기록: `docs/adr/0001-ci-tool-selection.md`, PR #3·#4 설명
