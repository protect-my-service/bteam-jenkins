# Packer — Pre-baked Jenkins Controller AMI

`infra/terraform/`가 가리키는 AMI를 사전 빌드해 컨트롤러 cold start 시간을 **5분 → ~60초**로 단축.

## 무엇이 이미 들어있나

| 항목 | 빌드 시 | 부팅 시 효과 |
|---|---|---|
| Docker engine + 부팅 자동시작 enable | dnf install + systemctl enable | dnf 재실행 시 no-op |
| Docker Compose v2 plugin (v2.29.7) | 수동 다운로드 | curl 재실행 시 no-op |
| awscli, git, jq, nvme-cli, unzip | dnf install | no-op |
| `pms-order-jenkins:2.555.1` docker image (Jenkins + 22 plugins) | `docker compose build` | `docker compose build` 시 cache hit (즉시 완료) → `up -d` 만으로 컨테이너 기동 |
| `/usr/local/sbin/spot-termination-handler.sh` | 사전 install | systemctl enable 만 하면 됨 |
| `/etc/systemd/system/spot-termination-handler.service` | 사전 install | 동상 |

## 들어가지 않는 것 (의도적)

- **시크릿** — SSM Parameter Store 에서 부팅 시 fetch
- **EBS attach/mount** — 인스턴스가 살아 있을 때만 의미
- **JENKINS_URL** — Terraform 이 ALB DNS 로 SSM 에 등록 (또는 사람이 입력)
- **에이전트 secret** — JCasC 가 노드 등록 시 controller 가 생성

## Build

```bash
cd infra/packer

# 자격증명 (예: aws sso login + AWS_PROFILE=...)
aws sts get-caller-identity   # 통과 확인

packer init jenkins-controller.pkr.hcl
packer fmt -check jenkins-controller.pkr.hcl
packer validate jenkins-controller.pkr.hcl
packer build jenkins-controller.pkr.hcl
```

빌드 시간: ~8분 (대부분이 Jenkins 이미지 + 22개 플러그인 다운로드)
빌드 인스턴스 비용: t3.medium × 8분 ≈ ~$0.005

## Terraform 에서 사용

`infra/terraform/terraform.tfvars` 에 다음을 추가:

```hcl
use_baked_ami = true
```

Terraform 의 `data "aws_ami" "baked_controller"` 가 가장 최근의 `Project=bteam-jenkins, Role=controller, Name=jenkins-controller-baked` 태그를 가진 AMI 를 자동 선택합니다.

## 변수 (override 가능)

| 변수 | 기본값 | 설명 |
|---|---|---|
| `aws_region` | `ap-northeast-2` | 빌드·결과 AMI 리전 |
| `instance_type` | `t3.medium` | 빌드 임시 인스턴스 |
| `jenkins_repo_url` | (this repo) | compose · Dockerfile · plugins.txt 출처 |
| `jenkins_repo_ref` | `main` | 체크아웃 ref |
| `jenkins_image_tag` | `2.555.1` | docker image tag = Jenkins LTS 버전 (Dockerfile FROM 과 일치) |

CLI override:
```bash
packer build -var jenkins_repo_ref=feat/some-branch jenkins-controller.pkr.hcl
```

## 재빌드 시점

다음이 변하면 새 AMI 가 필요:
- `Dockerfile` (베이스 이미지·Docker CLI·플러그인 cli 변경)
- `plugins.txt` (플러그인 추가/버전)
- `scripts/spot-termination-handler.{sh,service}` (사전 install 한 그 파일 자체)

다음은 AMI 와 무관 (부팅 시 fresh 적용):
- `jcasc/jenkins.yaml`
- `docker-compose.yml`, `docker-compose.prod.yml`
- `scripts/user-data-*.sh`

> 이유: AMI 안의 docker 이미지는 Jenkins 본체 + 플러그인 만 포함. JCasC YAML 은 compose 의 `./jcasc:/var/jenkins_home/casc_configs:ro` 바인드 마운트로 컨테이너에 노출되므로 git 위 변경이 부팅 시 즉시 반영.

## 정리

오래된 AMI 는 비용만 발생. 주기적으로 정리:

```bash
aws ec2 describe-images --owners self \
  --filters Name=tag:Name,Values=jenkins-controller-baked \
  --query 'sort_by(Images,&CreationDate)[*].[ImageId,CreationDate]' --output table

# N-1 보다 오래된 것 deregister (snapshot 도 같이 삭제)
aws ec2 deregister-image --image-id ami-xxxxxxxx
aws ec2 delete-snapshot   --snapshot-id snap-xxxxxxxx
```
