# ============================================================================
# Red: usamos la VPC default de la cuenta + un security group propio.
# Sin VPC custom para mantener la infra mínima (suficiente para 1 servicio).
# ============================================================================

# VPC default de la cuenta. AWS la crea automáticamente. NO la modificamos.
data "aws_vpc" "default" {
  default = true
}

# Subnets de la VPC default (una por AZ disponible).
data "aws_subnets" "default" {
  filter {
    name   = "vpc-id"
    values = [data.aws_vpc.default.id]
  }
}

# Security group = firewall stateful asociado a la EC2.
resource "aws_security_group" "app" {
  name        = "ml-traductores-app"
  description = "App: HTTP/HTTPS publico, SSH desde IP admin, salida libre"
  vpc_id      = data.aws_vpc.default.id

  # Puerto 80: HTTP. Caddy lo usa para el challenge ACME (Let's Encrypt)
  # y para redirigir todo el tráfico HTTP a HTTPS.
  ingress {
    description = "HTTP (Caddy redirige a HTTPS)"
    from_port   = 80
    to_port     = 80
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  # Puerto 443: HTTPS. Aquí entran el webhook de WhatsApp y la API del dashboard.
  ingress {
    description = "HTTPS (webhook + API)"
    from_port   = 443
    to_port     = 443
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  # Puerto 22: SSH. Solo desde la IP del admin (definida en tfvars).
  # En operación normal NO necesitamos SSH (usamos SSM Session Manager).
  # Si tu IP cambia, actualizar ssh_allowed_cidr y `terraform apply`.
  ingress {
    description = "SSH solo desde IP admin"
    from_port   = 22
    to_port     = 22
    protocol    = "tcp"
    cidr_blocks = [var.ssh_allowed_cidr]
  }

  # Tráfico de salida: completamente libre. Necesario para pullear ECR,
  # llamar a Anthropic/Meta, mandar logs a CloudWatch, hacer backups a S3.
  egress {
    description = "Salida libre"
    from_port   = 0
    to_port     = 0
    protocol    = "-1" # todos los protocolos
    cidr_blocks = ["0.0.0.0/0"]
  }
}
