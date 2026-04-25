# ─────────────────────────────────────────────────────────────────────────────
# DLM — daily snapshot. tag-based targeting (Snapshot=true) 로 jenkins_data만.
# ─────────────────────────────────────────────────────────────────────────────

resource "aws_dlm_lifecycle_policy" "jenkins_data" {
  description        = "jenkins-data daily snapshot"
  execution_role_arn = aws_iam_role.dlm.arn
  state              = "ENABLED"

  policy_details {
    resource_types = ["VOLUME"]

    schedule {
      name = "daily"

      create_rule {
        interval      = 24
        interval_unit = "HOURS"
        times         = [var.snapshot_time_utc]
      }

      retain_rule {
        count = var.snapshot_retention_count
      }

      copy_tags = true
    }

    target_tags = {
      Snapshot = "true"
    }
  }
}
