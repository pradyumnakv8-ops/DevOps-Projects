# Amazon RDS MySQL — Exact Configuration and Explanation

This document explains the RDS configuration currently committed to:

```text
DevOps-Project-01/infrastructure-v2/rds.tf
```

The following resources form the data tier:

```text
Private application subnets
  -> DB subnet group
  -> Database security group
  -> RDS MySQL instance
  -> Synchronous standby for Multi-AZ deployments
```

## 1. Purpose of RDS

Amazon RDS provides a managed MySQL database instead of requiring MySQL to run on a manually managed EC2 instance.

AWS manages database engine installation, database storage infrastructure, automated backups, point-in-time recovery, software patching, instance restart behavior, and Multi-AZ standby operations.

The infrastructure still requires database schema migrations, application credentials, database user management, query tuning, backup testing, monitoring, and application-level connection handling.

## 2. Complete RDS configuration

```hcl
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
```

## 3. DB subnet group

```hcl
resource "aws_db_subnet_group" "database" {
```

A DB subnet group tells RDS which private subnets and Availability Zones it may use.

### Name

```hcl
name = "${var.project}-${var.environment}-db-subnets"
```

The resource name becomes environment-specific, for example:

```text
java-login-app-dev-db-subnets
```

### Subnet IDs

```hcl
subnet_ids = aws_subnet.private[*].id
```

The splat expression supplies all private subnet IDs. The VPC configuration provides private subnets in separate Availability Zones:

```text
10.20.11.0/24
10.20.12.0/24
```

RDS can place the database primary and standby in these private subnets.

A subnet group does not make RDS publicly accessible. Public accessibility is controlled separately by `publicly_accessible = false` on the RDS instance.

### Subnet-group tags

```hcl
Name        = "${var.project}-${var.environment}-db-subnets"
Environment = var.environment
Tier        = "data"
```

These tags identify the resource's purpose and environment.

## 4. Database security group

```hcl
resource "aws_security_group" "database" {
```

The database security group controls inbound network access to RDS.

### Name and description

```hcl
name        = "${var.project}-${var.environment}-database-sg"
description = "Allow MySQL access only from application instances"
```

The name identifies the security group as the data-tier database access control.

### VPC

```hcl
vpc_id = aws_vpc.main.id
```

The security group belongs to the same VPC as the private subnets and application instances.

### MySQL ingress rule

```hcl
ingress {
  description     = "MySQL from the application tier"
  from_port       = 3306
  to_port         = 3306
  protocol        = "tcp"
  security_groups = [aws_security_group.application.id]
}
```

This rule allows TCP port `3306` when traffic comes from the application security group.

It therefore allows:

- Application EC2 instances
- Instances that use `aws_security_group.application`

It does not allow:

- Public internet access
- Direct access from the ALB security group
- Access from arbitrary VPC security groups
- SSH or arbitrary database ports

The database security group does not use a CIDR block, so source access is tied to the application security group rather than a broad IP range.

### Database security-group tags

The tags identify the security group as an environment-specific data-tier resource.

## 5. RDS database resource

```hcl
resource "aws_db_instance" "mysql" {
```

This resource creates an RDS database instance and configures its engine, size, networking, storage, backups, maintenance, logs, and deletion behavior.

### Identifier

```hcl
identifier = "${var.project}-${var.environment}-mysql"
```

For example:

```text
java-login-app-dev-mysql
```

The identifier is the RDS instance name. It does not replace the endpoint, database name, or master username.

The identifier should be unique across the AWS account and region where RDS instances are managed.

## 6. Database engine

```hcl
engine = "mysql"
```

RDS creates a MySQL database. AWS manages the database engine process and infrastructure.

This configuration does not install MySQL on an EC2 instance. It also does not create application tables. RDS creates the initial database name and master user; application schema migrations must create and update tables.

## 7. DB instance class

```hcl
instance_class = var.db_instance_class
```

The default is:

```text
db.t3.medium
```

The instance class determines database CPU and memory resources.

A larger class may provide:

- More CPU
- More memory
- Better network throughput
- Better database concurrency capacity

The instance class is not storage and does not by itself determine IOPS or read scalability.

Use database workload testing to determine whether `db.t3.medium` is sufficient.

## 8. Initial database name

```hcl
db_name = var.db_name
```

The default is:

```text
javaapp
```

RDS creates this MySQL database when the instance is first initialized.

This is different from:

- `identifier`: RDS instance resource name
- `username`: MySQL master username
- JDBC endpoint: DNS address for the database instance

Tables such as `users` must be created through SQL migrations or database initialization scripts.

## 9. Master username

```hcl
username = var.db_master_username
```

The default master username is:

```text
dbadmin
```

The master username is the database administrator identity created by RDS.

This account should not normally be used by application runtime code. Create a least-privilege application user for application connections.

The username is safe to store in Terraform configuration, but the password is not manually supplied in this configuration.

## 10. RDS-managed master password

```hcl
manage_master_user_password = true
```

RDS creates and manages the master password and stores it in AWS Secrets Manager.

This configuration avoids:

- Hard-coding a password in Terraform.
- Passing a password through a Terraform variable.
- Saving a manually created database password in application source code.

RDS exposes secret information through:

```hcl
aws_db_instance.mysql.master_user_secret[0].secret_arn
```

The secret ARN can be retrieved by applications or administrators with appropriate IAM permissions.

The application should retrieve the secret using AWS SDK/Secrets Manager integration or a configured secret-injection mechanism rather than reading the credential from Terraform source.

## 11. Initial storage

```hcl
allocated_storage = var.db_allocated_storage
```

The default is:

```text
20 GiB
```

This is the initial storage size allocated to RDS.

Database storage is separate from EC2 instance memory and CPU. RDS storage autoscaling can increase storage when usage thresholds are reached.

## 12. Maximum storage

```hcl
max_allocated_storage = var.db_max_allocated_storage
```

The default is:

```text
100 GiB
```

RDS storage autoscaling is bounded by this value.

`db_allocated_storage` must be lower than `db_max_allocated_storage`. Storage autoscaling does not guarantee unlimited growth and should be selected based on application growth estimates and cost limits.

## 13. GP3 storage

```hcl
storage_type = "gp3"
```

GP3 is general-purpose SSD storage.

It provides a cost-efficient balance of capacity and performance and can support workload requirements without the more expensive I/O characteristics of provisioned-IOPS storage.

Database performance should be tested. GP3 throughput and IOPS should be tuned if the database has a storage-bound workload.

## 14. Storage encryption

```hcl
storage_encrypted = true
```

RDS storage encryption protects database storage at rest.

It applies to:

- Database storage
- Automated backups
- Read replicas created from the encrypted database
- Snapshots associated with the encrypted database

Encryption at rest is a major baseline requirement, but application traffic and credentials still need separate security controls.

## 15. DB subnet and security group attachment

```hcl
db_subnet_group_name   = aws_db_subnet_group.database.name
vpc_security_group_ids = [aws_security_group.database.id]
```

The DB subnet group determines where RDS may place the database. The database security group determines which network sources may connect.

Together, they provide:

- Private VPC placement
- Availability-Zone placement options
- Restricted MySQL access

## 16. Public accessibility

```hcl
publicly_accessible = false
```

The RDS instance does not receive a public endpoint or public IP address.

Database access must originate from a permitted network location inside the VPC or through a controlled private network connection.

Do not enable public accessibility merely for testing. Use VPN, private bastion access, SSM, or a controlled administration path if database administration is required.

## 17. Multi-AZ

```hcl
multi_az = var.db_multi_az
```

The default is:

```text
true
```

A Multi-AZ RDS deployment has:

- A primary database instance
- A synchronous standby in another Availability Zone
- Automatic failover management

The application uses the RDS DNS endpoint. RDS updates endpoint routing during failover.

Multi-AZ improves availability for infrastructure failures and planned maintenance. It is not a read scaling mechanism.

During failover:

- Existing connections may be dropped.
- Applications should retry transient connection failures.
- JDBC connection pools may need to discard stale connections.
- The DNS endpoint should remain the application connection target.

## 18. Automated backup retention

```hcl
backup_retention_period = var.db_backup_retention_days
```

The default is:

```text
7 days
```

RDS retains automated backups for this period and supports point-in-time recovery for the retained backup period.

Backup retention affects:

- Recovery capability
- Storage cost
- Compliance requirements

A configured retention period does not prove that restores work. Periodic restore tests are recommended.

## 19. Backup window

```hcl
backup_window = var.db_backup_window
```

The default is:

```text
03:00-04:00 UTC
```

This is RDS's preferred time range for backup operations. RDS may adjust timing within operational constraints.

The backup window should avoid known peak application periods when possible.

## 20. Maintenance window

```hcl
maintenance_window = var.db_maintenance_window
```

The default is:

```text
sun:04:00-sun:05:00 UTC
```

This is the preferred weekly window for maintenance actions such as:

- OS maintenance
- Engine patching
- Minor updates
- Reconfiguration operations

A maintenance event can affect availability and may restart the database, depending on the operation and Multi-AZ configuration.

## 21. Copy tags to snapshots

```hcl
copy_tags_to_snapshot = true
```

RDS copies database tags to snapshots.

This helps identify:

- Environment
- Data tier
- Owner or project
- Cost-allocation context

Without this setting, snapshots would not inherit useful resource tags.

## 22. CloudWatch log exports

```hcl
enabled_cloudwatch_logs_exports = ["error", "general", "slowquery"]
```

This sends selected MySQL logs to CloudWatch Logs.

### Error log

Captures database startup, shutdown, and error events.

### General log

Captures general database activity. It can be verbose and may contain sensitive application or SQL data.

### Slow-query log

Captures SQL queries that MySQL considers slow under the configured threshold.

Useful operational uses include:

- Finding failing or expensive queries
- Investigating latency
- Identifying missing indexes
- Detecting unexpected query patterns

CloudWatch log retention and cost are not defined in this RDS file, so add retention policies if the logs should not remain indefinitely.

## 23. Minor-version upgrades

```hcl
auto_minor_version_upgrade = true
```

RDS can automatically apply eligible minor MySQL engine updates during the maintenance window.

Minor updates normally remain within the same major database engine line, but they can still trigger maintenance behavior or restart processes.

Test major- and minor-engine behavior before production deployment. This setting does not manage major-version upgrades.

## 24. Immediate application of changes

```hcl
apply_immediately = false
```

Terraform changes that require RDS modification wait until RDS maintenance or its next appropriate scheduled update behavior instead of being forced immediately.

This reduces surprise outages but means a plan/apply may not immediately modify every RDS setting.

Set this to `true` only when immediate scheduling has been reviewed.

## 25. Deletion protection

```hcl
deletion_protection = var.db_deletion_protection
```

The default is:

```text
true
```

Deletion protection prevents accidental RDS database deletion through Terraform or AWS APIs.

Before an intentional destroy:

1. Disable deletion protection.
2. Review backup and final-snapshot behavior.
3. Review restore dependencies.
4. Apply the Terraform change that disables protection.
5. Then perform the approved deletion.

## 26. Final snapshots

```hcl
skip_final_snapshot = var.db_skip_final_snapshot
final_snapshot_identifier = var.db_skip_final_snapshot ? null : "${var.project}-${var.environment}-mysql-final"
```

The default is:

```text
skip_final_snapshot = false
```

Therefore, RDS should create a final snapshot unless intentionally skipped.

The final snapshot identifier is:

```text
java-login-app-dev-mysql-final
```

For production, retain the final snapshot and deletion protection. For disposable development databases, `skip_final_snapshot = true` may reduce cost and cleanup friction, but it removes an extra recovery point.

## 27. RDS tags

```hcl
tags = {
  Name        = "${var.project}-${var.environment}-mysql"
  Environment = var.environment
  Tier        = "data"
}
```

These tags help with:

- AWS resource identification
- Environment filtering
- Cost allocation
- Inventory
- Operational ownership

The tags are also copied to snapshots because `copy_tags_to_snapshot = true`.

## 28. RDS input variables

| Variable | Default | Meaning |
|---|---:|---|
| `db_name` | `javaapp` | Initial database name |
| `db_master_username` | `dbadmin` | Master database username |
| `db_instance_class` | `db.t3.medium` | RDS database capacity |
| `db_allocated_storage` | `20 GiB` | Initial storage |
| `db_max_allocated_storage` | `100 GiB` | Storage autoscaling upper bound |
| `db_multi_az` | `true` | Enable primary/standby Multi-AZ topology |
| `db_backup_retention_days` | `7` | Automated backup retention |
| `db_backup_window` | `03:00-04:00` UTC | Preferred backup period |
| `db_maintenance_window` | `sun:04:00-sun:05:00` UTC | Preferred maintenance period |
| `db_deletion_protection` | `true` | Prevent accidental deletion |
| `db_skip_final_snapshot` | `false` | Final snapshot behavior |

## 29. RDS outputs

The RDS setup should provide:

- Database endpoint DNS name
- Database port
- Initial database name
- RDS master credential secret ARN
- Database security-group ID

Example connection configuration:

```text
Host: <database endpoint>
Port: 3306
Database: javaapp
Username: application user or dbadmin
Password: retrieved from Secrets Manager
```

The application should use the database endpoint, not an EC2 public IP or hard-coded DNS address.

## 30. Java connection behavior

A typical JDBC URL is:

```text
jdbc:mysql://<database_endpoint>:3306/javaapp
```

The Java application should:

- Use a connection pool.
- Retrieve credentials securely.
- Use a dedicated application database user.
- Retry transient failover connection failures.
- Close unused connections and statements.
- Test TLS/SSL behavior required by the MySQL driver.
- Avoid master credentials for normal application traffic.

The RDS secret does not by itself configure an IAM role or Java secret retrieval. Those application and EC2 IAM resources must be added separately.

## 31. Complete traffic flow

```text
Client
  -> public ALB
  -> application ASG instance
  -> application security group
  -> TCP 3306
  -> database security group
  -> private RDS MySQL primary

RDS Multi-AZ standby
  <- receives synchronous updates in another AZ
```

The data tier is isolated from direct internet traffic.

## 32. Data initialization

RDS creates the `javaapp` database, but it does not create application tables from this configuration.

The project needs an initialization or migration process for SQL such as:

```sql
USE javaapp;

CREATE TABLE users (
  id INT AUTO_INCREMENT PRIMARY KEY,
  username VARCHAR(50) NOT NULL UNIQUE,
  password VARCHAR(255) NOT NULL,
  email VARCHAR(100) NOT NULL UNIQUE,
  created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP
);

CREATE INDEX idx_username ON users(username);
CREATE INDEX idx_email ON users(email);
```

Use migrations or approved release scripts so schema changes are tracked and repeatable.

## 33. Security recommendations

The RDS configuration should be complemented by:

- A dedicated application database user with minimum privileges
- Secrets Manager credential retrieval by application instances
- An EC2/ASG instance IAM role with access only to required secrets
- TLS for database connections where supported
- Strong database parameter and password policies
- Restricted administration access
- CloudWatch alarms for CPU, memory, storage, connections, replication, and I/O
- Log review and log retention
- Regular restore tests
- Backup and retention review

Do not open RDS port `3306` to `0.0.0.0/0`.

## 34. Current configuration limitations

The RDS file does not include:

- EC2 IAM role and policy for retrieving the database secret
- Java secret integration
- Database schema migrations
- A custom parameter group
- Read replicas
- Performance Insights configuration
- Enhanced monitoring role and interval
- CloudWatch alarms
- CloudWatch log retention
- A database migration or initialization resource
- Custom database maintenance or backup validation automation

## 35. Important validation items

Before applying RDS:

- Confirm `db_allocated_storage <= db_max_allocated_storage`.
- Confirm `db.t3.medium` meets expected database workloads.
- Decide if the initial environment should use Multi-AZ.
- Verify backup and maintenance windows against application usage.
- Confirm whether `db_skip_final_snapshot` should be false for production.
- Confirm deletion protection is suitable for production and development.
- Test application credential retrieval from Secrets Manager.
- Test network access from an application instance on port `3306`.
- Plan database schema migrations.
- Configure logging and monitoring.
- Estimate storage and backup costs.
- Test a restore in a non-production environment.

Run Terraform validation:

```bash
cd DevOps-Project-01/infrastructure-v2
terraform fmt -check -recursive
terraform validate
terraform plan
```

Review the RDS plan carefully. RDS changes can trigger instance modifications, storage changes, version updates, restarts, or failover behavior.
