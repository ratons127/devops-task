output "ecr_repository_url" {
  description = "Set as the ECR_REPOSITORY GitHub variable (name part only) and used by the app stack."
  value       = aws_ecr_repository.app.repository_url
}

output "ci_role_arn" {
  description = "Set as the AWS_ROLE_ARN GitHub Actions variable."
  value       = aws_iam_role.ci.arn
}
