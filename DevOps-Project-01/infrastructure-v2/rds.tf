# RDS data tier
# MySQL is private in the VPC's private subnets. The database security group
# accepts MySQL connections only from the application instance security group.

resource "aws_db_subnet_group" "database" {
  name        = "${var.project}-${var.environment}-db-subnets"
  description = "Private subnets for the ${var.project} ${var.environment} MySQL database"
  subnet_ids  = aws_subnet.private[*].id

  tags = {
    Name        = "${var.project}-${var.environment}-db-subnets"
    Environment = var.environment
    Tier        = "data"
  }
}

resource "aws_security_group" "database" {
  name        = "${var.project}-${var.environment}-database-sg"
  description = "Allow MySQL access only from application instances"
  vpc_id      = aws_vpc.main.id

  ingress {
    description     = "MySQL from the application tier"
    from_port       = 3306
    to_port         = 3306
    protocol        = "tcp"
    security_groups = [aws_security_group.application.id]
  }

  tags = {
    Name        = "${var.project}-${var.environment}-database-sg"
    Environment = var.environment
    Tier        = "data"
  }
}

resource "aws_db_instance" "mysql" {
  identifier = "${var.project}-${var.environment}-mysql"

  engine         = "mysql"
  instance_class = var.db_instance_class
  db_name        = var.db_name
  username       = var.db_master_username

  # Let RDS create and manage the master password in Secrets Manager.
  # Do not put database passwords in Terraform source or tfvars files.
  manage_master_user_password = true

  allocated_storage     = var.db_allocated_storage
  max_allocated_storage = var.db_max_allocated_storage
  storage_type          = "gp3"
  storage_encrypted     = true

  db_subnet_group_name   = aws_db_subnet_group.database.name
  vpc_security_group_ids = [aws_security_group.database.id]
  publicly_accessible    = false
  multi_az               = var.db_multi_az

  backup_retention_period = var.db_backup_retention_days
  backup_window           = var.db_backup_window
  maintenance_window      = var.db_maintenance_window
  copy_tags_to_snapshot   = true

  enabled_cloudwatch_logs_exports = ["error", "general", "slowquery"]
  auto_minor_version_upgrade      = true
  apply_immediately               = false

  deletion_protection = var.db_deletion_protection
  skip_final_snapshot = var.db_skip_final_snapshot
  final_snapshot_identifier = var.db_skip_final_snapshot ? null : "${var.project}-${var.environment}-mysql-final"

  tags = {
    Name        = "${var.project}-${var.environment}-mysql"
    Environment = var.environment
    Tier        = "data"
  }
}
