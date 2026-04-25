#!/usr/bin/env bash
# Jenkins controller docker image 를 사전 빌드해 AMI 안의 docker layer cache 에 baking.
# 부팅 시 user-data 가 docker compose build/up 을 호출해도 cache hit 으로 즉시 시작.
#
# 추가로 spot-termination-handler 스크립트 + systemd unit 도 미리 OS에 설치해둠
# (user-data에서 install 단계를 건너뛰어도 되도록).
set -euxo pipefail

: "${JENKINS_REPO_URL:?JENKINS_REPO_URL required}"
: "${JENKINS_REPO_REF:?JENKINS_REPO_REF required}"
: "${JENKINS_IMAGE_TAG:?JENKINS_IMAGE_TAG required}"

WORKDIR=/opt/jenkins-stack-prebuild
rm -rf "$WORKDIR"
git clone --depth 1 --branch "$JENKINS_REPO_REF" "$JENKINS_REPO_URL" "$WORKDIR"

cd "$WORKDIR"

# pms-order-jenkins:${JENKINS_IMAGE_TAG} 빌드 → docker layer cache 에 저장.
# DOCKER_GID 는 빌드 인자라 어떤 값이라도 무관 (실제 GID 는 부팅 시 user-data가 다시 build 하면 갱신).
DOCKER_GID=999 docker compose -f docker-compose.yml build

# 빌드 결과 확인
docker images | grep -i pms-order-jenkins || { echo "image build failed"; exit 1; }

# spot-termination-handler 스크립트 + systemd unit 사전 설치
install -m 0755 "$WORKDIR/scripts/spot-termination-handler.sh" \
  /usr/local/sbin/spot-termination-handler.sh
install -m 0644 "$WORKDIR/scripts/spot-termination-handler.service" \
  /etc/systemd/system/spot-termination-handler.service
# 단, 부팅 시점에 enable — 여기서는 unit 파일만 배치.

# 임시 build 인공물 제거 (AMI 크기 최소화)
rm -rf "$WORKDIR"
docker system prune -f --filter "until=1h" || true

echo "[prebuild-jenkins-image] done"
