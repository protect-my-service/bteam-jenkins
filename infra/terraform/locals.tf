locals {
  jenkins_url = var.jenkins_url != null && var.jenkins_url != "" ? var.jenkins_url : "http://localhost:8080/"
}
