# ADR-0001: CI/CD 도구로 Jenkins 채택

## Status
Accepted — 2026-04-24

## Context
여러 서비스를 같은 인프라에서 운영한다고 가정하며 진행할 예정이며, 외부 SaaS 의존을
피하고자 한다.

## Decision
Jenkins LTS를 Docker Compose + JCasC로 self-hosted 운영한다.

## Rationale

**1. 멀티 서비스 확장성**
Shared Library로 공통 배포 로직 재사용. 서비스가 늘어도 함수 호출로
파이프라인 구성.

**2. 외부 의존성 제거**
우리 AWS 계정 안에서 운영되어 외부 서비스 장애로부터 격리.

**3. 비용 예측**
EC2 고정 비용. 사용량 기반 과금 없음.

**4. AWS 통합**
EC2 Instance Role로 키 없는 AWS 접근.

## Alternatives

| 후보 | 배제 사유                          |
|------|--------------------------------|
| GitHub Actions | 외부 의존성, 사용량 기반 과금, 배포 성능이 비교적 낮음 |
| AWS CodePipeline | AWS 종속, 파이프라인당 과금              |
| GitLab CI | 외부 의존성 또는 별도 서버 운영 부담          |
| CircleCI | 외부 의존성, 사용량 기반 과금              |

## Consequences

**Positive**
- 외부 장애와 독립적 배포
- 비용 예측 가능
- 멀티 서비스 확장 용이

**Negative**
- 초기 구축 공수 → Docker Compose + JCasC로 재현 가능 구축
- 운영 부담(업그레이드·백업) → runbook · 스크립트로 자동화

## Revisit Criteria

- 서비스 10개 초과 시 Kubernetes 기반 CI/CD 재검토
- Jenkins 운영 부담이 생산성에 유의미한 영향을 줄 경우 SaaS 재검토