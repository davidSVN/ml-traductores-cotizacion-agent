# Infra — Terraform

Infraestructura AWS de ML Traductores Agent (ver `RFC_AWS_MIGRATION.md` y `EXECUTION_PLAN.md` en la raíz para contexto).

## Pre-requisitos

- AWS CLI 2.x con perfil configurado: `aws configure --profile ml-traductores`
- Terraform >= 1.6
- Bucket S3 + tabla DynamoDB para state remoto creados manualmente:
  - `ml-traductores-tfstate` (S3, versionado, encrypted, region us-east-1)
  - `ml-traductores-tflock` (DynamoDB, partition key `LockID` String)
- Key pair EC2 creado en consola: `ml-traductores-admin`

## Setup inicial

```bash
cd infra/terraform

# 1. Crear archivo de variables con tus valores
cp terraform.tfvars.example terraform.tfvars
# Editar terraform.tfvars

# 2. Inicializar
terraform init

# 3. Ver plan
terraform plan

# 4. Aplicar
terraform apply
```

## Outputs importantes

Tras `apply`, anota estos outputs:

```bash
terraform output elastic_ip                # → Cloudflare DNS A record
terraform output ec2_instance_id           # → GitHub Secret EC2_INSTANCE_ID
terraform output ecr_repository_url        # → .env de la EC2
terraform output github_actions_role_arn   # → GitHub Secret AWS_DEPLOY_ROLE_ARN
terraform output backups_bucket            # → .env de la EC2
terraform output ssm_session_command       # → para abrir sesión sin SSH
```

## Operaciones comunes

```bash
# Ver state actual
terraform show

# Ver outputs sin re-aplicar
terraform output

# Aplicar solo cambios de un recurso específico
terraform apply -target=aws_instance.app

# Importar un recurso existente al state (si fue creado fuera de TF)
terraform import aws_s3_bucket.backups ml-traductores-backups

# Destruir TODO (cuidado: requiere quitar prevent_destroy de S3 y EBS data)
terraform destroy
```

## Cambios que requieren atención

| Cambio | Comportamiento de Terraform |
|---|---|
| `instance_type` | Reinicia la EC2 (downtime ~2 min) |
| `user_data.sh` | Ignorado por `lifecycle.ignore_changes` — aplicar manual vía SSM |
| `ssh_allowed_cidr` | Solo actualiza el security group, sin downtime |
| `alert_emails` | Manda emails de confirmación a los nuevos |
| `ami` | Ignorado por `lifecycle.ignore_changes` — para upgrade del SO usar `dnf update -y` en la EC2 |

## Recursos protegidos contra destroy

Estos recursos tienen `prevent_destroy = true`:
- `aws_ebs_volume.data` (datos de Postgres)
- `aws_s3_bucket.backups` (backups)

Para borrarlos a propósito: quitar el `lifecycle` block, `apply`, luego `destroy`.

La EC2 tiene `disable_api_termination = true`. Para terminarla a propósito: ponerlo en `false`, `apply`, luego terminar.

## Estructura

```
main.tf            Provider AWS + backend remoto del state
variables.tf       Inputs (ver terraform.tfvars.example)
outputs.tf         Valores que Terraform imprime al final
network.tf         VPC default + security group
ec2.tf             EC2 + EBS data + IAM role + Elastic IP
s3.tf              Bucket de backups (versionado + lifecycle)
ecr.tf             Repositorio Docker
monitoring.tf      Log group + alarmas + SNS + budget + dashboard
backup.tf          AWS Backup vault + plan diario para EBS
github_oidc.tf     Rol IAM que GitHub Actions asume vía OIDC
user_data.sh       Bootstrap de la EC2 (corre al primer boot)
```
