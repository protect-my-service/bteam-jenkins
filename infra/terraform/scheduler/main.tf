data "aws_caller_identity" "current" {}

# ─────────────────────────────────────────────────────────────────────────────
# Lambda 패키지 zip
# ─────────────────────────────────────────────────────────────────────────────

data "archive_file" "lambda_zip" {
  type        = "zip"
  source_dir  = "${path.module}/lambda"
  output_path = "${path.module}/.build/lambda.zip"
}

# ─────────────────────────────────────────────────────────────────────────────
# IAM
# ─────────────────────────────────────────────────────────────────────────────

data "aws_iam_policy_document" "lambda_assume" {
  statement {
    effect = "Allow"
    principals {
      type        = "Service"
      identifiers = ["lambda.amazonaws.com"]
    }
    actions = ["sts:AssumeRole"]
  }
}

resource "aws_iam_role" "lambda" {
  name               = "${var.name_prefix}-lambda-role"
  assume_role_policy = data.aws_iam_policy_document.lambda_assume.json
}

resource "aws_iam_role_policy_attachment" "lambda_logs" {
  role       = aws_iam_role.lambda.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AWSLambdaBasicExecutionRole"
}

# EC2/RDS describe와 stop/start 만 허용. terminate 같은 파괴적 동작은 일체 제외.
data "aws_iam_policy_document" "lambda_inline" {
  statement {
    effect = "Allow"
    actions = [
      "ec2:DescribeInstances",
      "ec2:StopInstances",
      "ec2:StartInstances",
    ]
    resources = ["*"]
  }

  statement {
    effect = "Allow"
    actions = [
      "rds:DescribeDBInstances",
      "rds:DescribeDBClusters",
      "rds:ListTagsForResource",
      "rds:StopDBInstance",
      "rds:StartDBInstance",
      "rds:StopDBCluster",
      "rds:StartDBCluster",
    ]
    resources = ["*"]
  }
}

resource "aws_iam_role_policy" "lambda_inline" {
  name   = "${var.name_prefix}-lambda-inline"
  role   = aws_iam_role.lambda.id
  policy = data.aws_iam_policy_document.lambda_inline.json
}

# ─────────────────────────────────────────────────────────────────────────────
# Lambda
# ─────────────────────────────────────────────────────────────────────────────

resource "aws_cloudwatch_log_group" "lambda" {
  name              = "/aws/lambda/${var.name_prefix}"
  retention_in_days = var.log_retention_days
}

resource "aws_lambda_function" "scheduler" {
  function_name    = var.name_prefix
  role             = aws_iam_role.lambda.arn
  runtime          = "nodejs22.x"
  handler          = "index.handler"
  filename         = data.archive_file.lambda_zip.output_path
  source_code_hash = data.archive_file.lambda_zip.output_base64sha256
  timeout          = var.lambda_timeout
  memory_size      = 256

  environment {
    variables = {
      TAG_KEY   = var.tag_key
      TAG_VALUE = var.tag_value
    }
  }

  depends_on = [
    aws_iam_role_policy.lambda_inline,
    aws_cloudwatch_log_group.lambda,
  ]
}

# ─────────────────────────────────────────────────────────────────────────────
# EventBridge - stop / start 스케줄
# ─────────────────────────────────────────────────────────────────────────────

resource "aws_cloudwatch_event_rule" "stop" {
  name                = "${var.name_prefix}-stop"
  description         = "tag ${var.tag_key}=${var.tag_value} 인 EC2/RDS 정지"
  schedule_expression = var.stop_schedule_expression
}

resource "aws_cloudwatch_event_target" "stop" {
  rule      = aws_cloudwatch_event_rule.stop.name
  target_id = "lambda"
  arn       = aws_lambda_function.scheduler.arn
  input     = jsonencode({ action = "stop" })
}

resource "aws_lambda_permission" "stop" {
  statement_id  = "AllowEventBridgeStop"
  action        = "lambda:InvokeFunction"
  function_name = aws_lambda_function.scheduler.function_name
  principal     = "events.amazonaws.com"
  source_arn    = aws_cloudwatch_event_rule.stop.arn
}

resource "aws_cloudwatch_event_rule" "start" {
  count               = var.enable_auto_start ? 1 : 0
  name                = "${var.name_prefix}-start"
  description         = "tag ${var.tag_key}=${var.tag_value} 인 EC2/RDS 기동"
  schedule_expression = var.start_schedule_expression
}

resource "aws_cloudwatch_event_target" "start" {
  count     = var.enable_auto_start ? 1 : 0
  rule      = aws_cloudwatch_event_rule.start[0].name
  target_id = "lambda"
  arn       = aws_lambda_function.scheduler.arn
  input     = jsonencode({ action = "start" })
}

resource "aws_lambda_permission" "start" {
  count         = var.enable_auto_start ? 1 : 0
  statement_id  = "AllowEventBridgeStart"
  action        = "lambda:InvokeFunction"
  function_name = aws_lambda_function.scheduler.function_name
  principal     = "events.amazonaws.com"
  source_arn    = aws_cloudwatch_event_rule.start[0].arn
}
