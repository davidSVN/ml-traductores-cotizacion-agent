# ============================================================================
# Bucket S3 para backups de Postgres.
# ============================================================================

resource "aws_s3_bucket" "backups" {
  bucket = "ml-traductores-backups"

  # No permitir destroy si tiene objetos. Capa extra contra "rm -rf".
  lifecycle {
    prevent_destroy = true
  }
}

# Versionado: si alguien sobrescribe o borra un objeto, queda una "noncurrent
# version" recuperable durante 30 días. Defensa contra ransomware o errores.
resource "aws_s3_bucket_versioning" "backups" {
  bucket = aws_s3_bucket.backups.id
  versioning_configuration {
    status = "Enabled"
  }
}

# Lifecycle: borra backups después de 30 días para mantenernos en free tier.
resource "aws_s3_bucket_lifecycle_configuration" "backups" {
  bucket = aws_s3_bucket.backups.id

  rule {
    id     = "expire-30d"
    status = "Enabled"

    # Versiones actuales: borrar a los 30 días.
    expiration {
      days = 30
    }

    # Versiones antiguas (sobrescritas/borradas): borrar 30 días después
    # de pasar a noncurrent. Total máximo en bucket: 60 días.
    noncurrent_version_expiration {
      noncurrent_days = 30
    }

    # Limpia uploads multipart abortados (ahorran espacio).
    abort_incomplete_multipart_upload {
      days_after_initiation = 7
    }
  }
}

# Bloquea TODO acceso público al bucket. Defensa contra mis-clicks.
# Backups NUNCA deben ser públicos (contienen toda la data del negocio).
resource "aws_s3_bucket_public_access_block" "backups" {
  bucket                  = aws_s3_bucket.backups.id
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

# Cifrado at-rest con clave gestionada por AWS (gratis, automático).
resource "aws_s3_bucket_server_side_encryption_configuration" "backups" {
  bucket = aws_s3_bucket.backups.id
  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm = "AES256"
    }
  }
}
