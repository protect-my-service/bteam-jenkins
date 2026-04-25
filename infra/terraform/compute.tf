# ─────────────────────────────────────────────────────────────────────────────
# Compute — Launch Template + ASG (mixed instance, Spot, capacity rebalance).
# ─────────────────────────────────────────────────────────────────────────────

# AL2023 최신 AMI (SSM 공개 파라미터) — use_baked_ami=false 일 때 사용
data "aws_ssm_parameter" "al2023_ami" {
  name = "/aws/service/ami-amazon-linux-latest/al2023-ami-kernel-default-x86_64"
}

# 사전 빌드된 controller AMI — use_baked_ami=true 일 때 사용
data "aws_ami" "baked_controller" {
  count       = var.use_baked_ami ? 1 : 0
  owners      = ["self"]
  most_recent = true

  filter {
    name   = "tag:Name"
    values = [var.baked_ami_name_filter]
  }

  filter {
    name   = "tag:Project"
    values = ["bteam-jenkins"]
  }

  filter {
    name   = "tag:Role"
    values = ["controller"]
  }

  filter {
    name   = "state"
    values = ["available"]
  }
}

locals {
  controller_ami_id = var.use_baked_ami ? data.aws_ami.baked_controller[0].id : data.aws_ssm_parameter.al2023_ami.value
}

# ── Controller LT ─────────────────────────────────────────────────────────────

locals {
  controller_asg_name     = "jenkins-controller-asg"
  controller_lc_hook_name = "jenkins-controller-launching"
  agent_asg_name          = "jenkins-agent-asg"
  agent_lc_hook_name      = "jenkins-agent-launching"
}

resource "aws_launch_template" "controller" {
  name_prefix = "jenkins-controller-"
  image_id    = local.controller_ami_id

  iam_instance_profile {
    name = aws_iam_instance_profile.controller.name
  }

  vpc_security_group_ids = [aws_security_group.controller.id]

  metadata_options {
    http_endpoint               = "enabled"
    http_tokens                 = "required"
    http_put_response_hop_limit = 2
  }

  block_device_mappings {
    device_name = "/dev/xvda"
    ebs {
      volume_size           = 20
      volume_type           = "gp3"
      delete_on_termination = true
      encrypted             = true
    }
  }

  tag_specifications {
    resource_type = "instance"
    tags = {
      Name = "jenkins-controller"
      Role = "controller"
    }
  }

  user_data = base64encode(templatefile("${path.module}/templates/userdata-controller.sh.tftpl", {
    jenkins_repo_url     = var.jenkins_repo_url
    jenkins_repo_ref     = var.jenkins_repo_ref
    jenkins_repo_raw_url = var.jenkins_repo_raw_url
    jenkins_data_volume  = aws_ebs_volume.jenkins_data.id
    aws_region           = var.aws_region
    asg_name             = local.controller_asg_name
    lifecycle_hook_name  = local.controller_lc_hook_name
  }))

  lifecycle {
    create_before_destroy = true
  }
}

# ── Controller ASG ────────────────────────────────────────────────────────────

resource "aws_autoscaling_group" "controller" {
  name                = local.controller_asg_name
  min_size            = 1
  max_size            = 1
  desired_capacity    = 1
  vpc_zone_identifier = [local.controller_subnet_id] # 단일 AZ (EBS 종속)
  target_group_arns   = [aws_lb_target_group.controller.arn]

  capacity_rebalance        = true
  health_check_type         = "ELB"
  health_check_grace_period = 300

  mixed_instances_policy {
    instances_distribution {
      on_demand_base_capacity                  = 0
      on_demand_percentage_above_base_capacity = 0
      spot_allocation_strategy                 = "capacity-optimized"
    }
    launch_template {
      launch_template_specification {
        launch_template_id = aws_launch_template.controller.id
        version            = "$Latest"
      }
      dynamic "override" {
        for_each = var.controller_instance_types
        content {
          instance_type = override.value
        }
      }
    }
  }

  initial_lifecycle_hook {
    name                 = local.controller_lc_hook_name
    lifecycle_transition = "autoscaling:EC2_INSTANCE_LAUNCHING"
    heartbeat_timeout    = var.lifecycle_hook_heartbeat_timeout
    default_result       = "ABANDON"
  }

  tag {
    key                 = "Name"
    value               = "jenkins-controller"
    propagate_at_launch = false
  }
}

# ── Agent LT ──────────────────────────────────────────────────────────────────

resource "aws_launch_template" "agent" {
  name_prefix = "jenkins-agent-"
  image_id    = data.aws_ssm_parameter.al2023_ami.value

  iam_instance_profile {
    name = aws_iam_instance_profile.agent.name
  }

  vpc_security_group_ids = [aws_security_group.agent.id]

  metadata_options {
    http_endpoint               = "enabled"
    http_tokens                 = "required"
    http_put_response_hop_limit = 2
  }

  tag_specifications {
    resource_type = "instance"
    tags = {
      Name = "jenkins-agent"
      Role = "agent"
    }
  }

  user_data = base64encode(templatefile("${path.module}/templates/userdata-agent.sh.tftpl", {
    aws_region           = var.aws_region
    agent_name           = "linux-agent-1"
    agent_param          = "/jenkins/AGENT_SECRET_1"
    jenkins_repo_url     = var.jenkins_repo_url
    jenkins_repo_raw_url = var.jenkins_repo_raw_url
    asg_name             = local.agent_asg_name
    lifecycle_hook_name  = local.agent_lc_hook_name
  }))

  lifecycle {
    create_before_destroy = true
  }
}

# ── Agent ASG (멀티 AZ) ──────────────────────────────────────────────────────

resource "aws_autoscaling_group" "agent" {
  name                = local.agent_asg_name
  min_size            = var.agent_min_size
  max_size            = var.agent_max_size
  desired_capacity    = var.agent_min_size
  vpc_zone_identifier = data.aws_subnets.default.ids

  capacity_rebalance = true

  mixed_instances_policy {
    instances_distribution {
      on_demand_base_capacity                  = 0
      on_demand_percentage_above_base_capacity = 0
      spot_allocation_strategy                 = "capacity-optimized"
    }
    launch_template {
      launch_template_specification {
        launch_template_id = aws_launch_template.agent.id
        version            = "$Latest"
      }
      dynamic "override" {
        for_each = var.agent_instance_types
        content {
          instance_type = override.value
        }
      }
    }
  }

  initial_lifecycle_hook {
    name                 = local.agent_lc_hook_name
    lifecycle_transition = "autoscaling:EC2_INSTANCE_LAUNCHING"
    heartbeat_timeout    = var.lifecycle_hook_heartbeat_timeout
    default_result       = "ABANDON"
  }

  tag {
    key                 = "Name"
    value               = "jenkins-agent"
    propagate_at_launch = false
  }
}
