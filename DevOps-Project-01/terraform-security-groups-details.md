# Terraform Security Groups: Configuration and Complete Explanation

This document explains the security-group configuration used by `DevOps-Project-01`. The configuration is located in:

```text
DevOps-Project-01/infrastructure/modules/security/
├── main.tf
├── variables.tf
└── outputs.tf
```

Security groups act as virtual firewalls for AWS resources. They control allowed inbound and outbound traffic. They are stateful, so response traffic for an allowed connection is automatically permitted.

## 1. Complete security module configuration

### `main.tf`

```hcl
# Security Groups Module

# ALB Security Group
resource "aws_security_group" "alb" {
  name        = "${var.environment}-alb-sg"
  description = "Security group for application load balancer"
  vpc_id      = var.vpc_id

  ingress {
    from_port   = 80
    to_port     = 80
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  ingress {
    from_port   = 443
    to_port     = 443
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = {
    Name        = "${var.environment}-alb-sg"
    Environment = var.environment
  }
}

# Application Security Group
resource "aws_security_group" "app" {
  name        = "${var.environment}-app-sg"
  description = "Security group for application servers"
  vpc_id      = var.vpc_id

  ingress {
    from_port       = 8080
    to_port         = 8080
    protocol        = "tcp"
    security_groups = [aws_security_group.alb.id]
  }

  ingress {
    from_port       = 22
    to_port         = 22
    protocol        = "tcp"
    security_groups = [aws_security_group.bastion.id]
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = {
    Name        = "${var.environment}-app-sg"
    Environment = var.environment
  }
}

# Database Security Group
resource "aws_security_group" "db" {
  name        = "${var.environment}-db-sg"
  description = "Security group for database"
  vpc_id      = var.vpc_id

  ingress {
    from_port       = 3306
    to_port         = 3306
    protocol        = "tcp"
    security_groups = [aws_security_group.app.id]
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = {
    Name        = "${var.environment}-db-sg"
    Environment = var.environment
  }
}

# Bastion Host Security Group
resource "aws_security_group" "bastion" {
  name        = "${var.environment}-bastion-sg"
  description = "Security group for bastion host"
  vpc_id      = var.vpc_id

  ingress {
    from_port   = 22
    to_port     = 22
    protocol    = "tcp"
    cidr_blocks = var.allowed_ssh_cidr_blocks
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = {
    Name        = "${var.environment}-bastion-sg"
    Environment = var.environment
  }
}
```

### `variables.tf`

```hcl
variable "environment" {
  description = "Environment name"
  type        = string
}

variable "vpc_id" {
  description = "ID of the VPC"
  type        = string
}

variable "allowed_ssh_cidr_blocks" {
  description = "List of CIDR blocks allowed to SSH to bastion host"
  type        = list(string)
  default     = ["0.0.0.0/0"]  # WARNING: Restrict this in production
}
```

### `outputs.tf`

```hcl
output "alb_security_group_id" {
  description = "ID of the ALB security group"
  value       = aws_security_group.alb.id
}

output "app_security_group_id" {
  description = "ID of the application security group"
  value       = aws_security_group.app.id
}

output "db_security_group_id" {
  description = "ID of the database security group"
  value       = aws_security_group.db.id
}

output "bastion_security_group_id" {
  description = "ID of the bastion host security group"
  value       = aws_security_group.bastion.id
}
```

## 2. Common configuration fields

Each resource uses the following fields:

- `resource "aws_security_group"` creates one AWS security group.
- `name` gives the group an environment-specific name.
- `description` documents the group's purpose.
- `vpc_id` attaches the security group to the project VPC.
- `ingress` defines allowed inbound traffic.
- `egress` defines allowed outbound traffic.
- `tags` adds searchable metadata.

The expression `${var.environment}` creates names such as:

```text
 dev-alb-sg
 dev-app-sg
 dev-db-sg
 dev-bastion-sg
```

## 3. ALB security group

```hcl
resource "aws_security_group" "alb" {
  name        = "${var.environment}-alb-sg"
  description = "Security group for application load balancer"
  vpc_id      = var.vpc_id
```

This creates the security group attached to the Application Load Balancer.

### Inbound HTTP

```hcl
ingress {
  from_port   = 80
  to_port     = 80
  protocol    = "tcp"
  cidr_blocks = ["0.0.0.0/0"]
}
```

This allows TCP traffic on port `80` from any IPv4 address. It is used by the HTTP listener.

### Inbound HTTPS

```hcl
ingress {
  from_port   = 443
  to_port     = 443
  protocol    = "tcp"
  cidr_blocks = ["0.0.0.0/0"]
}
```

This allows TCP traffic on port `443` from any IPv4 address. An HTTPS listener and ACM certificate are still required before HTTPS traffic can actually be processed.

### ALB outbound traffic

```hcl
egress {
  from_port   = 0
  to_port     = 0
  protocol    = "-1"
  cidr_blocks = ["0.0.0.0/0"]
}
```

`protocol = "-1"` represents all protocols. This allows the ALB to send traffic to application targets.

The ALB security flow is:

```text
Internet -> ALB security group: TCP 80/443
ALB security group -> Application security group: TCP 8080
```

## 4. Application security group

```hcl
resource "aws_security_group" "app" {
  name        = "${var.environment}-app-sg"
  description = "Security group for application servers"
  vpc_id      = var.vpc_id
```

This group is attached to application EC2 instances created by the Auto Scaling Group.

### Application traffic from the ALB

```hcl
ingress {
  from_port       = 8080
  to_port         = 8080
  protocol        = "tcp"
  security_groups = [aws_security_group.alb.id]
}
```

This allows application traffic on port `8080` only from resources associated with the ALB security group. It does not expose port `8080` to the whole internet.

The application traffic flow is:

```text
Client -> ALB port 80 -> ALB -> Application instance port 8080
```

### SSH traffic from the bastion

```hcl
ingress {
  from_port       = 22
  to_port         = 22
  protocol        = "tcp"
  security_groups = [aws_security_group.bastion.id]
}
```

This allows SSH on port `22` only from the bastion security group. Direct SSH access from the internet to application instances is not allowed by this rule.

### Application outbound traffic

The application group permits all outbound traffic according to the current configuration. This allows application instances to reach services such as the database, package repositories, AWS APIs, and other required endpoints.

## 5. Database security group

```hcl
resource "aws_security_group" "db" {
  name        = "${var.environment}-db-sg"
  description = "Security group for database"
  vpc_id      = var.vpc_id
```

This group is attached to the RDS database.

### MySQL traffic from the application

```hcl
ingress {
  from_port       = 3306
  to_port         = 3306
  protocol        = "tcp"
  security_groups = [aws_security_group.app.id]
}
```

This allows MySQL traffic on port `3306` only from the application security group.

The database is therefore not open to the internet:

```text
Application security group -> Database security group: TCP 3306
```

The database outbound rule is currently open for all outbound traffic according to the configuration.

## 6. Bastion host security group

```hcl
resource "aws_security_group" "bastion" {
  name        = "${var.environment}-bastion-sg"
  description = "Security group for bastion host"
  vpc_id      = var.vpc_id
```

This group is attached to the bastion host.

### SSH access from administrators

```hcl
ingress {
  from_port   = 22
  to_port     = 22
  protocol    = "tcp"
  cidr_blocks = var.allowed_ssh_cidr_blocks
}
```

SSH access is controlled by the variable `allowed_ssh_cidr_blocks`.

The current default is:

```hcl
default = ["0.0.0.0/0"]
```

This allows SSH attempts from any IPv4 address and is unsafe for production. It should be restricted to a trusted administrator IP, VPN range, or corporate network. For one fixed public IPv4 address, use a `/32` CIDR such as:

```text
203.0.113.10/32
```

The bastion outbound rule permits the bastion to connect to the private application instances.

## 7. Security-group references

These rules use security-group references instead of broad CIDR ranges:

```hcl
security_groups = [aws_security_group.alb.id]
security_groups = [aws_security_group.bastion.id]
security_groups = [aws_security_group.app.id]
```

They mean:

```text
ALB security group -> Application security group
Bastion security group -> Application security group
Application security group -> Database security group
```

A security-group reference allows traffic from resources associated with that security group. It does not allow every resource in the VPC.

## 8. Security groups versus route tables

| Resource | Responsibility |
| --- | --- |
| Route table | Determines where traffic is sent |
| Security group | Determines whether traffic is permitted |

Both must be correct. A security group cannot create a missing route, and a route cannot override a blocked security-group rule.

For the ALB flow, the required conditions are:

```text
Public subnet route table -> Internet Gateway
ALB security group        -> Allows TCP 80/443
App security group        -> Allows TCP 8080 from the ALB group
```

## 9. Stateful behavior

Security groups are stateful. If a connection is allowed in one direction, the response traffic is automatically allowed.

For example:

```text
ALB -> Application: TCP 8080
Application -> ALB: response traffic automatically allowed
```

The same applies to:

```text
Application -> Database: TCP 3306
Database -> Application: response traffic automatically allowed
```

## 10. Root module usage

The root configuration creates the security module as follows:

```hcl
module "security" {
  source = "./modules/security"

  environment              = var.environment
  vpc_id                   = module.vpc.vpc_id
  allowed_ssh_cidr_blocks  = var.allowed_ssh_cidr_blocks
}
```

The outputs are then used by other modules:

```hcl
module "rds" {
  source = "./modules/rds"

  security_group_ids = [module.security.db_security_group_id]
}

module "asg" {
  source = "./modules/asg"

  security_group_ids = [module.security.app_security_group_id]
}
```

The output IDs allow the RDS and ASG modules to reuse the existing security groups without defining duplicate groups.

## 11. Complete traffic flow

Application traffic:

```text
Internet
  -> ALB security group: TCP 80/443
  -> Application security group: TCP 8080
  -> Application instance
  -> Database security group: TCP 3306
  -> RDS MySQL database
```

Administrative traffic:

```text
Trusted administrator CIDR
  -> Bastion security group: TCP 22
  -> Bastion host
  -> Application security group: TCP 22
  -> Application instance
```

## 12. Security warning and recommended production changes

The default bastion SSH rule allows `0.0.0.0/0`:

```hcl
default = ["0.0.0.0/0"]
```

Before using this configuration in production:

- Restrict `allowed_ssh_cidr_blocks` to trusted administrator IPs or VPN ranges.
- Avoid exposing application SSH directly to the internet.
- Allow application SSH only from the bastion security group.
- Allow database access only from the application security group.
- Keep public access limited to ALB listener ports.
- Consider restricting outbound rules according to the application's actual requirements.

The intended access model is:

```text
Public users       -> ALB on TCP 80/443
ALB                -> Application on TCP 8080
Bastion            -> Application on TCP 22
Application        -> Database on TCP 3306
```

## 13. Validation

Run Terraform from `DevOps-Project-01/infrastructure`:

```bash
terraform fmt -recursive
terraform validate
terraform plan
```

Verify the plan shows:

- One ALB security group.
- One application security group.
- One database security group.
- One bastion security group.
- ALB access on ports `80` and `443`.
- Application access on port `8080` only from the ALB security group.
- Application SSH on port `22` only from the bastion security group.
- Database access on port `3306` only from the application security group.
- Bastion SSH restricted to the intended CIDR blocks.
