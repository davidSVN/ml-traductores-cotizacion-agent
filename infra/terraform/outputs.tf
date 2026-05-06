# ============================================================================
# Outputs que Terraform imprime al final de `apply`.
# Se usan para configurar GitHub Secrets y el DNS de Cloudflare.
# ============================================================================

output "elastic_ip" {
  description = "IP pública estática a apuntar en Cloudflare DNS (registro A)"
  value       = aws_eip.app.public_ip
}

output "ec2_instance_id" {
  description = "ID de la EC2 (va al GitHub Secret EC2_INSTANCE_ID y se usa en SSM)"
  value       = aws_instance.app.id
}

output "ecr_repository_url" {
  description = "URL completa del repo ECR (va al .env de la EC2 como ECR_REGISTRY)"
  value       = aws_ecr_repository.app.repository_url
}

output "github_actions_role_arn" {
  description = "ARN del rol IAM que GitHub Actions asume vía OIDC (va al GitHub Secret AWS_DEPLOY_ROLE_ARN)"
  value       = aws_iam_role.github_actions.arn
}

output "backups_bucket" {
  description = "Bucket S3 para backups de Postgres (va al .env de la EC2 como S3_BACKUPS_BUCKET)"
  value       = aws_s3_bucket.backups.bucket
}

output "sns_topic_arn" {
  description = "ARN del topic SNS de alertas (referencia, no se usa directamente)"
  value       = aws_sns_topic.alerts.arn
}

output "ssm_session_command" {
  description = "Comando para abrir sesión interactiva en la EC2 sin SSH"
  value       = "aws ssm start-session --target ${aws_instance.app.id} --profile ${var.aws_profile}"
}
