variable "aws_region" {
  description = "AWS 리전. 메인 Terraform과 동일하게 us-east-1 기본값."
  type        = string
  default     = "us-east-1"
}

variable "aws_profile" {
  description = "AWS CLI 프로파일."
  type        = string
  default     = null
}

variable "name_prefix" {
  description = "리소스 이름 prefix."
  type        = string
  default     = "bteam-scheduler"
}

variable "tag_key" {
  description = "Lambda가 stop/start 대상으로 인식할 태그 key. 이 태그가 붙은 EC2/RDS만 처리된다."
  type        = string
  default     = "AutoStop"
}

variable "tag_value" {
  description = "tag_key 와 함께 일치해야 할 태그 value."
  type        = string
  default     = "true"
}

variable "stop_schedule_expression" {
  description = "정지 스케줄. 기본값은 매일 02:00 KST = 17:00 UTC(전일)."
  type        = string
  default     = "cron(0 17 * * ? *)"
}

variable "start_schedule_expression" {
  description = "기동 스케줄. 기본값은 매일 09:00 KST = 00:00 UTC."
  type        = string
  default     = "cron(0 0 * * ? *)"
}

variable "enable_auto_start" {
  description = "자동 기동 스케줄을 켤지 여부. 학습용으로 필요할 때만 수동 invoke 하려면 false."
  type        = bool
  default     = false
}

variable "lambda_timeout" {
  description = "Lambda timeout(초). RDS 태그 조회가 인스턴스마다 호출되므로 여유있게."
  type        = number
  default     = 120
}

variable "log_retention_days" {
  description = "Lambda CloudWatch Logs 보관 기간."
  type        = number
  default     = 14
}
