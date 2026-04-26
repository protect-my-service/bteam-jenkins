# ─────────────────────────────────────────────────────────────────────────────
# 영속 EBS - controller subnet과 같은 AZ에 생성. EC2 user-data에서 attach.
# prevent_destroy로 실수로 인한 데이터 손실 방지 (변경하려면 lifecycle 블록 수정).
# ─────────────────────────────────────────────────────────────────────────────

resource "aws_ebs_volume" "jenkins_data" {
  availability_zone = data.aws_subnet.controller.availability_zone
  size              = var.data_volume_size_gb
  type              = "gp3"
  encrypted         = true

  tags = {
    Name     = "jenkins-data"
    Snapshot = "true"
  }

  lifecycle {
    prevent_destroy = true
  }
}
