#!/usr/bin/env bash
# 스팟 종료 통보(IMDSv2 /spot/instance-action) 폴링 → 컨테이너 graceful 정지
# → (controller) EBS detach → ASG lifecycle CONTINUE
# 환경 파일: /etc/spot-termination-handler/env
#   HANDLER_MODE          - controller | agent
#   COMPOSE_PROJECT_DIR   - controller 모드: docker compose 실행 디렉토리
#   COMPOSE_FILES         - controller 모드: "-f docker-compose.yml -f docker-compose.prod.yml"
#   JENKINS_DATA_VOLUME   - controller 모드: 영속 EBS 볼륨 ID (vol-xxxx)
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
  detach_data_volume
}

# umount 까지 끝난 뒤 EBS를 명시적으로 detach. ASG가 새 인스턴스를 띄울 때
# 같은 볼륨 attach 가 즉시 가능하도록 release 를 앞당긴다.
# 1차: --force 없이 (이미 깨끗이 unmount 됐으므로 정상 detach 가능)
# 2차: 30초 안에 안 떨어지면 --force fallback (umount 끝났으니 데이터 손실 위험 없음)
detach_data_volume() {
  [ -n "${JENKINS_DATA_VOLUME:-}" ] || { log "JENKINS_DATA_VOLUME 미설정 — detach 생략"; return 0; }
  log "detach EBS $JENKINS_DATA_VOLUME (no --force)"
  if aws ec2 detach-volume --region "$AWS_REGION" \
       --volume-id "$JENKINS_DATA_VOLUME" >/dev/null; then
    for i in $(seq 1 15); do
      STATE=$(aws ec2 describe-volumes --region "$AWS_REGION" \
        --volume-ids "$JENKINS_DATA_VOLUME" \
        --query 'Volumes[0].State' --output text 2>/dev/null || echo unknown)
      [ "$STATE" = "available" ] && { log "EBS detach 완료 ($STATE)"; return 0; }
      sleep 2
    done
  fi
  log "detach 지연 — --force fallback (umount 완료 상태이므로 안전)"
  aws ec2 detach-volume --region "$AWS_REGION" \
    --volume-id "$JENKINS_DATA_VOLUME" --force >/dev/null || true
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
