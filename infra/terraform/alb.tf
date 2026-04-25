# ─────────────────────────────────────────────────────────────────────────────
# ALB + Target Group + Listener (HTTP only).
# DNS·ACM 미사용 — ALB의 자동 할당 DNS를 그대로 사용.
# 에이전트는 ws://<alb-dns>/ 로 접속 (webSocket on HTTP, JEP-222).
# webSocket 연결이 끊기지 않도록 idle_timeout 상향 (default 60s).
# ─────────────────────────────────────────────────────────────────────────────

resource "aws_lb" "jenkins" {
  name               = "jenkins-alb"
  load_balancer_type = "application"
  internal           = false
  security_groups    = [aws_security_group.alb.id]
  subnets            = data.aws_subnets.default.ids

  idle_timeout = var.alb_idle_timeout_seconds
}

resource "aws_lb_target_group" "controller" {
  name        = "jenkins-tg"
  port        = 8080
  protocol    = "HTTP"
  vpc_id      = data.aws_vpc.default.id
  target_type = "instance"

  health_check {
    enabled             = true
    protocol            = "HTTP"
    path                = "/login"
    port                = "traffic-port"
    healthy_threshold   = 2
    unhealthy_threshold = 3
    interval            = 30
    timeout             = 10
    matcher             = "200"
  }
}

resource "aws_lb_listener" "http" {
  load_balancer_arn = aws_lb.jenkins.arn
  port              = 80
  protocol          = "HTTP"

  default_action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.controller.arn
  }
}
