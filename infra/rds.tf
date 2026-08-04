resource "aws_db_subnet_group" "this" {
  name       = "togglemaster-db"
  subnet_ids = module.vpc.private_subnets
}

resource "aws_security_group" "this" {
  name        = "togglemaster-rds"
  description = "Libera PostgreSQL (5432) apenas a partir dos nos do EKS"
  vpc_id      = module.vpc.vpc_id
}

resource "aws_vpc_security_group_ingress_rule" "this" {
  security_group_id            = aws_security_group.this.id
  description                  = "PostgreSQL a partir dos nos do EKS"
  from_port                    = 5432
  to_port                      = 5432
  ip_protocol                  = "tcp"
  referenced_security_group_id = module.eks.node_security_group_id
}

resource "aws_kms_key" "rds" {
  description         = "Chave de criptografia dos bancos RDS do ToggleMaster"
  enable_key_rotation = true
}

resource "aws_kms_alias" "rds" {
  name          = "alias/togglemaster-rds"
  target_key_id = aws_kms_key.rds.key_id
}

locals {
  databases = {
    auth      = { db_name = "auth_db", username = "auth_user" }
    flag      = { db_name = "flag_db", username = "flag_user" }
    targeting = { db_name = "targeting_db", username = "targeting_user" }
  }
}

resource "aws_db_instance" "this" {
  for_each = local.databases

  identifier = "togglemaster-${each.key}"
  db_name    = each.value.db_name
  username   = each.value.username

  engine            = "postgres"
  engine_version    = "16"
  instance_class    = "db.t3.micro"
  allocated_storage = 20
  storage_type      = "gp3"

  db_subnet_group_name   = aws_db_subnet_group.this.name
  vpc_security_group_ids = [aws_security_group.this.id]
  publicly_accessible    = false
  multi_az               = false

  storage_encrypted                   = true
  kms_key_id                          = aws_kms_key.rds.arn
  manage_master_user_password         = true
  iam_database_authentication_enabled = true

  skip_final_snapshot = true
}
