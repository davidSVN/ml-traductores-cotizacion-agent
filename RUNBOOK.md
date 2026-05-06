# RUNBOOK — Operaciones AWS

Cheat sheet para operar la infra en AWS. Para contexto completo ver `RFC_AWS_MIGRATION.md`.

## Acceso a la EC2

Usamos AWS SSM Session Manager (no SSH).

```bash
# Lista instancias EC2 administradas por SSM
aws ssm describe-instance-information --profile ml-traductores

# Abrir sesión interactiva
aws ssm start-session --target <instance-id> --profile ml-traductores

# Una vez dentro, asumir root
sudo bash
cd /opt/ml-traductores
```

SSH solo de emergencia (puerto 22 abierto solo desde la IP del admin):
```bash
ssh -i ~/.ssh/ml-traductores-admin.pem ec2-user@<elastic-ip>
```

## Logs

### Ver logs en vivo de la app (desde la EC2)
```bash
docker compose -f /opt/ml-traductores/docker-compose.prod.yml logs -f app
docker compose -f /opt/ml-traductores/docker-compose.prod.yml logs -f postgres
docker compose -f /opt/ml-traductores/docker-compose.prod.yml logs -f caddy
```

### Buscar errores recientes en CloudWatch (desde tu máquina)
```bash
aws logs filter-log-events \
  --log-group-name /ml-traductores/app \
  --filter-pattern "ERROR" \
  --start-time $(date -u -v-1H +%s)000 \
  --profile ml-traductores
```

### Logs de backups
```bash
sudo tail -f /var/log/backup.log
sudo tail -f /var/log/restore_test.log
```

## Backups y restore

```bash
# Backup manual ya mismo
/opt/ml-traductores/scripts/backup.sh

# Listar últimos 20 backups en S3
aws s3 ls s3://ml-traductores-backups/postgres/ --recursive --profile ml-traductores | sort | tail -20

# Restaurar un backup específico (DESTRUCTIVO)
/opt/ml-traductores/scripts/restore.sh postgres/2026/05/05/060000.sql.gz

# Verificar último test de restore (manual)
/opt/ml-traductores/scripts/test_restore.sh
```

## Postgres

```bash
# Conectarse al psql
docker compose -f /opt/ml-traductores/docker-compose.prod.yml exec postgres \
  psql -U mluser ml_traductores

# Ver size de la DB
docker compose -f /opt/ml-traductores/docker-compose.prod.yml exec postgres \
  psql -U mluser ml_traductores -c \
  "SELECT pg_size_pretty(pg_database_size('ml_traductores'));"

# Tablas y filas
docker compose -f /opt/ml-traductores/docker-compose.prod.yml exec postgres \
  psql -U mluser ml_traductores -c \
  "SELECT relname, n_live_tup FROM pg_stat_user_tables ORDER BY n_live_tup DESC;"

# Borrar la DB temporal _old (después de un restore exitoso)
docker compose -f /opt/ml-traductores/docker-compose.prod.yml exec postgres \
  psql -U mluser -d postgres -c "DROP DATABASE ml_traductores_old;"
```

## Deploy manual (sin pasar por GitHub Actions)

```bash
# Pull la imagen `latest` y reinicia el container app
/opt/ml-traductores/scripts/deploy.sh
```

## Containers

```bash
# Estado
docker compose -f /opt/ml-traductores/docker-compose.prod.yml ps

# Reiniciar solo la app
docker compose -f /opt/ml-traductores/docker-compose.prod.yml restart app

# Reiniciar todo
docker compose -f /opt/ml-traductores/docker-compose.prod.yml restart

# Ver uso de recursos
docker stats --no-stream
```

## Sistema

```bash
df -h           # uso de disco
free -h         # uso de memoria
top -b -n 1     # procesos
uptime          # carga
```

## Patches del SO

```bash
sudo dnf update -y
sudo reboot   # si actualizó el kernel
```

## Edición del .env

```bash
sudo nano /opt/ml-traductores/.env
sudo chmod 600 /opt/ml-traductores/.env

# Aplicar cambios (reiniciar app)
docker compose -f /opt/ml-traductores/docker-compose.prod.yml restart app
```

## Recovery: la EC2 está caída

```
Caso A: instance "stopped" (no terminada)
  1. Consola EC2 → Start instance
  2. Espera ~1 min, verifica: curl https://api.tudominio.com/health
  3. Si responde, fin.

Caso B: instance terminada pero EBS de datos sobrevive
  1. cd infra/terraform && terraform apply
     (recrea EC2 y re-attachea EBS de datos)
  2. Espera ~3 min a user_data
  3. SSM session → restaurar /opt/ml-traductores/.env desde 1Password
  4. /opt/ml-traductores/scripts/deploy.sh
  5. Verifica /health

Caso C: EBS de datos también perdido
  1. Quitar prevent_destroy del aws_ebs_volume.data, terraform apply
  2. Igual que caso B + restore desde S3:
     aws s3 ls s3://ml-traductores-backups/postgres/ --recursive | tail
     /opt/ml-traductores/scripts/restore.sh <key>
  3. /opt/ml-traductores/scripts/deploy.sh

ETAs: 5 min (A), 20 min (B), 30 min (C)
```

## Cambiar la URL del webhook de WhatsApp

Si cambia el dominio o se migra a otra infra:

1. Meta Business Manager → tu app → WhatsApp → Configuration → Webhook
2. Edit endpoint → nueva URL: `https://nuevo-dominio.com/webhook/whatsapp`
3. Verify token: el del `.env` (`META_VERIFY_TOKEN`)
4. Verify and save

## Renovar la IP del SSH allowed CIDR

Si tu IP residencial cambia:

```bash
curl ifconfig.me   # obtener nueva IP
# Editar infra/terraform/terraform.tfvars con la nueva IP/32
cd infra/terraform && terraform apply
```
