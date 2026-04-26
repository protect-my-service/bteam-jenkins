# ─────────────────────────────────────────────────────────────────────────────
# JENKINS_URL — jenkins_url 변수가 있으면 그 값을, 없으면 로컬 기본 URL을
# SSM에 저장. ALB 연결 후 실제 URL로 갱신하는 것을 권장.
#
# 시크릿(JENKINS_ADMIN_PASSWORD, GITHUB_PAT, SLACK_TOKEN)은
# state·plan 노출 방지를 위해 Terraform 밖에서 관리 (README 참조).
# ─────────────────────────────────────────────────────────────────────────────

resource "aws_ssm_parameter" "jenkins_url" {
  name        = "/jenkins/JENKINS_URL"
  type        = "String"
  value       = local.jenkins_url
  description = "Jenkins URL - 외부에서 보는 주소. JCasC location.url 로 사용."
  overwrite   = true
}
