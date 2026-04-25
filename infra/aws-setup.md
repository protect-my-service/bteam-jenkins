# AWS Spot로 Jenkins 띄우기 — 단계별 런북

학습/개인 환경을 가정한 수동 셋업입니다. Terraform/CloudFormation 도입 전, **CLI로 한 번 손에 익혀** 어떤 리소스가 왜 필요한지 직접 파악하기 위한 절차입니다. 안정화 후 IaC로 옮기는 것을 권장합니다.

## 산출 토폴로지

```
Internet → Route53(jenkins.example.com)
        → ALB(443 HTTPS, ACM)  → controller-SG → Controller ASG (desired=1, Spot)
                                                  ↳ EBS gp3 30GB (retain)
                                          ↳ controller:50000 ← Agent ASG (Spot)
```

월 예상 비용 (서울 리전 기준): **~$40** — 컨트롤러+에이전트 t3.medium Spot ($17) + ALB ($20) + EBS 30GB gp3 ($2.4) + Route53 hosted zone ($0.5).

---

## 0. 사전 준비

| 항목 | 비고 |
|---|---|
| AWS 계정 + CLI 로그인 | `aws sts get-caller-identity` |
| 도메인 | Route53 hosted zone 보유 (예: `example.com`) |
| ACM 인증서 | **ALB와 같은 리전**에서 `jenkins.example.com` 발급 + 검증 완료 |
| 리포 접근 | `JENKINS_REPO_URL`로 사용할 git URL (이 리포). private이면 deploy key/PAT 별도 |

```bash
export AWS_REGION=ap-northeast-2
export AWS_PAGER=""

# ── 리포 출처 (모든 user-data가 git clone / curl 로 받아옴) ──
# private 리포면 Launch Template에 GIT_PAT 등을 추가로 넣고 user-data에서 git config 처리.
export JENKINS_REPO_URL="https://github.com/protect-my-service/bteam-jenkins.git"
export JENKINS_REPO_REF="main"
export JENKINS_REPO_RAW_URL="https://raw.githubusercontent.com/protect-my-service/bteam-jenkins/${JENKINS_REPO_REF}"

# ── 도메인 ──
export JENKINS_DOMAIN="jenkins.example.com"
export ROUTE53_ZONE_DNS="example.com"

export VPC_ID=$(aws ec2 describe-vpcs --filters Name=is-default,Values=true \
  --query 'Vpcs[0].VpcId' --output text)
export SUBNETS=$(aws ec2 describe-subnets --filters Name=vpc-id,Values=$VPC_ID \
  --query 'Subnets[].SubnetId' --output text)
echo "VPC=$VPC_ID  SUBNETS=$SUBNETS"
```

기본 VPC를 그대로 사용합니다 (학습 단계). 운영에서는 별도 VPC + private subnet 권장.

---

## 1. Security Group 3개

에이전트는 webSocket(JEP-222)으로 **ALB(443)** 를 통해 controller에 접속합니다 → controller에 별도 50000 인바운드를 열 필요가 없습니다.

```bash
ALB_SG=$(aws ec2 create-security-group --group-name jenkins-alb \
  --description "Jenkins ALB" --vpc-id $VPC_ID --query GroupId --output text)
aws ec2 authorize-security-group-ingress --group-id $ALB_SG \
  --protocol tcp --port 443 --cidr 0.0.0.0/0
aws ec2 authorize-security-group-ingress --group-id $ALB_SG \
  --protocol tcp --port 80 --cidr 0.0.0.0/0

CTRL_SG=$(aws ec2 create-security-group --group-name jenkins-controller \
  --description "Jenkins controller" --vpc-id $VPC_ID --query GroupId --output text)
# 8080: ALB → controller (HTTP + 업그레이드된 wss WebSocket 모두 이 포트로)
aws ec2 authorize-security-group-ingress --group-id $CTRL_SG \
  --protocol tcp --port 8080 --source-group $ALB_SG

AGENT_SG=$(aws ec2 create-security-group --group-name jenkins-agent \
  --description "Jenkins agent (egress only)" --vpc-id $VPC_ID --query GroupId --output text)
# 인바운드 룰 없음 — 에이전트는 outbound 만 (ALB로 wss 접속)

echo "ALB_SG=$ALB_SG  CTRL_SG=$CTRL_SG  AGENT_SG=$AGENT_SG"
```

> SSH는 의도적으로 막아둡니다. 디버깅이 필요하면 SSM Session Manager를 사용하세요.

---

## 2. EBS 영속 볼륨

ASG가 어느 AZ에 인스턴스를 띄우든 같은 볼륨을 attach해야 하므로 **AZ 하나를 선택해 그 AZ로만 ASG를 제한**합니다 (가장 단순한 방식).

```bash
TARGET_AZ=$(echo $SUBNETS | awk '{print $1}' | xargs -I{} aws ec2 describe-subnets \
  --subnet-ids {} --query 'Subnets[0].AvailabilityZone' --output text)

DATA_VOL=$(aws ec2 create-volume --availability-zone $TARGET_AZ \
  --size 30 --volume-type gp3 \
  --tag-specifications 'ResourceType=volume,Tags=[{Key=Name,Value=jenkins-data}]' \
  --query VolumeId --output text)
echo "TARGET_AZ=$TARGET_AZ  DATA_VOL=$DATA_VOL"
```

> ALB는 multi-AZ가 강제이므로 Target Group과 Listener는 모든 AZ를 사용해도 됩니다. **인스턴스 ASG만** `TARGET_AZ` 하나로 제한합니다.

---

## 3. SSM Parameter Store에 시크릿 저장

```bash
aws ssm put-parameter --name /jenkins/JENKINS_ADMIN_PASSWORD \
  --type SecureString --value '<강력한-비번>'
aws ssm put-parameter --name /jenkins/JENKINS_URL \
  --type String --value "https://${JENKINS_DOMAIN}/"
aws ssm put-parameter --name /jenkins/GITHUB_PAT \
  --type SecureString --value '<github-pat>' || true   # 비워둘 거면 생략
aws ssm put-parameter --name /jenkins/SLACK_TOKEN \
  --type SecureString --value '<slack-token>' || true
# AGENT_SECRET_1은 4단계 완료 후 다시 돌아와 추가
```

---

## 4. IAM 인스턴스 프로파일 2개

### 컨트롤러
```bash
cat > /tmp/trust.json <<'EOF'
{"Version":"2012-10-17","Statement":[{"Effect":"Allow",
 "Principal":{"Service":"ec2.amazonaws.com"},"Action":"sts:AssumeRole"}]}
EOF

aws iam create-role --role-name jenkins-controller-role \
  --assume-role-policy-document file:///tmp/trust.json
aws iam attach-role-policy --role-name jenkins-controller-role \
  --policy-arn arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore

cat > /tmp/ctrl-inline.json <<EOF
{"Version":"2012-10-17","Statement":[
 {"Effect":"Allow","Action":["ssm:GetParameter","ssm:GetParameters"],
  "Resource":"arn:aws:ssm:${AWS_REGION}:*:parameter/jenkins/*"},
 {"Effect":"Allow","Action":["ec2:AttachVolume","ec2:DescribeVolumes"],
  "Resource":"*"},
 {"Effect":"Allow","Action":["autoscaling:CompleteLifecycleAction"],
  "Resource":"*"}
]}
EOF
aws iam put-role-policy --role-name jenkins-controller-role \
  --policy-name jenkins-controller-inline --policy-document file:///tmp/ctrl-inline.json

aws iam create-instance-profile --instance-profile-name jenkins-controller-profile
aws iam add-role-to-instance-profile --instance-profile-name jenkins-controller-profile \
  --role-name jenkins-controller-role
```

### 에이전트
```bash
aws iam create-role --role-name jenkins-agent-role \
  --assume-role-policy-document file:///tmp/trust.json
aws iam attach-role-policy --role-name jenkins-agent-role \
  --policy-arn arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore

cat > /tmp/agent-inline.json <<EOF
{"Version":"2012-10-17","Statement":[
 {"Effect":"Allow","Action":["ssm:GetParameter","ssm:GetParameters"],
  "Resource":"arn:aws:ssm:${AWS_REGION}:*:parameter/jenkins/*"},
 {"Effect":"Allow","Action":["autoscaling:CompleteLifecycleAction"],
  "Resource":"*"}
]}
EOF
aws iam put-role-policy --role-name jenkins-agent-role \
  --policy-name jenkins-agent-inline --policy-document file:///tmp/agent-inline.json

aws iam create-instance-profile --instance-profile-name jenkins-agent-profile
aws iam add-role-to-instance-profile --instance-profile-name jenkins-agent-profile \
  --role-name jenkins-agent-role
```

---

## 5. Launch Template 2개

```bash
AMI=$(aws ssm get-parameter \
  --name /aws/service/ami-amazon-linux-latest/al2023-ami-kernel-default-x86_64 \
  --query 'Parameter.Value' --output text)

# 컨트롤러 user-data — 0단계의 JENKINS_REPO_URL/REF/RAW_URL 사용 (placeholder 없음)
cat > /tmp/ctrl-userdata.sh <<EOF
#!/usr/bin/env bash
export JENKINS_REPO_URL="${JENKINS_REPO_URL}"
export JENKINS_REPO_REF="${JENKINS_REPO_REF}"
export JENKINS_DATA_VOLUME="${DATA_VOL}"
export AWS_REGION="${AWS_REGION}"
export ASG_NAME=jenkins-controller-asg
export LIFECYCLE_HOOK_NAME=jenkins-controller-launching
# 본문은 user-data-controller.sh를 인라인으로 붙이거나, 미리 S3/git에서 받아 실행
exec bash <(curl -fsSL "${JENKINS_REPO_RAW_URL}/scripts/user-data-controller.sh")
EOF

CTRL_LT=$(aws ec2 create-launch-template --launch-template-name jenkins-controller-lt \
  --launch-template-data "{
    \"ImageId\":\"$AMI\",
    \"IamInstanceProfile\":{\"Name\":\"jenkins-controller-profile\"},
    \"SecurityGroupIds\":[\"$CTRL_SG\"],
    \"UserData\":\"$(base64 -i /tmp/ctrl-userdata.sh)\",
    \"MetadataOptions\":{\"HttpTokens\":\"required\",\"HttpEndpoint\":\"enabled\"},
    \"BlockDeviceMappings\":[{\"DeviceName\":\"/dev/xvda\",
        \"Ebs\":{\"VolumeSize\":20,\"VolumeType\":\"gp3\",\"DeleteOnTermination\":true}}],
    \"TagSpecifications\":[{\"ResourceType\":\"instance\",
        \"Tags\":[{\"Key\":\"Name\",\"Value\":\"jenkins-controller\"}]}]
  }" --query 'LaunchTemplate.LaunchTemplateId' --output text)

# 에이전트 user-data — 동일한 패턴, AGENT_NAME/AGENT_PARAM만 다름
cat > /tmp/agent-userdata.sh <<EOF
#!/usr/bin/env bash
export AWS_REGION="${AWS_REGION}"
export AGENT_NAME=linux-agent-1
export AGENT_PARAM=/jenkins/AGENT_SECRET_1
export JENKINS_REPO_URL="${JENKINS_REPO_URL}"
export ASG_NAME=jenkins-agent-asg
export LIFECYCLE_HOOK_NAME=jenkins-agent-launching
exec bash <(curl -fsSL "${JENKINS_REPO_RAW_URL}/scripts/user-data-agent.sh")
EOF

AGENT_LT=$(aws ec2 create-launch-template --launch-template-name jenkins-agent-lt \
  --launch-template-data "{
    \"ImageId\":\"$AMI\",
    \"IamInstanceProfile\":{\"Name\":\"jenkins-agent-profile\"},
    \"SecurityGroupIds\":[\"$AGENT_SG\"],
    \"UserData\":\"$(base64 -i /tmp/agent-userdata.sh)\",
    \"MetadataOptions\":{\"HttpTokens\":\"required\",\"HttpEndpoint\":\"enabled\"}
  }" --query 'LaunchTemplate.LaunchTemplateId' --output text)

echo "CTRL_LT=$CTRL_LT  AGENT_LT=$AGENT_LT"
```

---

## 6. ALB + Target Group + Listener

```bash
# Target Group: HTTP 8080, /login health
TG_ARN=$(aws elbv2 create-target-group --name jenkins-tg \
  --protocol HTTP --port 8080 --vpc-id $VPC_ID --target-type instance \
  --health-check-protocol HTTP --health-check-path /login \
  --health-check-interval-seconds 30 --healthy-threshold-count 2 \
  --query 'TargetGroups[0].TargetGroupArn' --output text)

# ALB
ALB_ARN=$(aws elbv2 create-load-balancer --name jenkins-alb \
  --subnets $SUBNETS --security-groups $ALB_SG --scheme internet-facing \
  --type application --query 'LoadBalancers[0].LoadBalancerArn' --output text)

# WebSocket(JEP-222) 에이전트 연결이 끊기지 않도록 idle timeout 을 1시간으로 상향.
# (속성명 `idle_timeout.timeout_seconds`, 범위 1-4000s, 기본 60s — `aws elbv2
# modify-load-balancer-attributes help` 참조)
aws elbv2 modify-load-balancer-attributes --load-balancer-arn $ALB_ARN \
  --attributes Key=idle_timeout.timeout_seconds,Value=3600

# 443 HTTPS (ACM 인증서 ARN 미리 확보)
CERT_ARN=$(aws acm list-certificates --query \
  "CertificateSummaryList[?DomainName=='${JENKINS_DOMAIN}'].CertificateArn" --output text)

aws elbv2 create-listener --load-balancer-arn $ALB_ARN \
  --protocol HTTPS --port 443 --certificates CertificateArn=$CERT_ARN \
  --default-actions Type=forward,TargetGroupArn=$TG_ARN

# 80 → 443 redirect
aws elbv2 create-listener --load-balancer-arn $ALB_ARN \
  --protocol HTTP --port 80 \
  --default-actions Type=redirect,RedirectConfig='{Protocol=HTTPS,Port=443,StatusCode=HTTP_301}'
```

---

## 7. ASG 2개 (Spot, mixed instance policy)

### 컨트롤러 ASG
```bash
# 컨트롤러는 EBS와 같은 AZ로 제한
TARGET_SUBNET=$(aws ec2 describe-subnets --filters \
  Name=vpc-id,Values=$VPC_ID Name=availability-zone,Values=$TARGET_AZ \
  --query 'Subnets[0].SubnetId' --output text)

aws autoscaling create-auto-scaling-group --auto-scaling-group-name jenkins-controller-asg \
  --min-size 1 --max-size 1 --desired-capacity 1 \
  --vpc-zone-identifier $TARGET_SUBNET \
  --target-group-arns $TG_ARN \
  --capacity-rebalance \
  --health-check-type ELB --health-check-grace-period 300 \
  --mixed-instances-policy "{
    \"LaunchTemplate\":{
      \"LaunchTemplateSpecification\":{\"LaunchTemplateId\":\"$CTRL_LT\",\"Version\":\"\$Latest\"},
      \"Overrides\":[
        {\"InstanceType\":\"t3.medium\"},{\"InstanceType\":\"t3a.medium\"},
        {\"InstanceType\":\"m5.large\"},{\"InstanceType\":\"m5a.large\"}
      ]
    },
    \"InstancesDistribution\":{
      \"OnDemandPercentageAboveBaseCapacity\":0,
      \"SpotAllocationStrategy\":\"capacity-optimized\"
    }
  }"

# launching lifecycle hook (user-data 완료 전까지 InService 진입 지연)
aws autoscaling put-lifecycle-hook --lifecycle-hook-name jenkins-controller-launching \
  --auto-scaling-group-name jenkins-controller-asg \
  --lifecycle-transition autoscaling:EC2_INSTANCE_LAUNCHING \
  --heartbeat-timeout 600 --default-result ABANDON
```

### 에이전트 ASG
```bash
aws autoscaling create-auto-scaling-group --auto-scaling-group-name jenkins-agent-asg \
  --min-size 1 --max-size 3 --desired-capacity 1 \
  --vpc-zone-identifier "$(echo $SUBNETS | tr ' ' ',')" \
  --capacity-rebalance \
  --mixed-instances-policy "{
    \"LaunchTemplate\":{
      \"LaunchTemplateSpecification\":{\"LaunchTemplateId\":\"$AGENT_LT\",\"Version\":\"\$Latest\"},
      \"Overrides\":[
        {\"InstanceType\":\"t3.medium\"},{\"InstanceType\":\"t3a.medium\"},
        {\"InstanceType\":\"c5.large\"},{\"InstanceType\":\"c5a.large\"}
      ]
    },
    \"InstancesDistribution\":{
      \"OnDemandPercentageAboveBaseCapacity\":0,
      \"SpotAllocationStrategy\":\"capacity-optimized\"
    }
  }"

aws autoscaling put-lifecycle-hook --lifecycle-hook-name jenkins-agent-launching \
  --auto-scaling-group-name jenkins-agent-asg \
  --lifecycle-transition autoscaling:EC2_INSTANCE_LAUNCHING \
  --heartbeat-timeout 600 --default-result ABANDON
```

---

## 8. Route53 A alias

```bash
ZONE_ID=$(aws route53 list-hosted-zones-by-name --dns-name "${ROUTE53_ZONE_DNS}" \
  --query 'HostedZones[0].Id' --output text | sed 's|/hostedzone/||')
ALB_DNS=$(aws elbv2 describe-load-balancers --load-balancer-arns $ALB_ARN \
  --query 'LoadBalancers[0].DNSName' --output text)
ALB_ZONE=$(aws elbv2 describe-load-balancers --load-balancer-arns $ALB_ARN \
  --query 'LoadBalancers[0].CanonicalHostedZoneId' --output text)

aws route53 change-resource-record-sets --hosted-zone-id $ZONE_ID \
  --change-batch "{\"Changes\":[{\"Action\":\"UPSERT\",\"ResourceRecordSet\":{
    \"Name\":\"${JENKINS_DOMAIN}\",\"Type\":\"A\",
    \"AliasTarget\":{\"HostedZoneId\":\"$ALB_ZONE\",
      \"DNSName\":\"$ALB_DNS\",\"EvaluateTargetHealth\":false}}}]}"
```

---

## 9. DLM (EBS daily snapshot, 14일 보존)

```bash
aws iam create-service-linked-role --aws-service-name dlm.amazonaws.com 2>/dev/null || true
DLM_ROLE=$(aws iam get-role --role-name AWSDataLifecycleManagerDefaultRole \
  --query 'Role.Arn' --output text)

aws dlm create-lifecycle-policy --description "jenkins-data daily" \
  --execution-role-arn $DLM_ROLE --state ENABLED \
  --policy-details '{
    "PolicyType":"EBS_SNAPSHOT_MANAGEMENT",
    "ResourceTypes":["VOLUME"],
    "TargetTags":[{"Key":"Name","Value":"jenkins-data"}],
    "Schedules":[{
      "Name":"daily","CopyTags":true,
      "CreateRule":{"Interval":24,"IntervalUnit":"HOURS","Times":["19:00"]},
      "RetainRule":{"Count":14}
    }]
  }'
```

---

## 10. 최초 부팅 후 한 번만 — Agent secret 등록

ASG로 컨트롤러가 InService가 되면 (`https://${JENKINS_DOMAIN}/` 접속 가능):

1. admin 로그인 → **Manage Jenkins → Nodes → linux-agent-1** → 표시되는 secret 값 복사
2. SSM에 저장:
   ```bash
   aws ssm put-parameter --name /jenkins/AGENT_SECRET_1 \
     --type SecureString --value '<복사한 secret>'
   ```
3. 에이전트 ASG가 user-data 다음 실행에서 secret을 읽어 controller에 connect.
   - 이미 떠 있는 에이전트가 있다면 재시작:
     ```bash
     aws autoscaling set-desired-capacity --auto-scaling-group-name jenkins-agent-asg \
       --desired-capacity 0
     # 잠시 후
     aws autoscaling set-desired-capacity --auto-scaling-group-name jenkins-agent-asg \
       --desired-capacity 1
     ```

---

## 11. 검증 (스팟 종료 복원성)

| # | 절차 | 기대 |
|---|---|---|
| 1 | `https://${JENKINS_DOMAIN}/` 접속 | admin 로그인 OK, JCasC `Last Applied` 성공 |
| 2 | Manage Nodes → `linux-agent-1` | Online (webSocket 연결, ALB 경유) |
| 3 | 컨트롤러 로그에서 `WebSocket` 연결 확인 | `docker logs` 또는 `journalctl`에 `WebSocket connection... open` |
| 4 | freestyle job: `echo hello && sleep 5` 실행 (label `linux`) | 성공 |
| 5 | 컨트롤러 인스턴스 강제 종료: `aws ec2 terminate-instances --instance-ids <id>` | spot handler가 EBS detach 호출 → ASG가 신규 인스턴스 launch (~3분) |
| 6 | EBS 상태 확인 (인스턴스 종료 직후) | `aws ec2 describe-volumes --volume-ids $DATA_VOL --query 'Volumes[0].State'` → `available` (몇 초 안에) |
| 7 | 신규 인스턴스 부팅 완료 후 같은 URL 재접속 | 잡 이력·credentials 그대로 (EBS 보존), 에이전트가 자동 재연결 |
| 8 | DLM 일정 시각 후 EBS 스냅샷 자동 생성 확인 | `aws ec2 describe-snapshots --owner-ids self --filters Name=tag:Name,Values=jenkins-data` |

---

## 정리/철거

```bash
aws autoscaling update-auto-scaling-group --auto-scaling-group-name jenkins-controller-asg \
  --min-size 0 --max-size 0 --desired-capacity 0
aws autoscaling update-auto-scaling-group --auto-scaling-group-name jenkins-agent-asg \
  --min-size 0 --max-size 0 --desired-capacity 0
# 인스턴스 종료 확인 후 ASG/LT/ALB/TG/Listener/Route53 record 순서대로 삭제
# EBS는 retain — 보존하려면 그대로, 비용 절약은 snapshot 후 delete
```

---

## 알려진 한계 (학습 단계 단순화)

- **단일 AZ ASG**: AZ 장애 시 컨트롤러 복구 불가. multi-AZ로 가려면 EBS Multi-Attach 또는 EFS로 전환 필요 (별도 설계).
- **인증**: `loggedInUsersCanDoAnything`. 실 사용자 추가 시 `matrix-auth` 또는 GitHub App OAuth로 전환.
- **컨트롤러 docker.sock**: ALB 뒤에 있지만 여전히 빌드 도커 명령은 컨트롤러 host docker로 들어옴 → 학습 단계에서만 유지. 운영은 빌드를 에이전트로 강제 (controller `numExecutors: 0` 으로 이미 차단됨).
- **컴포즈 자산 배포**: user-data가 git clone으로 받아오는 단순 방식. 실제 운영은 AMI bake 또는 SSM RunCommand로 전환 권장.
