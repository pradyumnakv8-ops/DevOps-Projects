# Complete Infrastructure Guide

## Project

This guide describes the infrastructure for the Java Login application in `DevOps-Project-01`.

The target AWS region is `ap-south-1` (Mumbai). Terraform must create a secure, two-AZ architecture for a Spring Boot application backed by Amazon RDS MySQL.

## Final architecture

```text
Internet
   |
   | TCP 80 / 443
   v
Application Load Balancer
(public subnets in two Availability Zones)
   |
   | HTTP TCP 8080
   v
EC2 instances managed by an Auto Scaling Group
(private subnets in two Availability Zones)
   |
   | MySQL TCP 3306
   v
Amazon RDS MySQL
(private subnets / DB subnet group)

AWS Systems Manager, CloudWatch, and S3/Terraform state
are used for management, monitoring, and infrastructure state.
```

## 1. Terraform project structure

```text
DevOps-Project-01/infrastructure-v2/
├── .gitignore
├── provider.tf
├── terraform.tfvars
├── variables.tf
├── main.tf
├── security.tf
├── database.tf
├── alb.tf
├── asg.tf
├── iam.tf
├── monitoring.tf
├── outputs.tf
└── BACKEND.md
```

Terraform combines every `.tf` file in the directory. It does not require resources to be in a particular file.

## 2. AWS provider

`provider.tf` configures the AWS provider and Terraform requirements:

```hcl
terraform {
  required_version = ">= 1.10.0"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
  }

  backend "s3" {
    bucket       = "replace-with-a-globally-unique-state-bucket"
    key          = "java-login-app/dev/terraform.tfstate"
    region       = "ap-south-1"
    encrypt      = true
    use_lockfile = true
  }
}

provider "aws" {
  region = var.aws_region

  default_tags {
    tags = {
      Project     = var.project
      Environment = var.environment
      ManagedBy   = "Terraform"
    }
  }
}
```

Backend settings cannot reference Terraform variables. The S3 bucket and key must be literal values.

## 3. Input variables

`variables.tf` defines reusable configuration:

```hcl
variable "project" {
  type    = string
  default = "java-login-app"
}

variable "environment" {
  type    = string
  default = "dev"
}

variable "aws_region" {
  type    = string
  default = "ap-south-1"
}

variable "vpc_cidr" {
  type    = string
  default = "10.20.0.0/16"
}

variable "public_subnet_cidrs" {
  type = list(string)
  default = [
    "10.20.1.0/24",
    "10.20.2.0/24"
  ]
}

variable "private_subnet_cidrs" {
  type = list(string)
  default = [
    "10.20.11/24",
    "10.20.12.0/24"
  ]
}

variable "db_name" {
  type    = string
  default = "javaapp"
}

variable "db_username" {
  type      = string
  sensitive = true
}

variable "db_password" {
  type      = string
  sensitive = true
}

variable "key_name" {
  description = "Optional EC2 key pair name. Prefer SSM Session Manager instead."
  type        = string
  default     = null
}
```

Example `terraform.tfvars`:

```hcl
aws_region = "ap-south-1"
project = "java-login-app"
environment = "dev"

vpc_cidr = "10.20.0.0/16"

public_subnet_cidrs = [
  "10.20.1.0/24",
  "10.20.2.0/24"
]

private_subnet_cidrs = [
  "10.20.11.0/24",
  "10.20.12.0/24"
]
```

Do not add database passwords to `terraform.tfvars`. Supply them through environment variables or a secrets service:

```bash
export TF_VAR_db_username='appadmin'
export TF_VAR_db_password='replace-with-a-strong-unique-password'
```

Marking variables `sensitive` hides normal CLI output, but Terraform state may still contain them.

## 4. Availability Zones

```hcl
data "aws_availability_zones" "available" {
  state = "available"

  filter {
    name   = "opt-in-status"
    values = ["opt-in-not-required"]
  }
}

locals {
  availability_zones = slice(
    data.aws_availability_zones.available.names,
    0,
    2
  )
}
```

This discovers two usable zones rather than assuming names such as `ap-south-1a` or `ap-south-1b`. The selected subnet pair should always remain in distinct zones.

## 5. VPC

```hcl
resource "aws_vpc" "main" {
  cidr_block           = var.vpc_cidr
  enable_dns_support   = true
  enable_dns_hostnames = true

  tags = {
    Name = "${var.project}-${var.environment}-vpc"
  }
}
```

Example CIDR:

```text
10.20.0.0/16
```

A VPC CIDR should not overlap with networks connected through peering or VPN. Choose CIDRs such as `10.20.0.0/16` as long as they do not conflict with other networks.

DNS support and DNS hostnames enable private DNS resolution inside AWS-supported networks.

## 6. Public subnets

```hcl
resource "aws_subnet" "public" {
  count = length(var.public_subnet_cidrs)

  vpc_id                  = aws_vpc.main.id
  cidr_block              = var.public_subnet_cidrs[count.index]
  availability_zone       = local.availability_zones[count.index]
  map_public_ip_on_launch = true

  tags = {
    Name = "${var.project}-${var.environment}-public-${count.index + 1}"
    Tier = "public"
  }
}
```

Example public subnets:

| Subnet | CIDR | Availability Zone |
| --- | --- | --- |
| Public 1 | `10.20.1.0/24` | First discovered AZ |
| Public 2 | `10.20.2.0/24` | Second discovered AZ |

Public subnets are for internet-facing entry points such as an ALB or NAT Gateway. A public subnet must have a route to an Internet Gateway.

## 7. Private subnets

```hcl
resource "aws_subnet" "private" {
  count = length(var.private_subnet_cidrs)

  vpc_id            = aws_vpc.main.id
  cidr_block        = var.private_subnet_cidrs[count.index]
  availability_zone = local.availability_zones[count.index]

  tags = {
    Name = "${var.project}-${var.environment}-private-${count.index + 1}"
    Tier = "private"
  }
}
```

Example private subnets:

| Subnet | CIDR | Availability Zone |
| --- | --- | --- |
| Private 1 | `10.20.11.0/24` | First discovered AZ |
| Private 2 | `10.20.12.0/24` | Second discovered AZ |

Application EC2 instances and RDS should use private subnets.

## 8. Internet Gateway

```hcl
resource "aws_internet_gateway" "main" {
  vpc_id = aws_vpc.main.id

  tags = {
    Name = "${var.project}-${var.environment}-igw"
  }
}
```

The Internet Gateway connects the VPC to the internet. It is attached to the VPC; routing determines whether a subnet can use it.

## 9. Public routing

```hcl
resource "aws_route_table" "public" {
  vpc_id = aws_vpc.main.id

  tags = {
    Name = "${var.project}-${var.environment}-public-rt"
  }
}

resource "aws_route" "public_internet" {
  route_table_id         = aws_route_table.public.id
  destination_cidr_block = "0.0.0.0/0"
  gateway_id             = aws_internet_gateway.main.id
}

resource "aws_route_table_association" "public" {
  count = length(aws_subnet.public)

  subnet_id      = aws_subnet.public[count.index].id
  route_table_id = aws_route_table.public.id
}
```

Public route:

```text
0.0.0.0/0 → Internet Gateway
```

Associations attach both public subnets to this route table.

## 10. Private routing

Create separate route tables for private subnets:

```hcl
resource "aws_route_table" "private" {
  count = length(aws_subnet.private)

  vpc_id = aws_vpc.main.id

  tags = {
    Name = "${var.project}-${var.environment}-private-rt-${count.index + 1}"
  }
}

resource "aws_route_table_association" "private" {
  count = length(aws_subnet.private)

  subnet_id      = aws_subnet.private[count.index].id
  route_table_id = aws_route_table.private[count.index].id
}
```

Private subnets do not need internet routing just to reach RDS. If private EC2 instances need package updates or internet downloads, add NAT Gateways or use VPC endpoints and tightly controlled delivery systems.

## 11. Security groups

### ALB security group

```hcl
resource "aws_security_group" "alb" {
  name        = "${var.project}-${var.environment}-alb-sg"
  description = "Public HTTP and HTTPS access to the application ALB"
  vpc_id      = aws_vpc.main.id

  ingress {
    description = "HTTP"
    from_port   = 80
    to_port     = 80
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  ingress {
    description = "HTTPS"
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
}
```

Initially, HTTP can remain available; production should redirect HTTP to HTTPS.

### Application security group

```hcl
resource "aws_security_group" "app" {
  name        = "${var.project}-${var.environment}-app-sg"
  description = "Application traffic from the ALB"
  vpc_id      = aws_vpc.main.id

  ingress {
    description     = "Tomcat from ALB"
    from_port       = 8080
    to_port         = 8080
    protocol        = "tcp"
    security_groups = [aws_security_group.alb.id]
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }
}
```

Do not open SSH publicly. Prefer AWS Systems Manager Session Manager for private administration.

### Database security group

```hcl
resource "aws_security_group" "db" {
  name        = "${var.project}-${var.environment}-db-sg"
  description = "MySQL access from application servers"
  vpc_id      = aws_vpc.main.id

  ingress {
    description     = "MySQL from application instances"
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
}
```

This prevents public access to RDS and allows database traffic only from members of the application security group.

## 12. DB subnet group

```hcl
resource "aws_db_subnet_group" "main" {
  name        = "${var.project}-${var.environment}-db-subnets"
  description = "Private subnets for RDS"
  subnet_ids  = aws_subnet.private[*].id

  tags = {
    Name = "${var.project}-${var.environment}-db-subnets"
  }
}
```

A DB subnet group tells RDS which subnets and Availability Zones it may use. It is not a firewall. RDS should receive subnets in at least two AZs.

## 13. RDS MySQL

```hcl
resource "aws_db_instance" "main" {
  identifier = "${var.project}-${var.environment}-mysql"

  engine         = "mysql"
  engine_version = "8.0"
  instance_class = "db.t3.micro"

  allocated_storage     = 20
  max_allocated_storage = 50
  storage_type          = "gp3"
  storage_encrypted     = true

  db_name  = var.db_name
  username = var.db_username
  password = var.db_password

  db_subnet_group_name   = aws_db_subnet_group.main.name
  vpc_security_group_ids = [aws_security_group.db.id]
  publicly_accessible    = false

  backup_retention_period = 7
  multi_az                = false

  deletion_protection       = false
  skip_final_snapshot       = false
  final_snapshot_identifier = "${var.project}-${var.environment}-mysql-final"

  tags = {
    Name = "${var.project}-${var.environment}-mysql"
  }
}
```

Key settings:

- `instance_class`: `db.t3.micro` is suitable for learning, subject to cost and workload review.
- `allocated_storage`: starts at 20 GB.
- `max_allocated_storage`: allows autoscaling up to 50 GB.
- `storage_encrypted`: enables storage encryption.
- `publicly_accessible`: keeps RDS off the public internet.
- `backup_retention_period`: retains automated backups for seven days.
- `multi_az`: production should generally use `true`; this learning setup may use `false` to reduce cost.
- `deletion_protection`: enable it for production.
- `skip_final_snapshot`: `false` creates a final snapshot during deletion. Use unique snapshot names for repeated destroy/create cycles.

## 14. Application Load Balancer

Create an internet-facing ALB in both public subnets:

```hcl
resource "aws_lb" "main" {
  name               = "${var.project}-${var.environment}-alb"
  internal           = false
  load_balancer_type = "application"
  security_groups    = [aws_security_group.alb.id]
  subnets            = aws_subnet.public[*].id

  enable_deletion_protection = false
}

resource "aws_lb_target_group" "main" {
  name     = "${var.project}-${var.environment}-tg"
  port     = 8080
  protocol = "HTTP"
  vpc_id   = aws_vpc.main.id

  health_check {
    enabled             = true
    path                = "/"
    protocol            = "HTTP"
    port                = "traffic-port"
    matcher             = "200"
    interval            = 30
    timeout             = 5
    healthy_threshold   = 2
    unhealthy_threshold = 2
  }
}

resource "aws_lb_listener" "http" {
  load_balancer_arn = aws_lb.main.arn
  port              = 80
  protocol          = "HTTP"

  default_action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.main.arn
  }
}
```

The application should return HTTP 200 from `/` for the health check. Add ACM and HTTPS before production use.

## 15. EC2 launch template and ASG

The application instances should run in private subnets and launch only approved software.

```hcl
resource "aws_launch_template" "main" {
  name_prefix   = "${var.project}-${var.environment}-lt"
  instance_type = "t3.micro"
  key_name      = var.key_name

  vpc_security_group_ids = [aws_security_group.app.id]

  iam_instance_profile {
    name = aws_iam_instance_profile.app.name
  }

  user_data = base64encode(<<-EOF
    #!/bin/bash
    set -e
    dnf update -y
    dnf install -y java-11-amazon-corretto nginx
  EOF
  )

  lifecycle {
    create_before_destroy = true
  }
}

resource "aws_autoscaling_group" "main" {
  name                = "${var.project}-${var.environment}-asg"
  vpc_zone_identifier = aws_subnet.private[*].id
  target_group_arns   = [aws_lb_target_group.main.arn]

  health_check_type         = "ELB"
  health_check_grace_period = 300

  min_size         = 2
  max_size         = 6
  desired_capacity = 2

  launch_template {
    id      = aws_launch_template.main.id
    version = "$Latest"
  }
}
```

Use dynamic AMI lookup for Amazon Linux instead of a fixed AMI:

```hcl
data "aws_ami" "amazon_linux" {
  most_recent = true
  owners      = ["amazon"]

  filter {
    name   = "name"
    values = ["al2023-ami-2023.*-x86_64"]
  }

  filter {
    name   = "architecture"
    values = ["x86_64"]
  }
}
```

Then set:

```hcl
image_id = data.aws_ami.amazon_linux.id
```

## 16. Application deployment

The launch template is not sufficient for deploying the Java WAR. Add one of these approaches:

- Cloud-init downloads the WAR from S3 and starts Tomcat.
- AWS CodeDeploy deploys a release to instances.
- A build pipeline builds and deploys the artifact.
- Packer builds an AMI containing the application.

Do not place database credentials in user-data. EC2 instances can retrieve configuration through AWS Secrets Manager or Parameter Store at runtime.

Example Spring configuration:

```properties
spring.datasource.url=${DB_URL}
spring.datasource.username=${DB_USERNAME}
spring.datasource.password=${DB_PASSWORD}
```

The RDS endpoint will be available as a Terraform output. It can be placed in a parameter or secret created after RDS creation.

## 17. IAM and Systems Manager

Create an EC2 role that allows Systems Manager:

```hcl
resource "aws_iam_role" "app" {
  name = "${var.project}-${var.environment}-ec2-role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect = "Allow"
      Principal = {
        Service = "ec2.amazonaws.com"
      }
      Action = "sts:AssumeRole"
    }]
  })
}

resource "aws_iam_role_policy_attachment" "ssm" {
  role       = aws_iam_role.app.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore"
}

resource "aws_iam_instance_profile" "app" {
  name = "${var.project}-${var.environment}-instance-profile"
  role = aws_iam_role.app.name
}
```

Session Manager enables shell access without public SSH ports or a key pair. If private instances cannot reach SSM services through public networking, add SSM VPC endpoints.

Grant application instances only the permissions they require for S3 artifacts or Secrets Manager. Avoid attaching administrator or broad write policies.

## 18. Monitoring

At minimum, monitor:

- ALB target health
- ALB HTTP 5xx responses
- ALB HTTP 4xx/5xx ratio
- ALB request latency
- ASG CPU utilization
- EC2 instance status
- RDS CPU utilization
- RDS free storage
- RDS free memory
- RDS database connections
- RDS replication or availability status

Create CloudWatch alarms and route high-priority notifications to SNS, email, or an incident system.

Use CloudWatch Logs for:

- Application logs
- Tomcat logs
- VPC Flow Logs
- ALB access logs, if enabled

## 19. Terraform backend

Create an encrypted, private S3 bucket for Terraform state before initialization:

```bash
aws s3api create-bucket \
  --bucket replace-with-a-globally-unique-state-bucket \
  --region ap-south-1 \
  --create-bucket-configuration LocationConstraint=ap-south-1

aws s3api put-bucket-versioning \
  --bucket replace-with-a-globally-unique-state-bucket \
  --versioning-configuration Status=Enabled

aws s3api put-bucket-encryption \
  --bucket replace-with-a-globally-unique-state-bucket \
  --server-side-encryption-configuration \
  '{"Rules":[{"ApplyServerSideEncryptionByDefault":{"SSEAlgorithm":"AES256"}}]}'

aws s3api put-public-access-block \
  --bucket replace-with-a-globally-unique-state-bucket \
  --public-access-block-configuration \
  'BlockPublicAcls=true,IgnorePublicAcls=true,BlockPublicPolicy=true,RestrictPublicBuckets=true'
```

Use separate state keys for development and production:

```text
java-login-app/dev/terraform.tfstate
java-login-app/prod/terraform.tfstate
```

Never commit `*.tfstate`, `*.tfstate.*`, `*.tfplan`, or `.terraform/`.

## 20. Outputs

Example `outputs.tf`:

```hcl
output "vpc_id" {
  value = aws_vpc.main.id
}

output "public_subnet_ids" {
  value = aws_subnet.public[*].id
}

output "private_subnet_ids" {
  value = aws_subnet.private[*].id
}

output "alb_dns_name" {
  value = aws_lb.main.dns_name
}

output "db_endpoint" {
  value = aws_db_instance.main.endpoint
}

output "db_name" {
  value = aws_db_instance.main.db_name
}

output "app_security_group_id" {
  value = aws_security_group.app.id
}

output "db_security_group_id" {
  value = aws_security_group.db.id
}
```

Do not output credentials.

## 21. Terraform workflow

```bash
aws sts get-caller-identity
terraform init
terraform fmt -recursive
terraform validate
terraform plan
terraform apply
```

The plan is a review step, not a deployment step. Confirm the AWS account, region, resource count, CIDRs, security groups, and database settings before apply.

To remove all infrastructure:

```bash
terraform destroy
```

Review the destroy plan and protect important production resources before running it.

## 22. Production prerequisites

Before a production deployment:

- Enable RDS Multi-AZ.
- Enable RDS deletion protection.
- Use unique RDS final snapshots.
- Store secrets in AWS Secrets Manager or Systems Manager Parameter Store.
- Add HTTPS with ACM.
- Redirect HTTP to HTTPS.
- Add Route 53 DNS records.
- Add WAF only if the threat model requires it.
- Restrict or remove public SSH access.
- Configure EC2 IAM roles using least privilege.
- Add NAT or VPC endpoints according to private-network requirements.
- Configure application deployment automation.
- Configure CloudWatch alarms and notifications.
- Add ALB access and application logs.
- Add ASG scaling policies based on measured traffic.
- Test database restore and application rollback procedures.
- Run Terraform plan in CI and require approval for apply.
- Review AWS cost estimates before applying NAT, RDS Multi-AZ, and larger compute resources.

## 23. Traffic flow summary

```text
Internet
  -> TCP 80/443
  -> Internet Gateway
  -> Public route table
  -> Public subnets
  -> ALB security group
  -> Application Load Balancer
  -> TCP 8080
  -> Application security group
  -> EC2 instances in private subnets
  -> TCP 3306
  -> Database security group
  -> RDS MySQL in private subnets
```

The public boundary is the ALB. Application instances and RDS remain in private subnets and should not accept public internet traffic directly.
