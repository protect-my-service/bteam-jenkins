# 처음부터 끝까지 — 초보 백엔드 엔지니어를 위한 walkthrough

> 백엔드 코드는 짤 줄 알지만 Jenkins·AWS·Terraform·Packer는 처음이라면, 이 문서를 위에서부터 차근차근 따라 읽으세요. 우리가 만든 결과물뿐 아니라 **왜 그렇게 만들었는지**가 핵심입니다.

---

## 1. 우리가 풀려고 한 문제

회사에서 누군가 말합니다.

> "**자체 호스팅 Jenkins**를 띄워야 해. 외부 SaaS는 안 쓸 거고, **AWS 위에 직접** 올리자. 비용 아끼게 **스팟 인스턴스**로."

이 한 문장 안에 4개의 큰 결정이 숨어 있습니다.

| 결정 | 의미 | 학습 포인트 |
|---|---|---|
| **자체 호스팅** Jenkins | 우리가 서버를 직접 운영 (vs GitHub Actions) | 외부 의존 없음, 대신 운영 책임 |
| **AWS** 위에 | 클라우드 인프라 사용 | EC2·EBS·ALB·SG·IAM 다 우리가 설정 |
| **스팟 인스턴스** | 60-90% 저렴, 대신 2분 통보 후 강제 종료될 수 있음 | "언제든 죽을 수 있다" 가정의 설계 필요 |
| 직접 올리자 | Terraform/CloudFormation 같은 IaC | 손으로 만들고 코드로 재현 가능하게 |

이 4개의 결정이 우리가 한 모든 작업의 토대입니다.

---

## 2. Jenkins 100초 입문 — 두 종류의 서버

Jenkins는 **두 가지 역할**의 서버로 구성됩니다.

```
        🧠 Controller                          🦾 Agent
        ──────────────                         ──────────
   ・ 웹 UI (브라우저로 보는 그것)         ・ 실제 빌드 명령 실행
   ・ "이 잡 실행해" 결정                  ・ git clone, npm test, mvn build
   ・ 잡 설정·이력·credentials 저장        ・ 결과를 controller로 전송
   ・ ❌ 직접 빌드 안 함                   ・ 무상태 (디스크 안 남음)

   죽으면 = 큰일 (UI 다운, 이력 손실)      죽으면 = 그 빌드만 실패
   → 보호 필수                              → 가볍게 굴려도 됨
```

**비유**: Controller는 매장 매니저(주문 받고 누구에게 시킬지 결정), Agent는 요리사(매니저 지시대로 음식 만듦). 매니저가 직접 요리하면 매장이 안 돌아가고, 요리사 한 명 빠져도 다른 요리사가 대신할 수 있음.

이 분리가 우리 설계 전체의 출발점입니다.

---

## 3. 큰 그림 — 우리가 최종적으로 만든 것

```
                    Internet
                       │ 80
              ┌────────▼─────────┐
              │  ALB (HTTP)      │ ← 인스턴스 IP가 바뀌어도 항상 같은 진입점
              │  idle_timeout    │
              │  3600s           │
              └────────┬─────────┘
                       │ 8080
       ┌───────────────▼──────────────────┐
       │  Controller (Spot EC2)           │
       │   ・Pre-baked AMI                 │  ← 부팅 5분 → 60초로 단축
       │   ・Docker로 Jenkins 실행         │
       │   ・JCasC로 자동 설정             │
       │   ・spot 종료 통보 받으면 graceful│
       │     종료 + EBS detach             │
       └──┬───────────────────────────┬───┘
          │                           │ ws:// (webSocket)
          ▼                           ▼
  ┌───────────────┐         ┌────────────────────┐
  │ EBS gp3       │         │ Agent (Spot EC2)   │
  │ 영속 스토리지 │         │  ・무상태           │
  │ (jenkins_home)│         │  ・docker로         │
  │ 보존 보장     │         │    inbound-agent    │
  │ DLM 일일      │         │    실행            │
  │ 스냅샷        │         └────────────────────┘
  └───────────────┘
```

이 그림 한 장이 우리가 한 모든 작업의 도착점이고, 아래 PR 시리즈가 이 그림에 도달한 과정입니다.

---

## 4. 단계별 진화 — PR 시리즈로 본 학습 곡선

### PR #2 — 발 디딤돌: Docker Compose로 Jenkins 띄우기

**무엇을 했나**: 로컬에서 `docker compose up` 한 번으로 Jenkins가 뜨도록 구성.

**왜 그렇게 했나**:
- 본격 클라우드 이전에 **로컬에서 손에 익혀야** 디버깅이 쉽다
- Docker는 어디서든 돌릴 수 있으니, 로컬→클라우드 이전이 매끄럽다

**핵심 도구 소개**:
- **Docker Compose**: 여러 컨테이너(우리는 1개지만 추후 확장)를 한 파일로 정의
- **JCasC (Jenkins Configuration as Code)**: Jenkins 설정을 UI 클릭이 아닌 YAML로. 서버를 처음부터 다시 띄워도 똑같이 재현됨.

**산출물**:
- `docker-compose.yml`, `docker-compose.local.yml`, `docker-compose.prod.yml`
- `Dockerfile` (Jenkins 이미지 + Docker CLI + 22개 플러그인)
- `jcasc/jenkins.yaml` (admin 계정·credentials·권한 자동 설정)

**여기서 배울 것**: 설정을 코드로 두면 **재현 가능**해진다. UI에서 한 번 클릭한 설정은 잊혀지고 사라지지만, YAML은 git에 영원히 남는다.

---

### PR #3 — 클라우드로 옮기기: AWS Spot 토폴로지

**무엇을 했나**: 위 Compose를 AWS Spot EC2 위에서 돌리기 위한 모든 보조 자산 추가.

**해결한 5가지 도전**:

| 도전 | 우리의 답 |
|---|---|
| Spot이 종료되면 데이터(jenkins_home) 사라짐 | **별도 EBS 볼륨**에 저장, 인스턴스와 분리 |
| Spot이 종료되면 인스턴스 사라짐 | **Auto Scaling Group (desired=1)** 가 새 인스턴스 자동 생성 |
| 인스턴스 IP가 바뀜 (GitHub Webhook 못 받음) | **ALB + 도메인** 으로 안정 URL |
| 부팅 시 시크릿(admin password 등) 어떻게 주입 | **AWS SSM Parameter Store**에 저장 → user-data가 IMDSv2로 fetch |
| 빌드 에이전트도 필요 | 별도 ASG로 **agent EC2** 분리 (controller:50000으로 inbound JNLP 연결) |

**핵심 개념 소개**:

- **EC2 Spot Instance**: AWS의 남는 용량을 60-90% 저렴하게. 단, 2분 통보 후 회수될 수 있음.
- **EBS gp3**: 인스턴스와 별도로 존재하는 디스크. 인스턴스 사라져도 데이터 보존 가능.
- **Auto Scaling Group (ASG)**: "desired=1로 항상 1대 유지" 같은 자가치유 자동화.
- **ALB (Application Load Balancer)**: 트래픽을 받아 뒤단 인스턴스로 분배. 인스턴스가 바뀌어도 도메인은 그대로.
- **SSM Parameter Store**: AWS의 무료 시크릿 저장소. `/jenkins/JENKINS_ADMIN_PASSWORD` 같은 경로로 저장.
- **user-data**: EC2 부팅 시 자동 실행되는 스크립트. 우리는 여기서 EBS attach, 시크릿 fetch, docker compose up까지 자동화.

**산출물** (10개 파일):
- `scripts/user-data-controller.sh` (controller 부팅 자동화)
- `scripts/user-data-agent.sh` (agent 부팅 자동화)
- `scripts/spot-termination-handler.{sh,service}` (2분 통보 받고 graceful 종료)
- `infra/aws-setup.md` (AWS CLI 11단계 런북)

**여기서 배울 것**: 클라우드는 "서버를 산다"가 아니라 **"서버가 죽을 수 있다는 가정으로 설계한다"**. EBS와 ASG의 분리가 그 핵심.

---

### PR #4 — 운영 hardening: webSocket + EBS detach + placeholder 제거

**무엇을 했나**: PR #3의 알려진 약점 3가지를 메움.

#### 약점 1: 에이전트가 50000 포트로 직접 controller에 TCP 연결
- **문제**: ALB 우회, SG 룰 추가 필요, NAT 뒤에서 안 됨
- **해결**: **WebSocket(JEP-222)** 으로 전환. ALB(443)을 통해 wss로 연결.
- **결과**: 50000 포트 publish 제거, controller SG 인바운드 룰 1개 줄음, Agent SG는 inbound 아예 없음

#### 약점 2: spot 종료 시 EBS가 즉시 release 안 됨
- **문제**: 새 인스턴스가 띄우려는데 옛 인스턴스가 EBS 잡고 있어서 attach 실패
- **해결**: spot termination handler에 `aws ec2 detach-volume` 호출 추가 (umount 후라 안전)

#### 약점 3: 런북에 `<org>` placeholder 5군데
- **문제**: 사용자가 5번 치환해야 함, 오타 위험
- **해결**: 0단계에 변수 1번 정의, 모든 명령이 그 변수 참조

**여기서 배울 것**: 처음 만든 게 끝이 아니다. **운영하면서 알게 되는 약점**을 다음 PR로 메우는 게 hardening. PR #4·#5는 그 패턴을 보여줌.

---

### PR #5 — 메타: 머지 누락 보정

**무엇을 했나**: PR #4가 GitHub에서 "머지됨"으로 표시됐지만 실제로는 staged branch에만 머지되고 main에 도달 못 함. 별도 PR로 cherry-pick.

**여기서 배울 것**: **stacked PR 함정** — 자식 PR의 base가 부모 PR이면, 부모가 main으로 머지된 뒤에 자식의 base를 main으로 바꿔야 함. 안 그러면 자식은 staged branch에만 머지됨.

---

### PR #6 + #7 — IaC 전환: 손 → Terraform

**무엇을 했나**: PR #3의 11단계 AWS CLI 런북을 **선언적 Terraform 모듈**로 옮김.

**왜?**:

| CLI 런북 (PR #3) | Terraform (PR #6/#7) |
|---|---|
| 한 번 손에 익히기 좋음 | 두 번째부터 동일 결과 보장 |
| 변경 시 어떤 명령을 실행할지 사용자가 판단 | `terraform plan`이 변경분을 자동 계산 |
| 삭제 시 의존성 순서 신경 써야 함 | `terraform destroy`가 알아서 |
| 누가 뭘 만들었는지 추적 어려움 | state 파일에 모두 기록 |

**핵심 도구 소개**:

- **Terraform**: HashiCorp의 IaC 도구. HCL 언어로 인프라를 선언하면 실행하면서 만든다/바꾼다/지운다.
- **Provider**: `hashicorp/aws ~> 6.0` — AWS 리소스를 다루는 플러그인.
- **Resource vs Data Source**: `resource` = "Terraform이 만들어주는 것", `data` = "이미 존재하는 걸 조회하는 것".
- **Variables / Outputs**: 입력 매개변수와 결과값.
- **templatefile()**: 외부 텍스트 파일에 변수를 끼워 넣는 함수. user-data에 사용.

**구조** (`infra/terraform/` 16개 파일):
```
versions.tf      provider 버전 고정
providers.tf     region·default_tags
variables.tf     입력값
network.tf       VPC data + SG 3개
storage.tf       EBS (prevent_destroy)
secrets.tf       JENKINS_URL을 SSM에 자동 등록 (ALB DNS에서 파생)
iam.tf           controller / agent / DLM 역할
compute.tf       Launch Template + ASG (mixed Spot)
alb.tf           ALB + TG + listener
dlm.tf           일일 스냅샷
outputs.tf       URL + 다음 단계 가이드
templates/       user-data 템플릿
```

**중간에 사용자 결정 변경**: "DNS는 따로 안 쓸 거야" → ACM·Route53 제거, ALB DNS 그대로 사용, HTTP-only.

**여기서 배울 것**:
- IaC는 **명령 모음이 아니라 원하는 상태 선언**
- 위험한 자원에 `prevent_destroy`로 안전장치
- 시크릿 값은 state에 들어가지 않게 **외부에서 관리** (SSM)

---

### PR #8 — Operational hardening: Packer로 AMI bake

**무엇을 했나**: 부팅 시 Docker·플러그인·Jenkins 이미지를 매번 새로 받지 않도록, **사전에 모두 설치한 AMI(Amazon Machine Image)를 만듦**.

**왜?**: 사용자가 "학습할 때만 띄울 거야"라고 함. 자주 띄우고 내리는 패턴이면 부팅 시간이 곧 비용·생산성. 5분 → 60초.

**핵심 도구 소개**:

- **Packer**: HashiCorp의 머신 이미지 빌더. "AL2023에서 시작해서 → Docker 설치 → Jenkins 이미지 pull → 그 상태를 AMI로 저장" 같은 절차를 HCL로 정의.
- **AMI (Amazon Machine Image)**: EC2 인스턴스의 시작점이 되는 디스크 이미지. 여기에 미리 다 설치해두면 부팅이 빠름.
- **Immutable Infrastructure**: 인스턴스 안에서 변경하지 말고, 새 AMI 만들어 인스턴스 교체. (오늘 우리가 한 그 패턴)

**산출물**:
- `infra/packer/jenkins-controller.pkr.hcl` — Packer 템플릿
- `infra/packer/scripts/install-base.sh` — Docker, Compose, awscli 설치
- `infra/packer/scripts/prebuild-jenkins-image.sh` — `docker compose build`로 이미지를 layer cache에 baking

**Terraform과 통합**: `var.use_baked_ami = true`로 토글 가능. baked AMI 없는 사용자에는 영향 없음 (default false).

**여기서 배울 것**:
- "**시작 시 매번 같은 일 반복하면 미리 해둬라**" 가 immutable infra의 핵심
- 운영 시간(부팅 5분)은 곧 학습 비용 — 60초로 줄이면 자주 켤 수 있음

---

## 5. 우리가 쓴 두 가지 메타-기법

### 가) 검증 게이트 (Verification Gate)

**언제 적용**: 코드를 쓰기 시작하기 **전에**, 사용할 모든 외부 식별자(API 옵션·필드명·환경변수)를 **공식 출처로 사전 확정**.

**왜?**: AI든 사람이든 기억은 틀린다. 익숙하지 않은 도구일수록 더 그렇다. "그럴듯한 이름"으로 코드를 쓰면 컴파일/validate에서 잡히지 않는 경우가 많다.

**예시**: PR #4에서 ALB idle timeout 키
- WebFetch가 `idle_timeout.connection_settings.idle_timeout.seconds`로 답함 → ❌ 환각
- 로컬 `aws elbv2 modify-load-balancer-attributes help`로 cross-check → 정확한 키 `idle_timeout.timeout_seconds` 발견
- 코드에 박히기 전에 정정

**초보 백엔드 엔지니어가 가져갈 것**: 새 라이브러리·새 API를 쓸 때 **공식 docs 1차 출처**를 한 번 더 보는 5분이 디버깅 5시간을 막아준다.

### 나) 환각 검증 패스 (Hallucination Review Pass)

**언제 적용**: 코드를 다 쓴 **후에**, 작성한 모든 외부 식별자를 한 번 더 cross-check.

**왜?**: 검증 게이트로 사전 확정한 것들도 코드 작성 중에 미묘하게 변형될 수 있음. 두 번 확인.

**예시**: PR #6 (Terraform IaC)
- `aws_ssm_parameter.overwrite` 가 v6에 살아있는지 → 공식 docs 확인 ✓
- `version = "$Latest"` 가 유효한지 → docs에 예시 있음 ✓
- `terraform validate`가 schema 1차 검증, 추가 cross-check 2차 검증

**초보 백엔드 엔지니어가 가져갈 것**: PR 올리기 전 한 번 더 읽기. 본인이 쓴 모든 식별자(메서드명·필드명·옵션명)가 정말 존재하는지 의심.

---

## 6. 최종 결과물 — 무엇을 갖게 되었나

### 코드 자산 (총 7개 PR, 8개 도메인)

```
bteam-jenkins/
├── README.md, docs/adr/             ← 결정 기록
├── Dockerfile, docker-compose*.yml  ← 컨테이너 정의 (PR #2, #4)
├── plugins.txt                       ← Jenkins 플러그인 22개 목록
├── jcasc/jenkins.yaml                ← Jenkins 자동 설정 (PR #2, #4)
├── scripts/                          ← EC2 자동화 (PR #3, #4)
│   ├── user-data-controller.sh
│   ├── user-data-agent.sh
│   ├── spot-termination-handler.sh
│   └── spot-termination-handler.service
└── infra/
    ├── aws-setup.md                  ← CLI 런북 (PR #3, #4)
    ├── terraform/                    ← IaC (PR #6, #7, #8)
    │   ├── versions.tf, providers.tf, variables.tf
    │   ├── network.tf, storage.tf, secrets.tf
    │   ├── iam.tf, compute.tf, alb.tf, dlm.tf
    │   ├── outputs.tf, README.md
    │   └── templates/userdata-*.sh.tftpl
    └── packer/                       ← AMI bake (PR #8)
        ├── jenkins-controller.pkr.hcl
        ├── scripts/install-base.sh
        ├── scripts/prebuild-jenkins-image.sh
        └── README.md
```

### 비용 (학습 패턴, 월 기준)

| 항목 | 비용 | 비고 |
|---|---|---|
| Controller Spot t3.medium | ~$8.5 | 24/7 기준, 토글하면 비례 감소 |
| Agent Spot t3.medium | ~$8.5 | 동상 |
| ALB | ~$20 | 사용량 무관, 고정 |
| EBS gp3 30GB | ~$2.4 | 인스턴스 죽어도 청구 |
| **합계** | **~$40** | DLM·SSM·Route53·CloudWatch 등 무료 티어 |

### 운영 능력

| 능력 | 어떻게 |
|---|---|
| 5분 안에 처음부터 띄우기 | `terraform apply` |
| 인스턴스 죽었을 때 자동 복구 | ASG + EBS retain |
| GitHub Webhook 안정 수신 | ALB DNS (인스턴스 IP 변동 무관) |
| 데이터 손실 안전망 | DLM 일일 스냅샷 (14일 보존) |
| 빌드 능력 N개로 확장 | Agent ASG max_size 조정 |
| 학습 후 비용 0원으로 | `terraform destroy` |

---

## 7. 백엔드 엔지니어가 가져갈 5가지 교훈

### ① 상태(state) 가진 컴포넌트와 무상태 컴포넌트를 분리하라

Controller(상태) ↔ Agent(무상태). DB(상태) ↔ API 서버(무상태). 같은 패턴.
- 상태 가진 쪽: 무겁게 보호 (백업·복구·이중화)
- 무상태 쪽: 가볍게 N개 (오토 스케일·롤링 배포)

### ② 설정은 UI가 아니라 코드로

JCasC, Terraform, Docker Compose 모두 **선언적 코드**. Git 위에 올라가니:
- diff로 변화 추적
- PR 리뷰 가능
- 처음부터 다시 만들어도 같은 결과
- "누가 언제 뭘 바꿨는지" 자동 기록

백엔드라면: application.yml·migration·CI 설정 모두 같은 원칙.

### ③ 재현 가능성 = 디버깅 가능성

로컬 → 스테이징 → 운영이 같은 도구·같은 설정이면 "여기선 됐는데" 가 안 생긴다. 우리가 Docker로 시작한 이유.

### ④ 장애를 가정한 설계 (Spot은 그 극단적 사례)

- 인스턴스가 2분 후 죽는다 가정 → EBS 분리, ASG 자동복구
- 데이터 잃을 수 있다 가정 → DLM 스냅샷
- API가 느려질 수 있다 가정 → 헬스체크, retry, idle timeout

백엔드 코드도 같다: DB connection 끊김, 외부 API 타임아웃, 메시지 큐 중복 — 모두 "정상이 아닐 때"에 대한 설계.

### ⑤ 외부 식별자는 항상 의심하고 1차 출처로 검증

이번에 잡은 환각 1건(`idle_timeout.connection_settings.idle_timeout.seconds`)이 그 예. 공식 docs·소스 코드·해당 도구의 help 명령이 1차 출처. Stack Overflow나 블로그는 참고용.

---

## 부록 — 새로 본 용어 사전

| 용어 | 한 줄 |
|---|---|
| **JCasC** | Jenkins Configuration as Code — UI 설정을 YAML로 |
| **EBS gp3** | AWS의 인스턴스와 분리된 영속 디스크 (범용 SSD) |
| **ASG** | Auto Scaling Group, "이만큼 항상 유지해" 자가치유 |
| **ALB** | Application Load Balancer, 7계층 트래픽 분배 |
| **SSM Parameter Store** | AWS 무료 시크릿 저장소 |
| **IMDSv2** | EC2 인스턴스가 자기 메타데이터 조회하는 보안 강화된 API |
| **JEP-222** | Jenkins WebSocket agent protocol (50000 TCP 대신 wss로) |
| **DLM** | Data Lifecycle Manager, EBS 스냅샷 자동화 |
| **HCL** | HashiCorp Configuration Language (Terraform·Packer 문법) |
| **AMI** | Amazon Machine Image, EC2 디스크 시작점 |
| **Immutable Infra** | 인스턴스 안에서 변경 X, 새로 만들어 교체 |
| **user-data** | EC2 부팅 시 자동 실행되는 스크립트 |
| **Spot Instance** | AWS 남는 용량을 60-90% 저렴하게 (회수 가능) |

---

## 실제로 따라해보고 싶다면

```bash
# 1. 리포 clone
git clone https://github.com/protect-my-service/bteam-jenkins.git
cd bteam-jenkins

# 2. 로컬에서 먼저 돌려보기 (AWS 안 써도 됨)
cp .env.example .env
$EDITOR .env  # JENKINS_ADMIN_PASSWORD만 채우면 OK
docker compose -f docker-compose.yml -f docker-compose.local.yml up -d
docker compose logs -f jenkins  # "Jenkins is fully up" 대기
open http://localhost:8080  # admin / 위에서 정한 비번으로 로그인

# 3. AWS에 올리고 싶다면 (비용 발생, 학습 단계)
cd infra/terraform
cp terraform.tfvars.example terraform.tfvars
$EDITOR terraform.tfvars  # jenkins_repo_url 등 채우기
terraform init
terraform plan -out plan.bin
terraform apply plan.bin
# outputs.tf의 next_steps 따라 SSM에 시크릿 등록
```

여기까지 따라했다면 **Jenkins + AWS Spot + IaC** 의 한 사이클을 직접 경험한 것. 백엔드 엔지니어로서 인프라 측면 사고를 시작하는 좋은 출발점입니다.
