# ============================================================================
# EC2 instance + EBS data volume + IAM role + Elastic IP.
# El corazón de la infra.
# ============================================================================

# ----------------------------------------------------------------------------
# AMI: Amazon Linux 2023 ARM (para t4g/Graviton).
# `data` (no `resource`) porque solo la consultamos, no la creamos.
# ----------------------------------------------------------------------------
data "aws_ami" "al2023_arm" {
  most_recent = true
  owners      = ["amazon"]
  filter {
    name   = "name"
    values = ["al2023-ami-2023.*-arm64"]
  }
}

# ----------------------------------------------------------------------------
# Rol IAM que la EC2 asume al arrancar.
# Sin esto la EC2 no puede pullear ECR, escribir a S3, mandar logs.
# AWS rota credenciales automáticamente — nunca hay claves en disco.
# ----------------------------------------------------------------------------
resource "aws_iam_role" "ec2" {
  name = "ml-traductores-ec2"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Action    = "sts:AssumeRole"
      Effect    = "Allow"
      Principal = { Service = "ec2.amazonaws.com" }
    }]
  })
}

# Permite que SSM administre la instancia: Session Manager, Run Command, Patch.
resource "aws_iam_role_policy_attachment" "ssm" {
  role       = aws_iam_role.ec2.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore"
}

# Permite que el CloudWatch Agent envíe métricas y logs.
resource "aws_iam_role_policy_attachment" "cw_agent" {
  role       = aws_iam_role.ec2.name
  policy_arn = "arn:aws:iam::aws:policy/CloudWatchAgentServerPolicy"
}

# Política inline custom: permisos específicos a S3 (solo nuestro bucket) y ECR.
resource "aws_iam_role_policy" "app" {
  role = aws_iam_role.ec2.name
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      # S3: subir/leer/listar SOLO el bucket de backups.
      {
        Effect = "Allow"
        Action = ["s3:PutObject", "s3:GetObject", "s3:ListBucket", "s3:DeleteObject"]
        Resource = [
          aws_s3_bucket.backups.arn,
          "${aws_s3_bucket.backups.arn}/*"
        ]
      },
      # ECR: pullear imágenes (necesario para `docker pull`).
      {
        Effect = "Allow"
        Action = [
          "ecr:GetAuthorizationToken",
          "ecr:BatchGetImage",
          "ecr:GetDownloadUrlForLayer",
          "ecr:BatchCheckLayerAvailability"
        ]
        Resource = "*"
      }
    ]
  })
}

# Wrapper que conecta el rol IAM con la instancia EC2.
resource "aws_iam_instance_profile" "ec2" {
  name = "ml-traductores-ec2"
  role = aws_iam_role.ec2.name
}

# ----------------------------------------------------------------------------
# La instancia EC2 propiamente dicha.
# ----------------------------------------------------------------------------
resource "aws_instance" "app" {
  ami                    = data.aws_ami.al2023_arm.id
  instance_type          = var.instance_type
  subnet_id              = data.aws_subnets.default.ids[0]
  vpc_security_group_ids = [aws_security_group.app.id]
  key_name               = var.ssh_key_name
  iam_instance_profile   = aws_iam_instance_profile.ec2.name

  # Protección contra terminación accidental por consola/API.
  # Para terminar a propósito: poner false, apply, luego terminar.
  disable_api_termination = true

  # Disco raíz: SO + docker + binarios. Postgres data está en EBS aparte.
  root_block_device {
    volume_size           = 8
    volume_type           = "gp3"
    encrypted             = true
    delete_on_termination = true
  }

  # Bootstrap script. Corre UNA SOLA VEZ al primer boot.
  # Si lo modificas y quieres reaplicar, hay que destruir y recrear la EC2.
  user_data = templatefile("${path.module}/user_data.sh", {
    ecr_registry = aws_ecr_repository.app.repository_url
    s3_backups   = aws_s3_bucket.backups.bucket
    region       = var.region
    domain       = var.domain_name
    github_repo  = var.github_repo
  })

  # `user_data_replace_on_change = false` es el default — cambios al script
  # NO recrean la EC2. Para reaplicar: SSM session y correr manualmente.

  # Auto-recovery: si AWS detecta fallo de hardware, reinicia en otro host.
  # NO incluye reinicio si la app crashea (eso lo maneja docker restart).
  maintenance_options {
    auto_recovery = "default"
  }

  tags = { Name = "ml-traductores-app" }

  # Si la AMI cambia (nueva versión menor de AL2023), NO queremos recrear
  # la EC2 (perderíamos el estado del root). Para upgrade del SO: dnf update.
  lifecycle {
    ignore_changes = [ami, user_data]
  }
}

# ----------------------------------------------------------------------------
# Disco EBS separado para Postgres data.
# Vive INDEPENDIENTE de la EC2. Si destruimos la EC2 sin querer, el disco
# sobrevive y se re-attachea a una nueva instancia con la DB intacta.
# ----------------------------------------------------------------------------
resource "aws_ebs_volume" "data" {
  availability_zone = aws_instance.app.availability_zone
  size              = 10
  type              = "gp3"
  encrypted         = true
  tags              = { Name = "ml-traductores-pgdata" }

  # Si Terraform intenta destruirlo, falla. Capa extra de protección.
  lifecycle {
    prevent_destroy = true
  }
}

# Conecta el volumen EBS a la instancia.
# /dev/sdf en AWS = /dev/nvme1n1 en Linux (NVMe naming).
resource "aws_volume_attachment" "data" {
  device_name = "/dev/sdf"
  volume_id   = aws_ebs_volume.data.id
  instance_id = aws_instance.app.id
}

# ----------------------------------------------------------------------------
# IP elástica (IP pública estática).
# Sin esto, la IP cambia cada vez que se detiene la EC2 y tendríamos que
# actualizar Cloudflare DNS. Gratis si está asociada a una instancia activa.
# ----------------------------------------------------------------------------
resource "aws_eip" "app" {
  instance = aws_instance.app.id
  domain   = "vpc"
  tags     = { Name = "ml-traductores-eip" }
}
