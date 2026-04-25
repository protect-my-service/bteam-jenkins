# ─────────────────────────────────────────────────────────────────────────────
# IAM — controller / agent / DLM 3종.
# ─────────────────────────────────────────────────────────────────────────────

data "aws_caller_identity" "current" {}

data "aws_iam_policy_document" "ec2_assume_role" {
  statement {
    effect = "Allow"
    principals {
      type        = "Service"
      identifiers = ["ec2.amazonaws.com"]
    }
    actions = ["sts:AssumeRole"]
  }
}

# ── Controller ────────────────────────────────────────────────────────────────

resource "aws_iam_role" "controller" {
  name               = "jenkins-controller-role"
  assume_role_policy = data.aws_iam_policy_document.ec2_assume_role.json
}

resource "aws_iam_role_policy_attachment" "controller_ssm_core" {
  role       = aws_iam_role.controller.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore"
}

data "aws_iam_policy_document" "controller_inline" {
  statement {
    effect    = "Allow"
    actions   = ["ssm:GetParameter", "ssm:GetParameters"]
    resources = ["arn:aws:ssm:${var.aws_region}:${data.aws_caller_identity.current.account_id}:parameter/jenkins/*"]
  }

  statement {
    effect    = "Allow"
    actions   = ["ec2:AttachVolume", "ec2:DetachVolume", "ec2:DescribeVolumes"]
    resources = ["*"]
  }

  statement {
    effect    = "Allow"
    actions   = ["autoscaling:CompleteLifecycleAction"]
    resources = ["*"]
  }
}

resource "aws_iam_role_policy" "controller_inline" {
  name   = "jenkins-controller-inline"
  role   = aws_iam_role.controller.id
  policy = data.aws_iam_policy_document.controller_inline.json
}

resource "aws_iam_instance_profile" "controller" {
  name = "jenkins-controller-profile"
  role = aws_iam_role.controller.name
}

# ── Agent ─────────────────────────────────────────────────────────────────────

resource "aws_iam_role" "agent" {
  name               = "jenkins-agent-role"
  assume_role_policy = data.aws_iam_policy_document.ec2_assume_role.json
}

resource "aws_iam_role_policy_attachment" "agent_ssm_core" {
  role       = aws_iam_role.agent.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore"
}

data "aws_iam_policy_document" "agent_inline" {
  statement {
    effect    = "Allow"
    actions   = ["ssm:GetParameter", "ssm:GetParameters"]
    resources = ["arn:aws:ssm:${var.aws_region}:${data.aws_caller_identity.current.account_id}:parameter/jenkins/*"]
  }

  statement {
    effect    = "Allow"
    actions   = ["autoscaling:CompleteLifecycleAction"]
    resources = ["*"]
  }
}

resource "aws_iam_role_policy" "agent_inline" {
  name   = "jenkins-agent-inline"
  role   = aws_iam_role.agent.id
  policy = data.aws_iam_policy_document.agent_inline.json
}

resource "aws_iam_instance_profile" "agent" {
  name = "jenkins-agent-profile"
  role = aws_iam_role.agent.name
}

# ── DLM ───────────────────────────────────────────────────────────────────────

data "aws_iam_policy_document" "dlm_assume_role" {
  statement {
    effect = "Allow"
    principals {
      type        = "Service"
      identifiers = ["dlm.amazonaws.com"]
    }
    actions = ["sts:AssumeRole"]
  }
}

resource "aws_iam_role" "dlm" {
  name               = "jenkins-dlm-role"
  assume_role_policy = data.aws_iam_policy_document.dlm_assume_role.json
}

data "aws_iam_policy_document" "dlm_inline" {
  statement {
    effect = "Allow"
    actions = [
      "ec2:CreateSnapshot",
      "ec2:CreateSnapshots",
      "ec2:DeleteSnapshot",
      "ec2:DescribeInstances",
      "ec2:DescribeVolumes",
      "ec2:DescribeSnapshots",
    ]
    resources = ["*"]
  }
  statement {
    effect    = "Allow"
    actions   = ["ec2:CreateTags"]
    resources = ["arn:aws:ec2:*::snapshot/*"]
  }
}

resource "aws_iam_role_policy" "dlm_inline" {
  name   = "jenkins-dlm-inline"
  role   = aws_iam_role.dlm.id
  policy = data.aws_iam_policy_document.dlm_inline.json
}
