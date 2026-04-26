# Jenkins on Existing AWS VPC - 간단 런북

Terraform 적용 전 리소스 관계를 빠르게 이해하기 위한 요약입니다. 실제 생성은 `infra/terraform`을 사용하세요.

## 목표 구조

```
기존 DNS
  -> 기존 ALB listener
  -> Jenkins host-header rule
  -> Jenkins target group
  -> Jenkins controller EC2 1대
  -> EBS gp3 1개(/data/jenkins)
```

## 필요한 기존 값

```bash
export AWS_REGION=ap-northeast-2
export VPC_ID=vpc-...
export CONTROLLER_SUBNET_ID=subnet-...
export ALB_LISTENER_ARN=arn:aws:elasticloadbalancing:...
export JENKINS_HOST=jenkins.example.com
export JENKINS_URL=https://jenkins.example.com/
```

## Terraform 사용

```bash
cd infra/terraform
cp terraform.tfvars.example terraform.tfvars
$EDITOR terraform.tfvars

terraform init
terraform plan -out plan.bin
terraform apply plan.bin
```

## 시크릿 등록

관리자 비밀번호와 선택 연동 토큰은 Terraform state에 남기지 않기 위해 직접 등록합니다.

```bash
aws ssm put-parameter --name /jenkins/JENKINS_ADMIN_PASSWORD --type SecureString --value '<강력한-비번>'
aws ssm put-parameter --name /jenkins/GITHUB_PAT             --type SecureString --value '<github-pat>'   # 선택
aws ssm put-parameter --name /jenkins/SLACK_TOKEN            --type SecureString --value '<slack-token>' # 선택
```

`/jenkins/JENKINS_URL`은 Terraform이 `jenkins_url` 변수값으로 등록합니다.

## 운영 메모

- 학습 목적이라 controller에서 빌드 executor를 직접 실행합니다.
- Jenkins 데이터는 `/data/jenkins`에 mount된 EBS에 보관합니다.
- 장애 자동복구, Spot, 별도 agent, 자동 스냅샷은 지금 구성에서 제외했습니다. 필요해지는 시점에 하나씩 추가하는 편이 관리하기 쉽습니다.
