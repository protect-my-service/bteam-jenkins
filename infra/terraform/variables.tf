variable "aws_region" {
  description = "AWS 리전. EBS·ALB·ASG 모두 같은 리전에 위치."
  type        = string
  default     = "ap-northeast-2"
}

variable "jenkins_repo_url" {
  description = "user-data가 git clone 할 리포 URL. private이면 별도 토큰 주입 필요."
  type        = string
  # 예: "https://github.com/protect-my-service/bteam-jenkins.git"
}

variable "jenkins_repo_ref" {
  description = "체크아웃할 branch 또는 tag."
  type        = string
  default     = "main"
}

variable "jenkins_repo_raw_url" {
  description = "user-data 스크립트를 curl로 받기 위한 raw 콘텐츠 URL prefix (브랜치까지 포함)."
  type        = string
  # 예: "https://raw.githubusercontent.com/protect-my-service/bteam-jenkins/main"
}

variable "controller_instance_types" {
  description = "컨트롤러 ASG mixed instance overrides. spot 풀 다양성 확보용."
  type        = list(string)
  default     = ["t3.medium", "t3a.medium", "m5.large", "m5a.large"]
}

variable "agent_instance_types" {
  description = "에이전트 ASG mixed instance overrides."
  type        = list(string)
  default     = ["t3.medium", "t3a.medium", "c5.large", "c5a.large"]
}

variable "agent_min_size" {
  description = "에이전트 ASG 최소 대수. 0이면 평소엔 빌드 처리 안 됨."
  type        = number
  default     = 1
}

variable "agent_max_size" {
  description = "에이전트 ASG 최대 대수."
  type        = number
  default     = 3
}

variable "data_volume_size_gb" {
  description = "jenkins_home 영속 EBS 크기."
  type        = number
  default     = 30
}

variable "snapshot_retention_count" {
  description = "DLM이 보관할 EBS 스냅샷 개수."
  type        = number
  default     = 14
}

variable "snapshot_time_utc" {
  description = "DLM 스냅샷 생성 시각 (UTC, HH:MM)."
  type        = string
  default     = "19:00"
}

variable "use_baked_ami" {
  description = "true: infra/packer로 사전 빌드한 controller AMI 사용 (cold start ~5분 → ~60초). false: AL2023 latest를 받아 user-data에서 모두 설치."
  type        = bool
  default     = false
}

variable "baked_ami_name_filter" {
  description = "use_baked_ami=true 일 때 controller AMI 선택 필터 (Name 태그). Packer가 jenkins-controller-baked 로 태그함."
  type        = string
  default     = "jenkins-controller-baked"
}

variable "alb_idle_timeout_seconds" {
  description = "ALB idle timeout. webSocket(JEP-222) 연결 유지를 위해 default 60s에서 상향. 범위 1-4000."
  type        = number
  default     = 3600

  validation {
    condition     = var.alb_idle_timeout_seconds >= 1 && var.alb_idle_timeout_seconds <= 4000
    error_message = "alb_idle_timeout_seconds는 1-4000 범위여야 합니다 (AWS ALB 제한)."
  }
}

variable "lifecycle_hook_heartbeat_timeout" {
  description = "ASG launching lifecycle hook heartbeat (초). user-data 부팅 + docker compose build 시간을 감안."
  type        = number
  default     = 600
}
