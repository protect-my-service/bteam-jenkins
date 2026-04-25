#!/usr/bin/env bash
# Base 패키지 설치 — Docker, Compose plugin, awscli, git, jq, nvme-cli, unzip.
# 모두 user-data가 부팅 시마다 다시 실행하지 않아도 되도록 사전 설치.
set -euxo pipefail

dnf -y update
dnf -y install \
  docker \
  git \
  jq \
  awscli \
  unzip \
  nvme-cli \
  curl

# Docker 활성화 (부팅 시 자동 시작)
systemctl enable docker
systemctl start docker

# Compose v2 plugin (수동 설치 — AL2023의 dnf에는 docker-compose-plugin이 없음)
COMPOSE_VER="v2.29.7"
mkdir -p /usr/libexec/docker/cli-plugins
curl -fsSL "https://github.com/docker/compose/releases/download/${COMPOSE_VER}/docker-compose-linux-$(uname -m)" \
  -o /usr/libexec/docker/cli-plugins/docker-compose
chmod +x /usr/libexec/docker/cli-plugins/docker-compose

# 검증
docker --version
docker compose version
aws --version
git --version

echo "[install-base] done"
