output "jenkins_url" {
  description = "Jenkins 접속 URL (ALB DNS). 처음엔 ALB 헬스체크 통과 + JCasC 부팅까지 약 5분."
  value       = "http://${aws_lb.jenkins.dns_name}/"
}

output "alb_dns_name" {
  description = "ALB DNS — 디버깅·webhook 등록 시 사용."
  value       = aws_lb.jenkins.dns_name
}

output "controller_asg_name" {
  description = "컨트롤러 ASG 이름 (수동 toggle 시: aws autoscaling set-desired-capacity ...)."
  value       = aws_autoscaling_group.controller.name
}

output "agent_asg_name" {
  description = "에이전트 ASG 이름."
  value       = aws_autoscaling_group.agent.name
}

output "jenkins_data_volume_id" {
  description = "영속 EBS 볼륨 ID. Launch Template user-data가 이 ID로 attach."
  value       = aws_ebs_volume.jenkins_data.id
}

output "controller_az" {
  description = "EBS·controller가 위치한 AZ."
  value       = local.controller_az
}

output "next_steps" {
  description = "apply 후 사용자가 직접 해야 할 작업 (시크릿 SSM + 에이전트 secret 부트스트랩)."
  value       = <<-EOT

    ──────────────────────────────────────────────────────────────────
    Terraform apply 완료. 다음 작업을 순서대로 진행하세요.
    ──────────────────────────────────────────────────────────────────

    1) 시크릿을 SSM Parameter Store에 등록 (Terraform은 값을 관리하지 않음):
       aws ssm put-parameter --name /jenkins/JENKINS_ADMIN_PASSWORD --type SecureString --value '<강력한-비번>'
       aws ssm put-parameter --name /jenkins/GITHUB_PAT             --type SecureString --value '<github-pat>'    # 선택
       aws ssm put-parameter --name /jenkins/SLACK_TOKEN            --type SecureString --value '<slack-token>'  # 선택
       # JENKINS_URL 은 Terraform이 자동 등록 (ALB DNS 파생).

    2) 컨트롤러 ASG가 인스턴스를 띄울 때까지 대기 (~5분), 그 후 접속:
       http://${aws_lb.jenkins.dns_name}/

    3) Manage Jenkins → Nodes → linux-agent-1 → secret 복사 → SSM에 저장:
       aws ssm put-parameter --name /jenkins/AGENT_SECRET_1 --type SecureString --value '<복사한-secret>'

    4) 에이전트 ASG 재시작 (secret 새로 읽도록):
       aws autoscaling set-desired-capacity --auto-scaling-group-name ${aws_autoscaling_group.agent.name} --desired-capacity 0
       # 잠시 후
       aws autoscaling set-desired-capacity --auto-scaling-group-name ${aws_autoscaling_group.agent.name} --desired-capacity ${var.agent_min_size}

    5) 검증: Manage Nodes → linux-agent-1 Online (webSocket on HTTP).

    주의: ALB가 HTTP만 노출합니다. GitHub Webhook은 HTTPS를 요구하므로
    public 코드 트리거가 필요하면 추후 ACM·Route53을 추가해 HTTPS 리스너로 전환하세요.
  EOT
}
