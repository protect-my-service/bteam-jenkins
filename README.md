## 변경 내용

<!-- 무엇을, 왜 -->

## 변경 유형

- [ ] 플러그인 (`plugins.txt`)
- [ ] JCasC 설정
- [ ] Docker / Compose
- [ ] Terraform
- [ ] 스크립트 / 문서

## 체크리스트

- [ ] 시크릿 커밋 없음
- [ ] 플러그인 버전 고정 (`:latest` 금지)
- [ ] 로컬에서 `docker compose up` 기동 확인
- [ ] Terraform 변경 시 `plan` 결과 첨부
- [ ] Jenkins 재시작 필요 여부 명시

## 테스트 / 롤백

<!-- 재현 절차와 문제 시 되돌리는 방법 -->

## 관련 링크

- Issue: #
- ADR:

---

## 처음 실행하기

### Prerequisites

- Docker Desktop (Mac/Win) 또는 Docker Engine + Compose v2 (Linux)
- 호스트 RAM 4GB 이상 여유

### 1단계 — Jenkins 로그인까지

```bash
cp .env.example .env
$EDITOR .env    # JENKINS_ADMIN_PASSWORD만 채우면 충분 (나머지는 빈 값 OK)

docker compose -f docker-compose.yml -f docker-compose.local.yml build
docker compose -f docker-compose.yml -f docker-compose.local.yml up -d

# "Jenkins is fully up and running" 메시지 대기
docker compose logs -f jenkins

# http://localhost:8080 → admin / (JENKINS_ADMIN_PASSWORD) 로그인
```

### 2단계 — 외부 연동 (GitHub / Slack)

1. `.env`에 `GITHUB_PAT`, `SLACK_TOKEN` 값 추가
2. `jcasc/jenkins.yaml`의 `slackNotifier` 블록 주석 해제 + `teamDomain` 채우기
3. 재기동:
   ```bash
   docker compose -f docker-compose.yml -f docker-compose.local.yml up -d --force-recreate
   ```
4. Manage Jenkins → Configuration as Code → **Reload existing configuration**

### 검증 체크리스트

**1단계**
- `curl -fsS -o /dev/null -w "%{http_code}\n" http://localhost:8080/login` → `200`
- admin 로그인 성공
- Manage Jenkins → Configuration as Code → `Last Applied` 성공 표시
- Credentials에서 `github-pat`, `slack-token` 항목이 optional 값(비어 있어도) 존재
- Manage Jenkins → Plugins → `plugins.txt`의 모든 항목 Enabled

**2단계**
- GitHub 자격증명으로 Multibranch job SCM 연결 성공
- Slack 테스트 메시지 송출 성공

### 운영 배포 (기존 AWS VPC)

학습 목적에 맞게 기존 AWS VPC에 Jenkins **단일 EC2 컨트롤러**만 띄웁니다. ALB는 별도 인프라에서 직접 연결합니다.

- **jenkins_home은 별도 EBS gp3** 볼륨에 보관
- **ALB / Target Group / Listener Rule**은 Terraform에서 만들지 않음
- **controller executor**에서 빌드 실행
- ASG, Spot, 별도 agent, DLM은 제외

```bash
# EC2에서는 local 오버라이드 없이 prod만 사용
docker compose -f docker-compose.yml -f docker-compose.prod.yml up -d
```

상세 셋업 절차:
👉 [`infra/aws-setup.md`](infra/aws-setup.md)

핵심 파일:
- `scripts/user-data-controller.sh` — 컨트롤러 EC2 부팅 시 실행 (EBS attach·mount → SSM 시크릿 → docker compose up)
- `docker-compose.prod.yml` — `/data/jenkins`(EBS) bind mount, `/data/secrets/deploy-key.pem` 마운트
- `infra/terraform` — 기존 VPC에 Jenkins EC2와 EBS 추가

운영 시크릿은 `.env` 대신 **SSM Parameter Store (SecureString)** 에 저장 (`/jenkins/JENKINS_ADMIN_PASSWORD`, `/jenkins/GITHUB_PAT`, `/jenkins/SLACK_TOKEN` 등). user-data가 IMDSv2 토큰으로 받아 `/etc/jenkins.env`에 작성한 뒤 compose interpolation에 사용됩니다.

> **EC2에 `docker-compose.local.yml`을 배포하지 마세요** (rsync/Ansible에서 exclude). `JENKINS_URL`은 `${JENKINS_URL:?}` 검사로 누락 시 기동 실패합니다.

### 환경 분리 검증

```bash
# 로컬 — SSH 마운트가 "없어야" 함
docker compose -f docker-compose.yml -f docker-compose.local.yml config

# 운영 — SSH 마운트가 "포함되어야" 함
docker compose -f docker-compose.yml -f docker-compose.prod.yml config

# 플래그 없이 — 공통 베이스만 보이고 local/prod 병합 안 됨
docker compose config
```

---

## 보안 / 운영 주의사항

학습 목적의 단순화 전제로 구성되어 있습니다. 실제 운영으로 전환 시 다음 사항을 검토하세요.

### docker.sock 노출의 위험

`/var/run/docker.sock` 마운트는 컨테이너에 **호스트 Docker root 권한을 사실상 위임**합니다. 컨테이너가 탈취되면 호스트 침해로 이어집니다.

- 학습 단계에서는 편의상 유지
- 운영 목표 아키텍처:
  - **Controller + dedicated agent** 분리
  - 또는 **외부 빌드 런타임** (Kaniko, Buildkit rootless 등) 사용

### 인증 전략 전환 조건

현재는 `loggedInUsersCanDoAnything`입니다. 다음 중 하나 해당 시 `matrix-auth` 또는 OIDC로 전환하세요.

- 사용자 2명 이상 추가
- 외부 조직 인증 (GitHub App, SSO) 도입
- Read / Build / Admin 권한 분리가 필요해질 때

### GitHub 인증

- 학습 단계: 개인 PAT (`GITHUB_PAT`)
- 실운영 권장: **GitHub App 인증** (권한 범위 축소, 감사 추적, 자동 토큰 갱신)
- `admin:repo_hook` 권한은 Jenkins가 웹훅을 **자동 등록**할 때만 필요 — 수동 설정이면 생략

### DOCKER_GID

- Linux 호스트 전용. `getent group docker | cut -d: -f3`로 확인 후 `.env`에 반영
- Mac/Windows Docker Desktop에서는 실질 효과 제한적 (그래도 빌드는 성공)

---

## 트러블슈팅

| 증상 | 원인 | 해결 |
|---|---|---|
| JCasC 파싱 에러 | `jenkins.yaml` 문법 또는 env var 미정의 | `docker compose logs jenkins \| grep -i casc` → 해당 라인 수정 후 재기동 |
| 플러그인 설치 실패 | `plugins.txt` 버전 오타 또는 update center 일시 장애 | `docker compose build --no-cache jenkins` |
| Docker 소켓 권한 거부 (Linux) | 호스트 Docker GID 불일치 | `.env`의 `DOCKER_GID` 재확인 → 재빌드 |
| Setup Wizard 화면이 뜸 | JCasC 로딩 전 진입 | `runSetupWizard=false` JAVA_OPTS 확인, JCasC 에러 로그 점검 |
| 전체 초기화 필요 | 테스트 중 상태 망가짐 | `docker compose down -v` (주의: `jenkins_home` 볼륨 전체 삭제) |
