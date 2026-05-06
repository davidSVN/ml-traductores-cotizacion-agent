# ============================================================================
# Logs + alarmas + notificaciones (CloudWatch + SNS) + budget alarm.
# Lo que activa los emails al equipo cuando algo va mal.
# ============================================================================

# ----------------------------------------------------------------------------
# SNS topic = canal de notificaciones.
# Las alarmas mandan al topic; SNS reenvía a los emails suscritos.
# ----------------------------------------------------------------------------
resource "aws_sns_topic" "alerts" {
  name = "ml-traductores-alerts"
}

# Suscribimos cada email. AWS manda un correo de confirmación; hay que
# clickear el link la PRIMERA vez para activar la suscripción.
resource "aws_sns_topic_subscription" "emails" {
  for_each  = toset(var.alert_emails)
  topic_arn = aws_sns_topic.alerts.arn
  protocol  = "email"
  endpoint  = each.value
}

# ----------------------------------------------------------------------------
# Log group de CloudWatch. Todos los logs aterrizan aquí.
# CloudWatch Logs Insights permite queries SQL-like sobre estos logs.
# ----------------------------------------------------------------------------
resource "aws_cloudwatch_log_group" "app" {
  name              = "/ml-traductores/app"
  retention_in_days = 30 # Free tier cubre 5 GB/mes ingesta + storage.
}

# ----------------------------------------------------------------------------
# Métrica derivada de logs: contar líneas con ERROR/CRITICAL/Traceback.
# CloudWatch escanea logs en tiempo real y crea una métrica custom.
# ----------------------------------------------------------------------------
resource "aws_cloudwatch_log_metric_filter" "errors" {
  name           = "app-errors"
  log_group_name = aws_cloudwatch_log_group.app.name

  # Sintaxis "?A ?B ?C" = OR lógico. Match si la línea contiene cualquiera.
  pattern = "?ERROR ?CRITICAL ?Traceback"

  metric_transformation {
    name      = "AppErrors"
    namespace = "MLTraductores"
    value     = "1"
  }
}

# ----------------------------------------------------------------------------
# Alarma 1: pico de errores en la app (5+ en 5 min).
# ----------------------------------------------------------------------------
resource "aws_cloudwatch_metric_alarm" "errors" {
  alarm_name          = "app-error-spike"
  comparison_operator = "GreaterThanOrEqualToThreshold"
  evaluation_periods  = 1
  metric_name         = "AppErrors"
  namespace           = "MLTraductores"
  period              = 300 # 5 min en segundos
  statistic           = "Sum"
  threshold           = 5
  alarm_description   = "5+ errores en 5 min en la app"
  alarm_actions       = [aws_sns_topic.alerts.arn]

  # Si no hay logs (app caída por completo), considerar OK.
  # Sin esto la alarma dispara cada vez que la EC2 se reinicia.
  treat_missing_data = "notBreaching"
}

# ----------------------------------------------------------------------------
# Alarma 2: CPU sostenida alta (3 períodos de 5 min con CPU > 80%).
# ----------------------------------------------------------------------------
resource "aws_cloudwatch_metric_alarm" "cpu_high" {
  alarm_name          = "ec2-cpu-high"
  comparison_operator = "GreaterThanThreshold"
  evaluation_periods  = 3
  metric_name         = "CPUUtilization"
  namespace           = "AWS/EC2"
  period              = 300
  statistic           = "Average"
  threshold           = 80
  dimensions          = { InstanceId = aws_instance.app.id }
  alarm_actions       = [aws_sns_topic.alerts.arn]
}

# ----------------------------------------------------------------------------
# Alarma 3: disco casi lleno.
# Métrica `disk_used_percent` la reporta el CloudWatch Agent (no es nativa).
# Critico: si Postgres llena su disco, todo se cae.
# ----------------------------------------------------------------------------
resource "aws_cloudwatch_metric_alarm" "disk_high" {
  alarm_name          = "ec2-disk-high"
  comparison_operator = "GreaterThanThreshold"
  evaluation_periods  = 1
  metric_name         = "disk_used_percent"
  namespace           = "CWAgent"
  period              = 300
  statistic           = "Average"
  threshold           = 80
  alarm_actions       = [aws_sns_topic.alerts.arn]
  treat_missing_data  = "notBreaching"
}

# ----------------------------------------------------------------------------
# Alarma 4: status check failed (la EC2 no responde).
# Junto con auto_recovery en ec2.tf, AWS reinicia la EC2 automáticamente.
# ----------------------------------------------------------------------------
resource "aws_cloudwatch_metric_alarm" "instance_status" {
  alarm_name          = "ec2-status-failed"
  comparison_operator = "GreaterThanOrEqualToThreshold"
  evaluation_periods  = 2
  metric_name         = "StatusCheckFailed"
  namespace           = "AWS/EC2"
  period              = 60
  statistic           = "Maximum"
  threshold           = 1
  dimensions          = { InstanceId = aws_instance.app.id }
  alarm_actions       = [aws_sns_topic.alerts.arn]
}

# ----------------------------------------------------------------------------
# Alarma 5: presupuesto AWS.
# Si el gasto del mes supera 80% de $5, alerta.
# Protección contra explosiones inesperadas (cripto-jacking, log explosion).
# ----------------------------------------------------------------------------
resource "aws_budgets_budget" "monthly" {
  name         = "ml-traductores-monthly"
  budget_type  = "COST"
  limit_amount = "5"
  limit_unit   = "USD"
  time_unit    = "MONTHLY"

  notification {
    comparison_operator        = "GREATER_THAN"
    threshold                  = 80
    threshold_type             = "PERCENTAGE"
    notification_type          = "ACTUAL"
    subscriber_email_addresses = var.alert_emails
  }
}

# ----------------------------------------------------------------------------
# Dashboard de CloudWatch. Vista única en consola para revisar el sistema.
# ----------------------------------------------------------------------------
resource "aws_cloudwatch_dashboard" "main" {
  dashboard_name = "ml-traductores-overview"

  dashboard_body = jsonencode({
    widgets = [
      {
        type   = "metric"
        x      = 0
        y      = 0
        width  = 12
        height = 6
        properties = {
          metrics = [["AWS/EC2", "CPUUtilization", "InstanceId", aws_instance.app.id]]
          period  = 300
          stat    = "Average"
          region  = var.region
          title   = "CPU EC2"
        }
      },
      {
        type   = "metric"
        x      = 12
        y      = 0
        width  = 12
        height = 6
        properties = {
          metrics = [["MLTraductores", "AppErrors"]]
          period  = 300
          stat    = "Sum"
          region  = var.region
          title   = "Errores app (suma 5min)"
        }
      },
      {
        type   = "metric"
        x      = 0
        y      = 6
        width  = 12
        height = 6
        properties = {
          metrics = [
            ["CWAgent", "disk_used_percent", "path", "/"],
            [".", ".", ".", "/mnt/pgdata"]
          ]
          period = 300
          stat   = "Average"
          region = var.region
          title  = "Uso disco (root y Postgres)"
        }
      },
      {
        type   = "metric"
        x      = 12
        y      = 6
        width  = 12
        height = 6
        properties = {
          metrics = [["CWAgent", "mem_used_percent"]]
          period  = 300
          stat    = "Average"
          region  = var.region
          title   = "Memoria"
        }
      }
    ]
  })
}
