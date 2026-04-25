provider "aws" {
  region = var.aws_region

  default_tags {
    tags = {
      Project   = "bteam-jenkins"
      ManagedBy = "terraform"
    }
  }
}
