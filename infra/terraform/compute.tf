# Jenkins 컨트롤러 단일 EC2. 학습 목적에서는 ASG/Spot/별도 agent 없이 이 구성이
# 가장 이해하기 쉽고 운영 포인트가 적다.
data "aws_ssm_parameter" "al2023_ami" {
  name = "/aws/service/ami-amazon-linux-latest/al2023-ami-kernel-default-x86_64"
}

resource "aws_instance" "controller" {
  ami                         = data.aws_ssm_parameter.al2023_ami.value
  instance_type               = var.controller_instance_type
  subnet_id                   = var.controller_subnet_id
  associate_public_ip_address = var.associate_public_ip_address
  vpc_security_group_ids      = [aws_security_group.controller.id]

  iam_instance_profile = aws_iam_instance_profile.controller.name

  metadata_options {
    http_endpoint               = "enabled"
    http_tokens                 = "required"
    http_put_response_hop_limit = 2
  }

  root_block_device {
    volume_size           = 20
    volume_type           = "gp3"
    delete_on_termination = true
    encrypted             = true
  }

  tags = {
    Name = "jenkins-controller"
    Role = "controller"
  }

  user_data = templatefile("${path.module}/templates/userdata-controller.sh.tftpl", {
    jenkins_repo_url     = var.jenkins_repo_url
    jenkins_repo_ref     = var.jenkins_repo_ref
    jenkins_repo_raw_url = var.jenkins_repo_raw_url
    jenkins_data_volume  = aws_ebs_volume.jenkins_data.id
    aws_region           = var.aws_region
  })
}
