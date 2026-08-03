resource "aws_ecr_repository" "this" {
  for_each = toset([
    "auth-service",
    "flag-service",
    "targeting-service",
    "evaluation-service",
    "analytics-service",
  ])

  name = each.value

  image_scanning_configuration {
    scan_on_push = true
  }

  force_delete = true
}
