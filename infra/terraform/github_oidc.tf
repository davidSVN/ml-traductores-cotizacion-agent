# ============================================================================
# OIDC: GitHub Actions asume un rol IAM SIN credenciales hardcodeadas.
# La autenticación se basa en el JWT firmado por GitHub.
# Más seguro que poner AWS_ACCESS_KEY_ID en GitHub Secrets.
# ============================================================================

# Provider OIDC: registra a GitHub como emisor de tokens en el que confiamos.
# Solo se hace una vez por cuenta AWS (idempotente — si ya existe, no falla).
resource "aws_iam_openid_connect_provider" "github" {
  url             = "https://token.actions.githubusercontent.com"
  client_id_list  = ["sts.amazonaws.com"]

  # Huella conocida de los certificados de GitHub Actions OIDC.
  # Si GitHub rota su cert, hay que actualizar esto.
  thumbprint_list = ["6938fd4d98bab03faadb97b34396831e3780aea1"]
}

# Rol que GitHub Actions asume al desplegar.
resource "aws_iam_role" "github_actions" {
  name = "ml-traductores-github-actions"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Action    = "sts:AssumeRoleWithWebIdentity"
      Principal = { Federated = aws_iam_openid_connect_provider.github.arn }
      Condition = {
        StringEquals = {
          "token.actions.githubusercontent.com:aud" = "sts.amazonaws.com"
        }
        # SOLO permite asumir el rol desde NUESTRO repo, NUESTRA rama.
        # Si alguien forkea el repo, no puede usarlo.
        StringLike = {
          "token.actions.githubusercontent.com:sub" = "repo:${var.github_repo}:ref:refs/heads/${var.github_branch}"
        }
      }
    }]
  })
}

# Permisos del rol: pushear a ECR + mandar comandos vía SSM.
# Limitado al mínimo necesario.
resource "aws_iam_role_policy" "github_deploy" {
  name = "github-deploy"
  role = aws_iam_role.github_actions.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      # ECR: login + push de la imagen.
      {
        Effect = "Allow"
        Action = [
          "ecr:BatchCheckLayerAvailability",
          "ecr:GetDownloadUrlForLayer",
          "ecr:BatchGetImage",
          "ecr:PutImage",
          "ecr:InitiateLayerUpload",
          "ecr:UploadLayerPart",
          "ecr:CompleteLayerUpload"
        ]
        Resource = aws_ecr_repository.app.arn
      },
      # GetAuthorizationToken NO acepta Resource específico (limitación AWS).
      {
        Effect   = "Allow"
        Action   = "ecr:GetAuthorizationToken"
        Resource = "*"
      },
      # SSM SendCommand: solo a NUESTRA EC2 específica.
      {
        Effect = "Allow"
        Action = "ssm:SendCommand"
        Resource = [
          aws_instance.app.arn,
          "arn:aws:ssm:${var.region}::document/AWS-RunShellScript"
        ]
      },
      # Para esperar y leer el output del comando.
      {
        Effect   = "Allow"
        Action   = ["ssm:GetCommandInvocation", "ssm:ListCommandInvocations"]
        Resource = "*"
      }
    ]
  })
}
