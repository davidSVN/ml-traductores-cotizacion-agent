# ============================================================================
# Elastic Container Registry: almacena las imágenes Docker de la app.
# Free tier: 500 MB permanente.
# ============================================================================

resource "aws_ecr_repository" "app" {
  name = "ml-traductores-app"

  # Cifrado at-rest de las imágenes.
  encryption_configuration {
    encryption_type = "AES256"
  }

  # Análisis automático de vulnerabilidades en cada push.
  # Útil para detectar CVEs en las dependencias del Dockerfile.
  image_scanning_configuration {
    scan_on_push = true
  }

  # IMMUTABLE = no se puede sobreescribir un tag existente.
  # Esto previene que un push accidental con `:latest` cambie una imagen
  # ya desplegada. Como usamos SHA del commit como tag además de `latest`,
  # mantenemos `latest` MUTABLE para poder ir actualizando.
  image_tag_mutability = "MUTABLE"
}

# Lifecycle: mantener solo las últimas 5 imágenes para no llenar el free tier.
resource "aws_ecr_lifecycle_policy" "app" {
  repository = aws_ecr_repository.app.name

  policy = jsonencode({
    rules = [{
      rulePriority = 1
      description  = "Mantener solo las ultimas 5 imagenes"
      selection = {
        tagStatus   = "any"
        countType   = "imageCountMoreThan"
        countNumber = 5
      }
      action = { type = "expire" }
    }]
  })
}
