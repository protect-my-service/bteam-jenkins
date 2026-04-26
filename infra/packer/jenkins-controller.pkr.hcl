packer {
  required_version = ">= 1.10"

  required_plugins {
    amazon = {
      version = ">= 1.3.0"
      source  = "github.com/hashicorp/amazon"
    }
  }
}

# ─────────────────────────────────────────────────────────────────────────────
# Variables
# ─────────────────────────────────────────────────────────────────────────────

variable "aws_region" {
  type        = string
  default     = "ap-northeast-2"
  description = "Build이 실행되는 리전. 결과 AMI 도 같은 리전에 생성."
}

variable "instance_type" {
  type        = string
  default     = "t3.medium"
  description = "Build 임시 인스턴스 타입. 빌드만 하면 되므로 작아도 OK."
}

variable "jenkins_repo_url" {
  type        = string
  default     = "https://github.com/protect-my-service/bteam-jenkins.git"
  description = "compose / Dockerfile / plugins.txt 를 받아 docker compose build 할 리포."
}

variable "jenkins_repo_ref" {
  type        = string
  default     = "main"
  description = "체크아웃할 branch / tag."
}

variable "jenkins_image_tag" {
  type        = string
  default     = "2.555.1"
  description = "결과 docker 이미지 tag. AMI tag로도 부착."
}

# ─────────────────────────────────────────────────────────────────────────────
# Source — AL2023 latest x86_64
# ─────────────────────────────────────────────────────────────────────────────

source "amazon-ebs" "controller" {
  region        = var.aws_region
  instance_type = var.instance_type

  source_ami_filter {
    owners      = ["amazon"]
    most_recent = true
    filters = {
      name                = "al2023-ami-*-kernel-*-x86_64"
      virtualization-type = "hvm"
      root-device-type    = "ebs"
      architecture        = "x86_64"
    }
  }

  ssh_username = "ec2-user"

  ami_name        = "jenkins-controller-${formatdate("YYYYMMDD-hhmmss", timestamp())}"
  ami_description = "Pre-baked Jenkins controller (Docker + compose plugin + jenkins/jenkins:${var.jenkins_image_tag} with plugins + spot termination handler)"

  tags = {
    Name            = "jenkins-controller-baked"
    Project         = "bteam-jenkins"
    Role            = "controller"
    JenkinsVersion  = var.jenkins_image_tag
    SourceRepoRef   = var.jenkins_repo_ref
    BaseAMI         = "{{ .SourceAMI }}"
    BaseAMIName     = "{{ .SourceAMIName }}"
    PackerBuildTime = "{{ timestamp }}"
  }

  # 임시 빌드 인스턴스용 root 볼륨도 gp3
  launch_block_device_mappings {
    device_name = "/dev/xvda"
    volume_size = 20
    volume_type = "gp3"
    encrypted   = true
  }
}

# ─────────────────────────────────────────────────────────────────────────────
# Build — provisioner 두 단계로 분리 (캐시·재시도 단위 관리)
# ─────────────────────────────────────────────────────────────────────────────

build {
  name    = "jenkins-controller"
  sources = ["source.amazon-ebs.controller"]

  provisioner "shell" {
    script          = "${path.root}/scripts/install-base.sh"
    execute_command = "sudo -E bash '{{ .Path }}'"
  }

  provisioner "shell" {
    script          = "${path.root}/scripts/prebuild-jenkins-image.sh"
    execute_command = "sudo -E bash '{{ .Path }}'"
    environment_vars = [
      "JENKINS_REPO_URL=${var.jenkins_repo_url}",
      "JENKINS_REPO_REF=${var.jenkins_repo_ref}",
      "JENKINS_IMAGE_TAG=${var.jenkins_image_tag}",
    ]
  }
}
