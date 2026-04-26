variable "aws_region" {
  description = "AWS 리전. 기존 VPC와 같은 리전이어야 함."
  type        = string
  default     = "ap-northeast-2"
}

variable "aws_profile" {
  description = "사용할 AWS CLI 프로파일 이름 (~/.aws/credentials, ~/.aws/config)."
  type        = string
  default     = null
}

# ─────────────────────────────────────────────────────────────────────────────
# 기존 인프라 - 사용자가 직접 ID 제공
# ─────────────────────────────────────────────────────────────────────────────

variable "vpc_id" {
  description = "Jenkins 컨트롤러가 위치할 기존 VPC ID."
  type        = string
}

variable "controller_subnet_id" {
  description = "컨트롤러 EC2와 EBS가 위치할 단일 subnet ID."
  type        = string
}

variable "jenkins_url" {
  description = "Jenkins가 자기 자신을 가리키는 외부 URL. 별도 ALB 연동 후 ALB URL을 넣으면 된다."
  type        = string
  default     = null
}

# ─────────────────────────────────────────────────────────────────────────────
# 리포
# ─────────────────────────────────────────────────────────────────────────────

variable "jenkins_repo_url" {
  description = "user-data가 git clone 할 리포 URL. private이면 별도 토큰 주입 필요."
  type        = string
}

variable "jenkins_repo_ref" {
  description = "체크아웃할 branch 또는 tag."
  type        = string
  default     = "main"
}

variable "jenkins_repo_raw_url" {
  description = "user-data 스크립트 다운로드용 raw 콘텐츠 URL prefix."
  type        = string
}

# ─────────────────────────────────────────────────────────────────────────────
# Compute / Storage
# ─────────────────────────────────────────────────────────────────────────────

variable "controller_instance_type" {
  description = "Jenkins 컨트롤러 EC2 인스턴스 타입."
  type        = string
  default     = "t3.medium"
}

variable "associate_public_ip_address" {
  description = "컨트롤러 EC2에 public IP를 붙일지 여부. public subnet에서 SSM/패키지 다운로드를 단순하게 쓰려면 true."
  type        = bool
  default     = true
}

variable "data_volume_size_gb" {
  description = "jenkins_home 영속 EBS 크기."
  type        = number
  default     = 30
}
