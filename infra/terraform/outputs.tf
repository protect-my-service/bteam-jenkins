output "jenkins_url" {
  description = "Jenkins가 JCasC location.url로 사용하는 URL."
  value       = local.jenkins_url
}

output "controller_instance_id" {
  description = "Jenkins 컨트롤러 EC2 인스턴스 ID."
  value       = aws_instance.controller.id
}

output "controller_private_ip" {
  description = "Jenkins 컨트롤러 private IP. 별도 ALB target 등록 시 사용."
  value       = aws_instance.controller.private_ip
}

output "controller_public_ip" {
  description = "Jenkins 컨트롤러 public IP. associate_public_ip_address=false면 null."
  value       = aws_instance.controller.public_ip
}

output "controller_security_group_id" {
  description = "Jenkins 컨트롤러 Security Group ID."
  value       = aws_security_group.controller.id
}

output "jenkins_data_volume_id" {
  description = "jenkins_home 영속 EBS 볼륨 ID."
  value       = aws_ebs_volume.jenkins_data.id
}

output "next_steps" {
  description = "apply 후 사용자가 직접 해야 할 작업."
  value       = <<-EOT

    Terraform apply 완료 후 아래를 확인하세요.

    1) 시크릿을 SSM Parameter Store에 등록:
       aws ssm put-parameter --name /jenkins/JENKINS_ADMIN_PASSWORD --type SecureString --value '<강력한-비번>'
       aws ssm put-parameter --name /jenkins/GITHUB_PAT             --type SecureString --value '<github-pat>'   # 선택
       aws ssm put-parameter --name /jenkins/SLACK_TOKEN            --type SecureString --value '<slack-token>' # 선택

    2) Jenkins 접속:
       ${local.jenkins_url}

    3) 별도 ALB에서 target group을 만들 때 target은 아래 값을 사용:
       instance_id = ${aws_instance.controller.id}
       port        = 8080

    4) Jenkins 컨트롤러 Security Group(${aws_security_group.controller.id})은 VPC CIDR에서 8080 접근을 허용합니다.
       더 좁히려면 ALB Security Group만 source로 허용하도록 수정하세요.
  EOT
}
