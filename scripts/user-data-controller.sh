#!/usr/bin/env bash
# Jenkins controller (Spot EC2) user-data
# 가정: Amazon Linux 2023, IAM 인스턴스 프로파일에 SSM:GetParameter / EC2:AttachVolume / asg:CompleteLifecycleAction 권한
# 환경변수 (Launch Template user-data 윗부분에서 주입):
#   JENKINS_REPO_URL    - 컴포즈 자산을 받을 git URL (예: https://github.com/<org>/bteam-jenkins.git)
#   JENKINS_REPO_REF    - branch/tag (기본: main)
#   JENKINS_DATA_VOLUME - 영속 EBS 볼륨 ID (vol-xxxx). lifecycle: retain.
#   AWS_REGION          - 리전 (예: ap-northeast-2)
#   ASG_NAME            - 컨트롤러 ASG 이름 (lifecycle hook 완료 호출용)
#   LIFECYCLE_HOOK_NAME - launching lifecycle hook 이름

set -euxo pipefail

: "${JENKINS_REPO_URL:?JENKINS_REPO_URL required}"
: "${JENKINS_DATA_VOLUME:?JENKINS_DATA_VOLUME required}"
: "${AWS_REGION:?AWS_REGION required}"
JENKINS_REPO_REF="${JENKINS_REPO_REF:-main}"

dnf install -y docker git jq awscli unzip
systemctl enable --now docker

# Compose v2 plugin
mkdir -p /usr/libexec/docker/cli-plugins
COMPOSE_VER="v2.29.7"
curl -fsSL "https://github.com/docker/compose/releases/download/${COMPOSE_VER}/docker-compose-linux-$(uname -m)" \
  -o /usr/libexec/docker/cli-plugins/docker-compose
chmod +x /usr/libexec/docker/cli-plugins/docker-compose

# IMDSv2 토큰 (이후 메타데이터 조회 공통 사용)
TOKEN=$(curl -fsS -X PUT "http://169.254.169.254/latest/api/token" \
  -H "X-aws-ec2-metadata-token-ttl-seconds: 21600")
INSTANCE_ID=$(curl -fsS -H "X-aws-ec2-metadata-token: $TOKEN" \
  http://169.254.169.254/latest/meta-data/instance-id)
AZ=$(curl -fsS -H "X-aws-ec2-metadata-token: $TOKEN" \
  http://169.254.169.254/latest/meta-data/placement/availability-zone)

# ── 1. EBS 볼륨 attach + 마운트 ────────────────────────────────────────────────
DEVICE=/dev/sdf
aws ec2 attach-volume --region "$AWS_REGION" \
  --volume-id "$JENKINS_DATA_VOLUME" \
  --instance-id "$INSTANCE_ID" \
  --device "$DEVICE"

# nvme 리네이밍 대응: 실제 디바이스 노드가 나타날 때까지 대기
ACTUAL_DEV=""
for i in $(seq 1 60); do
  if [ -b "$DEVICE" ]; then ACTUAL_DEV="$DEVICE"; break; fi
  for d in /dev/nvme*n1; do
    [ -b "$d" ] || continue
    if nvme id-ctrl -o json "$d" 2>/dev/null | jq -re --arg v "${JENKINS_DATA_VOLUME#vol-}" \
        '.sn | sub("^vol";"") == $v' >/dev/null; then
      ACTUAL_DEV="$d"; break 2
    fi
  done
  sleep 2
done
[ -n "$ACTUAL_DEV" ] || { echo "EBS device not found"; exit 1; }

# 비어 있으면 ext4 포맷 (최초 1회)
if ! blkid "$ACTUAL_DEV" >/dev/null 2>&1; then
  mkfs.ext4 -L jenkins-data "$ACTUAL_DEV"
fi

mkdir -p /data/jenkins /data/secrets
UUID=$(blkid -s UUID -o value "$ACTUAL_DEV")
grep -q "$UUID" /etc/fstab || echo "UUID=$UUID /data ext4 defaults,nofail 0 2" >> /etc/fstab
mountpoint -q /data || mount -a

# bind mount 타겟 보정 (jenkins_home 권한: jenkins UID 1000)
mkdir -p /data/jenkins /data/secrets
chown -R 1000:1000 /data/jenkins

# ── 2. SSM Parameter Store에서 시크릿 받아 /etc/jenkins.env 작성 ────────────────
fetch_param() {
  aws ssm get-parameter --region "$AWS_REGION" \
    --name "$1" --with-decryption --query 'Parameter.Value' --output text
}

umask 077
{
  echo "JENKINS_ADMIN_PASSWORD=$(fetch_param /jenkins/JENKINS_ADMIN_PASSWORD)"
  echo "GITHUB_PAT=$(fetch_param /jenkins/GITHUB_PAT || echo '')"
  echo "SLACK_TOKEN=$(fetch_param /jenkins/SLACK_TOKEN || echo '')"
  echo "JENKINS_URL=$(fetch_param /jenkins/JENKINS_URL)"
  echo "DOCKER_GID=$(getent group docker | cut -d: -f3)"
} > /etc/jenkins.env
chmod 600 /etc/jenkins.env

# Deploy key (선택): SSM SecureString → EBS 위 보존 위치
if aws ssm get-parameter --region "$AWS_REGION" --name /jenkins/DEPLOY_KEY --with-decryption \
     --query 'Parameter.Value' --output text > /data/secrets/deploy-key.pem 2>/dev/null; then
  chmod 400 /data/secrets/deploy-key.pem
  chown 1000:1000 /data/secrets/deploy-key.pem
else
  rm -f /data/secrets/deploy-key.pem
  # prod compose의 ro bind 실패 방지 placeholder (없으면 600)
  install -m 600 -o 1000 -g 1000 /dev/null /data/secrets/deploy-key.pem
fi
umask 022

# ── 3. 리포 clone & docker compose up ─────────────────────────────────────────
install -d -o root -m 0755 /opt/jenkins-stack
git clone --depth 1 --branch "$JENKINS_REPO_REF" "$JENKINS_REPO_URL" /opt/jenkins-stack
cd /opt/jenkins-stack

# .env (compose interpolation) — env_file 대용으로 source
set -a; . /etc/jenkins.env; set +a

docker compose -f docker-compose.yml -f docker-compose.prod.yml build
docker compose -f docker-compose.yml -f docker-compose.prod.yml up -d

# ── 4. spot termination handler 설치 + 기동 ───────────────────────────────────
install -m 0755 /opt/jenkins-stack/scripts/spot-termination-handler.sh \
  /usr/local/sbin/spot-termination-handler.sh
install -m 0644 /opt/jenkins-stack/scripts/spot-termination-handler.service \
  /etc/systemd/system/spot-termination-handler.service

# 컨트롤러 모드: docker compose stop 사용
mkdir -p /etc/spot-termination-handler
cat > /etc/spot-termination-handler/env <<EOF
HANDLER_MODE=controller
COMPOSE_PROJECT_DIR=/opt/jenkins-stack
COMPOSE_FILES="-f docker-compose.yml -f docker-compose.prod.yml"
AWS_REGION=$AWS_REGION
ASG_NAME=${ASG_NAME:-}
LIFECYCLE_HOOK_NAME=${LIFECYCLE_HOOK_NAME:-}
EOF

systemctl daemon-reload
systemctl enable --now spot-termination-handler.service

# ── 5. ASG launching lifecycle hook 완료 ─────────────────────────────────────
if [ -n "${ASG_NAME:-}" ] && [ -n "${LIFECYCLE_HOOK_NAME:-}" ]; then
  aws autoscaling complete-lifecycle-action --region "$AWS_REGION" \
    --lifecycle-hook-name "$LIFECYCLE_HOOK_NAME" \
    --auto-scaling-group-name "$ASG_NAME" \
    --instance-id "$INSTANCE_ID" \
    --lifecycle-action-result CONTINUE || true
fi
