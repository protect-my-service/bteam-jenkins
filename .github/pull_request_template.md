## 변경 내용

<!-- 무엇을, 왜 변경했는지 간결하게 -->

## 변경 유형

- [ ] 앱 코드 (src/)
- [ ] DB 스키마 (Flyway migration)
- [ ] Dockerfile
- [ ] Jenkinsfile (CI/CD 파이프라인)
- [ ] scripts/deploy.sh (배포 로직)
- [ ] 서비스 인프라 (infra/terraform/)
- [ ] 설정 (application.yml)
- [ ] 문서/ADR
- [ ] 기타:

## 영향 범위

- [ ] Breaking API 변경 (클라이언트 수정 필요)
- [ ] DB 마이그레이션 포함 (롤백 영향 확인)
- [ ] 환경변수 추가/변경 (SSM Parameter Store 업데이트 필요)
- [ ] 인프라 변경 (terraform apply 필요)
- [ ] RabbitMQ 큐/라우팅 키 변경
- [ ] 배포 순서·방식 변경
- [ ] 영향 없음

## 체크리스트

### 공통
- [ ] 로컬 테스트 통과 (`./gradlew test`)
- [ ] 시크릿을 커밋하지 않음

### 앱 변경 시 (B 담당)
- [ ] API 변경 시 하위호환 유지 또는 Expand-Contract 적용
- [ ] `/actuator/health/readiness` 정상 동작 확인
- [ ] 환경변수 추가 시 `application.yml` 기본값 또는 SSM 경로 문서화

### DB 마이그레이션 포함 시
- [ ] Expand-Contract 원칙 준수 (구/신 앱 동시 동작 가능)
- [ ] `DROP COLUMN`, `NOT NULL` 추가 등 위험한 변경은 별도 배포로 분리
- [ ] 롤백 시나리오 검토

### 인프라 변경 시 (A 담당)
- [ ] `terraform plan` 결과 첨부
- [ ] `prevent_destroy` 리소스 확인
- [ ] persistent/ephemeral 계층 경계 준수

### CI/CD 변경 시 (C 담당)
- [ ] Jenkins 파이프라인 dry-run 또는 develop 브랜치 검증
- [ ] 롤백 경로 영향 확인

### 메시징 변경 시 (D 담당)
- [ ] DLQ 설정 확인
- [ ] idempotency key 규약 유지
- [ ] Consumer 하위호환

## 테스트 방법

<!-- 리뷰어가 로컬에서 재현할 수 있는 절차 -->

## 롤백 계획

<!-- 문제 발생 시 되돌리는 절차. 예: 이전 이미지 태그, Flyway undo 전략 -->

## 관련 이슈/문서

- Issue: #
- ADR: