#!/usr/bin/env bash
# Jenkins inbound agent (Spot EC2) user-data
# 가정: Amazon Linux 2023, IAM 인스턴스 프로파일에 SSM:GetParameter 권한
# Launch Template user-data 윗부분에서 주입할 변수:
#   AWS_REGION    - 리전 (예: ap-northeast-2)
#   AGENT_NAME    - JCasC에 정의된 노드 이름 (기본: linux-agent-1)
#   AGENT_PARAM   - SSM 파라미터 경로 (기본: /jenkins/AGENT_SECRET_1)
#   ASG_NAME / LIFECYCLE_HOOK_NAME - (선택) launching lifecycle hook 사용 시

set -euxo pipefail

: "${AWS_REGION:?AWS_REGION required}"
AGENT_NAME="${AGENT_NAME:-linux-agent-1}"
AGENT_PARAM="${AGENT_PARAM:-/jenkins/AGENT_SECRET_1}"

dnf install -y docker jq awscli
systemctl enable --now docker

TOKEN=$(curl -fsS -X PUT "http://169.254.169.254/latest/api/token" \
  -H "X-aws-ec2-metadata-token-ttl-seconds: 21600")
INSTANCE_ID=$(curl -fsS -H "X-aws-ec2-metadata-token: $TOKEN" \
  http://169.254.169.254/latest/meta-data/instance-id)

JENKINS_URL=$(aws ssm get-parameter --region "$AWS_REGION" \
  --name /jenkins/JENKINS_URL --query 'Parameter.Value' --output text)
AGENT_SECRET=$(aws ssm get-parameter --region "$AWS_REGION" \
  --name "$AGENT_PARAM" --with-decryption --query 'Parameter.Value' --output text)

docker rm -f jenkins-agent >/dev/null 2>&1 || true
# webSocket(JEP-222) 모드 — JENKINS_URL(=ALB 443) 위 wss 로 controller 와 단일 포트 통신.
# 환경변수명은 jenkinsci/docker-inbound-agent README 명세 준수.
docker run -d --name jenkins-agent --restart=unless-stopped \
  -e JENKINS_URL="$JENKINS_URL" \
  -e JENKINS_AGENT_NAME="$AGENT_NAME" \
  -e JENKINS_SECRET="$AGENT_SECRET" \
  -e JENKINS_AGENT_WORKDIR=/home/jenkins/agent \
  -e JENKINS_WEB_SOCKET=true \
  -v /var/run/docker.sock:/var/run/docker.sock \
  jenkins/inbound-agent:latest

# spot termination handler (graceful disconnect)
install -d /opt/jenkins-stack/scripts
cat > /opt/jenkins-stack/scripts/spot-termination-handler.sh <<'EOF_PLACEHOLDER'
# placeholder; real one is installed from repo if present
EOF_PLACEHOLDER

# 리포에서 실제 핸들러를 받아 설치 (에이전트 모드)
if [ -d /opt/jenkins-stack/.git ] || git clone --depth 1 \
     "${JENKINS_REPO_URL:-}" /opt/jenkins-stack 2>/dev/null; then
  install -m 0755 /opt/jenkins-stack/scripts/spot-termination-handler.sh \
    /usr/local/sbin/spot-termination-handler.sh
  install -m 0644 /opt/jenkins-stack/scripts/spot-termination-handler.service \
    /etc/systemd/system/spot-termination-handler.service
  mkdir -p /etc/spot-termination-handler
  cat > /etc/spot-termination-handler/env <<EOF
HANDLER_MODE=agent
AGENT_CONTAINER=jenkins-agent
AWS_REGION=$AWS_REGION
ASG_NAME=${ASG_NAME:-}
LIFECYCLE_HOOK_NAME=${LIFECYCLE_HOOK_NAME:-}
EOF
  systemctl daemon-reload
  systemctl enable --now spot-termination-handler.service
fi

if [ -n "${ASG_NAME:-}" ] && [ -n "${LIFECYCLE_HOOK_NAME:-}" ]; then
  aws autoscaling complete-lifecycle-action --region "$AWS_REGION" \
    --lifecycle-hook-name "$LIFECYCLE_HOOK_NAME" \
    --auto-scaling-group-name "$ASG_NAME" \
    --instance-id "$INSTANCE_ID" \
    --lifecycle-action-result CONTINUE || true
fi
