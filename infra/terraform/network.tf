# 기존 VPC 안에 Jenkins 컨트롤러 1대만 배치한다.
data "aws_vpc" "selected" {
  id = var.vpc_id
}

data "aws_subnet" "controller" {
  id = var.controller_subnet_id
}

resource "aws_security_group" "controller" {
  name        = "jenkins-controller"
  description = "Jenkins controller - 8080 from existing VPC only"
  vpc_id      = data.aws_vpc.selected.id
}

resource "aws_security_group_rule" "controller_8080_from_vpc" {
  type              = "ingress"
  security_group_id = aws_security_group.controller.id
  from_port         = 8080
  to_port           = 8080
  protocol          = "tcp"
  cidr_blocks       = [data.aws_vpc.selected.cidr_block]
  description       = "HTTP from existing ALB or VPC clients"
}

resource "aws_security_group_rule" "controller_egress_all" {
  type              = "egress"
  security_group_id = aws_security_group.controller.id
  from_port         = 0
  to_port           = 0
  protocol          = "-1"
  cidr_blocks       = ["0.0.0.0/0"]
  description       = "All egress"
}
