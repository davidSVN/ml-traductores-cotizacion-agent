#!/bin/bash
# ============================================================================
# Bootstrap de la EC2 ml-traductores-app.
# Corre AUTOMÁTICAMENTE al primer boot. Output va a /var/log/cloud-init-output.log
# ============================================================================
set -euxo pipefail

# ----------------------------------------------------------------------------
# 1. Actualizar el SO
# ----------------------------------------------------------------------------
dnf update -y

# ----------------------------------------------------------------------------
# 2. Instalar paquetes base
# ----------------------------------------------------------------------------
dnf install -y docker amazon-cloudwatch-agent

systemctl enable --now docker
usermod -aG docker ec2-user

# ----------------------------------------------------------------------------
# 3. Instalar docker compose v2 (plugin)
# ----------------------------------------------------------------------------
DOCKER_CONFIG=/usr/local/lib/docker
mkdir -p $DOCKER_CONFIG/cli-plugins
curl -SL https://github.com/docker/compose/releases/latest/download/docker-compose-linux-aarch64 \
  -o $DOCKER_CONFIG/cli-plugins/docker-compose
chmod +x $DOCKER_CONFIG/cli-plugins/docker-compose

# ----------------------------------------------------------------------------
# 4. Esperar y formatear el EBS de datos
# ----------------------------------------------------------------------------
DEVICE=/dev/nvme1n1
echo "Esperando dispositivo $DEVICE..."
for i in {1..60}; do
  if [ -e $DEVICE ]; then break; fi
  sleep 2
done

# Formatear con XFS si NO tiene filesystem todavía (primera vez).
if ! blkid $DEVICE; then
  echo "Formateando $DEVICE con XFS"
  mkfs.xfs $DEVICE
fi

# Crear punto de montaje y agregar a fstab
mkdir -p /mnt/pgdata
echo "$DEVICE /mnt/pgdata xfs defaults,nofail 0 2" >> /etc/fstab
mount /mnt/pgdata

# uid 999 = postgres en la imagen oficial. Sin esto Postgres no puede escribir.
chown -R 999:999 /mnt/pgdata

# ----------------------------------------------------------------------------
# 5. Configurar el agente de CloudWatch
# ----------------------------------------------------------------------------
cat > /opt/aws/amazon-cloudwatch-agent/etc/amazon-cloudwatch-agent.json <<'EOF'
{
  "metrics": {
    "metrics_collected": {
      "disk": {
        "measurement": ["used_percent"],
        "resources": ["/", "/mnt/pgdata"],
        "drop_device": true
      },
      "mem": {
        "measurement": ["used_percent"]
      }
    }
  },
  "logs": {
    "logs_collected": {
      "files": {
        "collect_list": [
          {
            "file_path": "/var/log/backup.log",
            "log_group_name": "/ml-traductores/app",
            "log_stream_name": "{instance_id}/backup"
          },
          {
            "file_path": "/var/log/restore_test.log",
            "log_group_name": "/ml-traductores/app",
            "log_stream_name": "{instance_id}/restore_test"
          }
        ]
      }
    }
  }
}
EOF
systemctl enable --now amazon-cloudwatch-agent

# ----------------------------------------------------------------------------
# 6. Crear directorio de la aplicación y bajar archivos del repo
# ----------------------------------------------------------------------------
mkdir -p /opt/ml-traductores
cd /opt/ml-traductores

# Descargar archivos de operación desde el repo (rama master).
# Si el repo es privado, esto fallará y los archivos se subirán manualmente vía SSM.
REPO_RAW="https://raw.githubusercontent.com/${github_repo}/master"
curl -sSLf $REPO_RAW/docker-compose.prod.yml -o docker-compose.prod.yml || echo "WARN: docker-compose.prod.yml no descargado (repo privado?)"
curl -sSLf $REPO_RAW/Caddyfile -o Caddyfile || echo "WARN: Caddyfile no descargado"

mkdir -p scripts
for s in backup.sh restore.sh test_restore.sh deploy.sh; do
  curl -sSLf $REPO_RAW/scripts/$s -o scripts/$s || echo "WARN: scripts/$s no descargado"
  chmod +x scripts/$s 2>/dev/null || true
done

# ----------------------------------------------------------------------------
# 7. Variables de infra (no secretos). El .env real con secrets se crea
#    manualmente vía SSM después del primer boot.
# ----------------------------------------------------------------------------
cat > /opt/ml-traductores/.env.infra <<EOF
ECR_REGISTRY=${ecr_registry}
S3_BACKUPS_BUCKET=${s3_backups}
AWS_REGION=${region}
DOMAIN_NAME=${domain}
EOF
chmod 644 /opt/ml-traductores/.env.infra

# ----------------------------------------------------------------------------
# 8. Crons de backup y test de restore
# ----------------------------------------------------------------------------
cat > /etc/cron.d/ml-traductores <<'EOF'
# m h dom mon dow user command
0 */6 * * * root /opt/ml-traductores/scripts/backup.sh >> /var/log/backup.log 2>&1
0 5 * * 0  root /opt/ml-traductores/scripts/test_restore.sh >> /var/log/restore_test.log 2>&1
EOF

# ----------------------------------------------------------------------------
# 9. Mensaje final
# ----------------------------------------------------------------------------
echo "============================================"
echo "Bootstrap completo. Pasos siguientes (manuales):"
echo "  1. Crear /opt/ml-traductores/.env via SSM con secrets reales"
echo "  2. Configurar GitHub Secrets (AWS_DEPLOY_ROLE_ARN, EC2_INSTANCE_ID)"
echo "  3. Apuntar Cloudflare DNS al IP elastico"
echo "  4. Mergear PR a master para disparar primer deploy"
echo "============================================"
