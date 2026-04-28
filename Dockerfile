FROM jenkins/jenkins:2.555.1-lts-jdk21

ARG DOCKER_GID=999

USER root

# Docker CLI: Debian 기본 저장소에 없어 공식 apt repo 추가 필요. unzip은 awscli v2 zip installer용.
RUN apt-get update && apt-get install -y --no-install-recommends \
      ca-certificates curl gnupg lsb-release unzip && \
    install -m 0755 -d /etc/apt/keyrings && \
    curl -fsSL https://download.docker.com/linux/debian/gpg \
      | gpg --dearmor -o /etc/apt/keyrings/docker.gpg && \
    chmod a+r /etc/apt/keyrings/docker.gpg && \
    echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] \
https://download.docker.com/linux/debian $(. /etc/os-release && echo $VERSION_CODENAME) stable" \
      > /etc/apt/sources.list.d/docker.list && \
    apt-get update && \
    apt-get install -y --no-install-recommends docker-ce-cli && \
    rm -rf /var/lib/apt/lists/*

# awscli v2: 파이프라인이 SSM Run Command / ELBv2 / ECR API를 컨테이너에서 직접 호출.
# 컨트롤러 EC2의 instance profile credentials를 IMDSv2 경유로 자동 획득.
# 플러그인 install 레이어보다 위에 두어 plugins.txt 변경 시 awscli 레이어 재사용.
RUN ARCH=$(uname -m) && \
    curl -fsSL "https://awscli.amazonaws.com/awscli-exe-linux-${ARCH}.zip" -o /tmp/awscliv2.zip && \
    unzip -q /tmp/awscliv2.zip -d /tmp && \
    /tmp/aws/install && \
    rm -rf /tmp/aws /tmp/awscliv2.zip && \
    aws --version

RUN (getent group docker && groupmod -g ${DOCKER_GID} docker) \
      || groupadd -g ${DOCKER_GID} docker && \
    usermod -aG docker jenkins

USER jenkins

COPY plugins.txt /usr/share/jenkins/ref/plugins.txt
RUN jenkins-plugin-cli --plugin-file /usr/share/jenkins/ref/plugins.txt --verbose
