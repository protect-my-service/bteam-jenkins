# ─────────────────────────────────────────────────────────────────────────────
# 영속 EBS — controller_az에 생성. ASG 인스턴스가 user-data에서 attach.
# prevent_destroy로 실수로 인한 데이터 손실 방지 (변경하려면 lifecycle 블록 수정).
# ─────────────────────────────────────────────────────────────────────────────

resource "aws_ebs_volume" "jenkins_data" {
  availability_zone = local.controller_az
  size              = var.data_volume_size_gb
  type              = "gp3"
  encrypted         = true

  tags = {
    Name     = "jenkins-data"
    Snapshot = "true" # DLM target_tag와 일치
  }

  lifecycle {
    prevent_destroy = true
  }
}
