# Terraform IaC - Jenkins on Existing AWS VPC

학습 목적에 맞춰 Jenkins 인스턴스만 기존 AWS VPC에 단순하게 올리는 구성입니다.

## 구조

```
Jenkins controller EC2 1대
  -> EBS gp3 1개(/data/jenkins)
```

이 Terraform은 VPC나 ALB를 새로 만들지 않고, ALB target group/listener rule도 만들지 않습니다. 기존 VPC와 subnet ID를 입력받아 Jenkins용 EC2만 띄웁니다.

## 남긴 것

| 리소스 | 이유 |
|---|---|
| EC2 1대 | Jenkins controller와 빌드를 같은 노드에서 실행해 학습 구조를 단순화 |
| EBS 1개 | `jenkins_home` 보존 |
| SSM Parameter Store | 관리자 비밀번호와 URL 주입 |
| IAM Instance Profile | EC2가 SSM 값을 읽고 EBS를 attach |

## 제거한 것

| 제거 | 이유 |
|---|---|
| ALB / Target Group / Listener Rule | 별도 인프라에서 연동 |
| ASG / Spot mixed policy | 학습 단계에서는 장애 대응보다 이해 가능한 구조가 우선 |
| 별도 agent ASG | controller executor로 충분 |
| DLM 자동 스냅샷 | 백업 전략은 필요해질 때 별도 추가 |
| agent secret 부트스트랩 | agent를 만들지 않으므로 불필요 |

## 사용

```bash
cd infra/terraform
cp terraform.tfvars.example terraform.tfvars
$EDITOR terraform.tfvars

terraform init
terraform fmt -check
terraform validate
terraform plan -out plan.bin
terraform apply plan.bin
```

`terraform.tfvars`에는 최소한 아래 값이 필요합니다.

```hcl
vpc_id               = "vpc-..."
controller_subnet_id = "subnet-..."
# ALB를 별도로 연결한 뒤 필요하면 지정.
# jenkins_url = "http://existing-alb-123456789.ap-northeast-2.elb.amazonaws.com/"
```

## Terraform 밖에서 관리하는 값

시크릿 값은 state 파일에 남기지 않기 위해 Terraform 밖에서 등록합니다.

```bash
aws ssm put-parameter --name /jenkins/JENKINS_ADMIN_PASSWORD --type SecureString --value '<강력한-비번>'
aws ssm put-parameter --name /jenkins/GITHUB_PAT             --type SecureString --value '<github-pat>'   # 선택
aws ssm put-parameter --name /jenkins/SLACK_TOKEN            --type SecureString --value '<slack-token>' # 선택
```

`/jenkins/JENKINS_URL`은 `jenkins_url`을 지정하면 그 값으로, 생략하면 `http://localhost:8080/`으로 Terraform이 등록합니다. ALB 연결 후 실제 ALB URL로 갱신하는 것을 권장합니다.

## 주의

- `controller_subnet_id`의 AZ에 EBS가 생성됩니다. 다른 subnet으로 바꾸면 EBS 마이그레이션을 먼저 고려해야 합니다.
- `aws_ebs_volume.jenkins_data`는 `prevent_destroy = true`입니다. Jenkins 데이터를 실수로 삭제하지 않기 위한 설정입니다.
- SSM Session Manager와 user-data 다운로드가 동작하려면 인스턴스가 AWS SSM, GitHub, Docker Compose 다운로드 URL로 HTTPS 아웃바운드가 가능해야 합니다. public subnet에서는 기본값 `associate_public_ip_address = true`를 사용하세요. private subnet이면 NAT Gateway 또는 SSM VPC Endpoint가 필요합니다.
- user-data에서 `amazon-ssm-agent`를 설치하고 기동합니다. SSM 접속이 안 되면 먼저 EC2가 `describe-instance-information`에 등록되는지 확인하세요.
- controller Security Group은 기존 VPC CIDR에서 8080 접근을 허용합니다. 더 엄격하게 하려면 기존 ALB Security Group ID를 변수로 받아 source SG 방식으로 바꾸면 됩니다.
- 별도 ALB에 붙일 때는 target을 `controller_instance_id`, 포트 `8080`, health check path `/login`으로 잡으면 됩니다.
