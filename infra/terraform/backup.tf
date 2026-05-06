# ============================================================================
# AWS Backup: snapshots EBS automáticos del volumen de datos.
# Capa #2 de backup (la #1 es pg_dump a S3 cada 6h, la #3 es test_restore).
# ============================================================================

resource "aws_backup_vault" "ebs" {
  name = "ml-traductores-ebs"
}

resource "aws_backup_plan" "daily" {
  name = "daily-7d"

  rule {
    rule_name         = "daily"
    target_vault_name = aws_backup_vault.ebs.name

    # Cron AWS: 07:00 UTC = 02:00 hora Bogotá. Hora de baja actividad.
    # NOTA: cron de AWS Backup tiene 6 campos (mins horas DOM mes DOW año).
    schedule = "cron(0 7 ? * * *)"

    lifecycle {
      delete_after = 7
    }
  }
}

# Rol IAM que AWS Backup usa para acceder a los volúmenes EBS.
# Usamos la política managed que AWS provee en lugar de inventar permisos.
resource "aws_iam_role" "backup" {
  name = "ml-traductores-backup"
  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Action    = "sts:AssumeRole"
      Effect    = "Allow"
      Principal = { Service = "backup.amazonaws.com" }
    }]
  })
}

resource "aws_iam_role_policy_attachment" "backup" {
  role       = aws_iam_role.backup.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AWSBackupServiceRolePolicyForBackup"
}

# Selección: qué recursos cubre el plan. Solo el EBS de datos.
# El root NO lo backupeamos: se reconstruye con Terraform + user_data + deploy.
resource "aws_backup_selection" "ebs" {
  iam_role_arn = aws_iam_role.backup.arn
  name         = "ebs-data"
  plan_id      = aws_backup_plan.daily.id

  resources = [aws_ebs_volume.data.arn]
}
