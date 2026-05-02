# Auto Stop/Start Scheduler

태그 기반으로 EC2 / RDS 인스턴스 / RDS 클러스터(Aurora 포함)를 EventBridge + Lambda(Node.js 22)로 자동 정지/기동합니다. 학습 환경 비용 절감용.

## 구조

```
EventBridge (cron) ──► Lambda (Node.js 22, AWS SDK v3)
                          │
                          ├─ EC2: tag:AutoStop=true ─► Stop/Start
                          ├─ RDS Instance: tag:AutoStop=true ─► Stop/Start
                          └─ RDS Cluster (Aurora): tag:AutoStop=true ─► Stop/Start
```

기본값: 매일 새벽 02:00 KST 정지. 자동 기동은 꺼져 있고 필요 시 콘솔/CLI에서 수동 invoke.

## 적용

```bash
cd infra/terraform/scheduler
cp terraform.tfvars.example terraform.tfvars
$EDITOR terraform.tfvars

terraform init
terraform plan -out plan.bin
terraform apply plan.bin
```

## 대상 지정 — 태그만 붙이면 끝

자동 정지/기동을 원하는 리소스에 `AutoStop=true` 태그를 붙입니다. (key/value는 변수로 변경 가능)

```bash
# EC2
aws ec2 create-tags --profile my-profile --region us-east-1 \
  --resources i-XXXX i-YYYY \
  --tags Key=AutoStop,Value=true

# RDS 인스턴스
aws rds add-tags-to-resource --profile my-profile --region us-east-1 \
  --resource-name arn:aws:rds:us-east-1:<ACCOUNT>:db:pms-order-db \
  --tags Key=AutoStop,Value=true

# Aurora 클러스터
aws rds add-tags-to-resource --profile my-profile --region us-east-1 \
  --resource-name arn:aws:rds:us-east-1:<ACCOUNT>:cluster:my-aurora \
  --tags Key=AutoStop,Value=true
```

## 수동 테스트

```bash
# 정지
aws lambda invoke --profile my-profile --region us-east-1 \
  --function-name bteam-scheduler \
  --cli-binary-format raw-in-base64-out \
  --payload '{"action":"stop"}' /tmp/out.json && cat /tmp/out.json

# 기동
aws lambda invoke --profile my-profile --region us-east-1 \
  --function-name bteam-scheduler \
  --cli-binary-format raw-in-base64-out \
  --payload '{"action":"start"}' /tmp/out.json && cat /tmp/out.json

# 로그
aws logs tail --profile my-profile --region us-east-1 \
  /aws/lambda/bteam-scheduler --follow
```

## 짚어둘 포인트

- **RDS 7일 자동 기동**: RDS 정지는 7일이 지나면 AWS가 자동 기동한다. 이 모듈은 매일 정지를 다시 수행하므로 학습 환경에서는 자연스럽게 우회된다.
- **Aurora**: 클러스터 단위 stop/start는 cluster API로 처리한다. 클러스터 멤버 인스턴스는 별도 처리하지 않는다(클러스터 stop 시 함께 정지됨).
- **태그 미부착 = 대상 아님**: `AutoStop` 태그 없는 리소스는 절대 건드리지 않는다. 부주의로 실서비스 리소스가 정지되는 사고 방지.
- **권한**: Lambda IAM은 stop/start/describe만 허용. terminate/delete 같은 파괴적 동작은 제외했다.
- **AWS SDK v3**: nodejs22.x 런타임에 번들로 포함되어 있어 `node_modules`를 zip에 넣지 않는다. `archive_file`이 `lambda/` 디렉터리만 압축한다.
- **타임존**: AWS EventBridge cron은 UTC. KST 02:00 정지 = `cron(0 17 * * ? *)` (UTC 기준 전일 17시).
