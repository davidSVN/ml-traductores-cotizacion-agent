# ============================================================================
# Inputs configurables. Los valores reales viven en terraform.tfvars
# (NO commiteado, ver .gitignore) o en variables de entorno TF_VAR_*.
# ============================================================================

variable "region" {
  type        = string
  description = "Región AWS donde se desplegará la infraestructura"
  default     = "us-east-1"
}

variable "aws_profile" {
  type        = string
  description = "Nombre del perfil de AWS CLI a usar (ej: ml-traductores)"
  default     = "ml-traductores"
}

variable "instance_type" {
  type        = string
  description = "Tipo de instancia EC2. t4g.micro: 2 vCPU ARM + 1 GB RAM. Free tier 750h/mes año 1."
  default     = "t4g.micro"
}

variable "ssh_key_name" {
  type        = string
  description = "Nombre del key pair en EC2 (creado fuera de Terraform en la consola)"
}

variable "ssh_allowed_cidr" {
  type        = string
  description = "CIDR permitido para SSH de emergencia (ej: 1.2.3.4/32)"

  validation {
    condition     = can(cidrhost(var.ssh_allowed_cidr, 0))
    error_message = "Debe ser un CIDR válido (ej: 1.2.3.4/32)."
  }
}

variable "alert_emails" {
  type        = list(string)
  description = "Emails que reciben alertas de SNS (CPU, errores, disco lleno, etc.)"

  validation {
    condition     = length(var.alert_emails) >= 1
    error_message = "Debes proveer al menos un email para alertas."
  }
}

variable "domain_name" {
  type        = string
  description = "Dominio HTTPS de la API (ej: mltraductores-api.ai-washflow.com). Caddy genera el cert."
}

variable "github_repo" {
  type        = string
  description = "Repo GitHub que puede desplegar (formato: owner/repo)"
}

variable "github_branch" {
  type        = string
  description = "Branch que dispara deploys (típicamente master o main)"
  default     = "master"
}
