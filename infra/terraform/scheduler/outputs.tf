output "lambda_function_name" {
  description = "수동 invoke / 로그 조회용 Lambda 이름."
  value       = aws_lambda_function.scheduler.function_name
}

output "lambda_arn" {
  description = "Lambda ARN."
  value       = aws_lambda_function.scheduler.arn
}

output "stop_rule_name" {
  description = "정지 EventBridge rule 이름."
  value       = aws_cloudwatch_event_rule.stop.name
}

output "start_rule_name" {
  description = "기동 EventBridge rule 이름. 비활성화 시 null."
  value       = try(aws_cloudwatch_event_rule.start[0].name, null)
}

output "log_group_name" {
  description = "Lambda CloudWatch Log group."
  value       = aws_cloudwatch_log_group.lambda.name
}
