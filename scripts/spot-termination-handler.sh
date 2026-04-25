#!/usr/bin/env bash
# 스팟 종료 통보(IMDSv2 /spot/instance-action) 폴링 → 컨테이너 graceful 정지 → ASG lifecycle CONTINUE
# 환경 파일: /etc/spot-termination-handler/env
#   HANDLER_MODE          - controller | agent
#   COMPOSE_PROJECT_DIR   - controller 모드: docker compose 실행 디렉토리
#   COMPOSE_FILES         - controller 모드: "-f docker-compose.yml -f docker-compose.prod.yml"
#   AGENT_CONTAINER       - agent 모드: 컨테이너 이름 (기본 jenkins-agent)
#   AWS_REGION
#   ASG_NAME              - (선택) terminating lifecycle hook 사용 시
#   LIFECYCLE_HOOK_NAME   - (선택) terminating lifecycle hook 이름

set -uo pipefail

# shellcheck disable=SC1091
. /etc/spot-termination-handler/env

HANDLER_MODE="${HANDLER_MODE:-controller}"
AGENT_CONTAINER="${AGENT_CONTAINER:-jenkins-agent}"
POLL_INTERVAL="${POLL_INTERVAL:-5}"

log() { echo "[spot-handler] $*"; }

renew_token() {
  curl -fsS -X PUT "http://169.254.169.254/latest/api/token" \
    -H "X-aws-ec2-metadata-token-ttl-seconds: 21600" 2>/dev/null
}

graceful_stop_controller() {
  log "controller: docker compose stop (60s timeout)"
  ( cd "$COMPOSE_PROJECT_DIR" && eval docker compose $COMPOSE_FILES stop -t 60 ) || true
  sync
  umount /data 2>/dev/null || true
}

graceful_stop_agent() {
  log "agent: SIGTERM to $AGENT_CONTAINER (60s timeout)"
  docker stop --time 60 "$AGENT_CONTAINER" || true
}

complete_lifecycle() {
  [ -n "${ASG_NAME:-}" ] && [ -n "${LIFECYCLE_HOOK_NAME:-}" ] || return 0
  TOKEN=$(renew_token) || return 0
  INSTANCE_ID=$(curl -fsS -H "X-aws-ec2-metadata-token: $TOKEN" \
    http://169.254.169.254/latest/meta-data/instance-id) || return 0
  aws autoscaling complete-lifecycle-action --region "$AWS_REGION" \
    --lifecycle-hook-name "$LIFECYCLE_HOOK_NAME" \
    --auto-scaling-group-name "$ASG_NAME" \
    --instance-id "$INSTANCE_ID" \
    --lifecycle-action-result CONTINUE || true
}

log "starting in mode=$HANDLER_MODE poll=${POLL_INTERVAL}s"

while true; do
  TOKEN=$(renew_token)
  if [ -z "$TOKEN" ]; then sleep "$POLL_INTERVAL"; continue; fi

  CODE=$(curl -s -o /tmp/spot-action -w "%{http_code}" \
    -H "X-aws-ec2-metadata-token: $TOKEN" \
    http://169.254.169.254/latest/meta-data/spot/instance-action)

  if [ "$CODE" = "200" ]; then
    log "spot interruption notice received: $(cat /tmp/spot-action)"
    case "$HANDLER_MODE" in
      controller) graceful_stop_controller ;;
      agent)      graceful_stop_agent ;;
    esac
    complete_lifecycle
    log "graceful shutdown complete; awaiting termination"
    # 통보 이후 2분 내 EC2가 종료. 핸들러는 자연 종료 대기.
    sleep 180
    exit 0
  fi

  sleep "$POLL_INTERVAL"
done
