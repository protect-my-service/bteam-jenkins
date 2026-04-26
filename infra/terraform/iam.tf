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
