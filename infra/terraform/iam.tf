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

  # ── pms-order 롤링 배포 파이프라인용 ────────────────────────────────────────
  # 파이프라인이 컨트롤러 IAM으로 다음 작업을 수행:
  #   - SSM Parameter Store에서 앱 메타데이터(INSTANCE_IDS, TG_ARN, ECR_REPO 등) 조회
  #   - SSM Run Command로 앱 EC2에서 deploy.sh / stop-old-color.sh / nginx 롤백 실행
  #   - ALB 타겟 deregister/register + healthy 폴링
  #   - ECR에 새 이미지 push
  #   - SSM 명령 출력 → CloudWatch Logs

  statement {
    effect = "Allow"
    actions = [
      "ssm:GetParameter",
      "ssm:GetParameters",
      "ssm:GetParametersByPath",
    ]
    resources = ["arn:aws:ssm:${var.aws_region}:${data.aws_caller_identity.current.account_id}:parameter/pms-order/*"]
  }

  # SendCommand: instance와 document를 분리한다.
  # condition은 statement 전체에 적용되므로, AWS 관리 문서(AWS-RunShellScript)에까지
  # ssm:resourceTag/Project 태그를 요구하면 condition fail로 전체가 deny된다.
  # → instance 리소스에만 Project=pms-order 태그 조건을 걸고, 문서는 무조건 허용.
  statement {
    effect    = "Allow"
    actions   = ["ssm:SendCommand"]
    resources = ["arn:aws:ssm:${var.aws_region}::document/AWS-RunShellScript"]
  }

  statement {
    effect    = "Allow"
    actions   = ["ssm:SendCommand"]
    resources = ["arn:aws:ec2:${var.aws_region}:${data.aws_caller_identity.current.account_id}:instance/*"]
    # 인스턴스는 태그 Project=pms-order 가 붙은 것에만 명령 가능. 운영 안전장치.
    condition {
      test     = "StringEquals"
      variable = "ssm:resourceTag/Project"
      values   = ["pms-order"]
    }
  }

  statement {
    effect = "Allow"
    # 리소스 레벨 스코프 미지원 → wildcard 강제
    actions = [
      "ssm:GetCommandInvocation",
      "ssm:ListCommandInvocations",
      "ssm:DescribeInstanceInformation",
    ]
    resources = ["*"]
  }

  statement {
    effect = "Allow"
    # TG ARN은 SSM에서 런타임 조회 → 학습용 wildcard.
    # 운영 시 SSM 키가 안정화되면 특정 TG ARN 으로 좁힐 것.
    actions = [
      "elasticloadbalancing:DescribeTargetHealth",
      "elasticloadbalancing:DescribeTargetGroups",
      "elasticloadbalancing:RegisterTargets",
      "elasticloadbalancing:DeregisterTargets",
    ]
    resources = ["*"]
  }

  statement {
    effect    = "Allow"
    actions   = ["ec2:DescribeInstances"]
    resources = ["*"]
  }

  statement {
    effect    = "Allow"
    actions   = ["ecr:GetAuthorizationToken"]
    resources = ["*"]
  }

  statement {
    effect = "Allow"
    actions = [
      "ecr:BatchCheckLayerAvailability",
      "ecr:PutImage",
      "ecr:InitiateLayerUpload",
      "ecr:UploadLayerPart",
      "ecr:CompleteLayerUpload",
      "ecr:BatchGetImage",
      "ecr:DescribeRepositories",
    ]
    # 실제 ECR repo 명: b-team/pms-order. b-team 네임스페이스 하위 레포 전체 허용.
    resources = ["arn:aws:ecr:${var.aws_region}:${data.aws_caller_identity.current.account_id}:repository/b-team/*"]
  }

  statement {
    effect = "Allow"
    actions = [
      "logs:CreateLogGroup",
      "logs:CreateLogStream",
      "logs:PutLogEvents",
      "logs:DescribeLogStreams",
    ]
    resources = ["arn:aws:logs:${var.aws_region}:${data.aws_caller_identity.current.account_id}:log-group:/ssm/pms-order-deploy*"]
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
