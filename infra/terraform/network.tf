# ─────────────────────────────────────────────────────────────────────────────
# Network — 기본 VPC를 그대로 사용 (학습 단계 단순화). 운영은 별도 VPC + private
# subnet 권장.
# ─────────────────────────────────────────────────────────────────────────────

data "aws_vpc" "default" {
  default = true
}

data "aws_subnets" "default" {
  filter {
    name   = "vpc-id"
    values = [data.aws_vpc.default.id]
  }
}

data "aws_subnet" "by_id" {
  for_each = toset(data.aws_subnets.default.ids)
  id       = each.value
}

# 컨트롤러는 EBS와 같은 AZ로 제한 → 첫 번째 subnet의 AZ를 선택.
locals {
  controller_subnet_id = data.aws_subnets.default.ids[0]
  controller_az        = data.aws_subnet.by_id[local.controller_subnet_id].availability_zone
}

# ─────────────────────────────────────────────────────────────────────────────
# Security Groups — webSocket(JEP-222) 채택으로 50000 인바운드 룰 불필요.
# 에이전트는 ALB(443) 경유라 inbound 룰이 아예 없음 (egress only).
# ─────────────────────────────────────────────────────────────────────────────

resource "aws_security_group" "alb" {
  name        = "jenkins-alb"
  description = "Jenkins ALB — 인터넷에서 80/443"
  vpc_id      = data.aws_vpc.default.id
}

resource "aws_security_group_rule" "alb_http_in" {
  type              = "ingress"
  security_group_id = aws_security_group.alb.id
  from_port         = 80
  to_port           = 80
  protocol          = "tcp"
  cidr_blocks       = ["0.0.0.0/0"]
  description       = "HTTP from Internet (no DNS/HTTPS)"
}

resource "aws_security_group_rule" "alb_egress_all" {
  type              = "egress"
  security_group_id = aws_security_group.alb.id
  from_port         = 0
  to_port           = 0
  protocol          = "-1"
  cidr_blocks       = ["0.0.0.0/0"]
  description       = "All egress"
}

resource "aws_security_group" "controller" {
  name        = "jenkins-controller"
  description = "Jenkins controller — 8080 from ALB only (webSocket은 같은 8080 위에서 wss로 업그레이드)"
  vpc_id      = data.aws_vpc.default.id
}

resource "aws_security_group_rule" "controller_8080_from_alb" {
  type                     = "ingress"
  security_group_id        = aws_security_group.controller.id
  from_port                = 8080
  to_port                  = 8080
  protocol                 = "tcp"
  source_security_group_id = aws_security_group.alb.id
  description              = "HTTP/wss from ALB"
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

resource "aws_security_group" "agent" {
  name        = "jenkins-agent"
  description = "Jenkins agent — egress only (controller에 ALB:443으로 wss 접속)"
  vpc_id      = data.aws_vpc.default.id
}

resource "aws_security_group_rule" "agent_egress_all" {
  type              = "egress"
  security_group_id = aws_security_group.agent.id
  from_port         = 0
  to_port           = 0
  protocol          = "-1"
  cidr_blocks       = ["0.0.0.0/0"]
  description       = "All egress"
}
