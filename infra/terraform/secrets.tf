# ─────────────────────────────────────────────────────────────────────────────
# JENKINS_URL — ALB DNS에서 파생되므로 Terraform이 SSM에 직접 작성.
# 시크릿(JENKINS_ADMIN_PASSWORD, GITHUB_PAT, SLACK_TOKEN, AGENT_SECRET_1)은
# state·plan 노출 방지를 위해 Terraform 밖에서 관리 (README 참조).
# ─────────────────────────────────────────────────────────────────────────────

resource "aws_ssm_parameter" "jenkins_url" {
  name        = "/jenkins/JENKINS_URL"
  type        = "String"
  value       = "http://${aws_lb.jenkins.dns_name}/"
  description = "Jenkins URL (ALB DNS, HTTP). user-data·JCasC가 사용."
  overwrite   = true
}
