# Terraform Application Load Balancer: ALB, Listener, Target Group, and Security Group

This guide explains the Application Load Balancer (ALB) configuration used by `DevOps-Project-01`. The relevant infrastructure is under `DevOps-Project-01/infrastructure/` and its ALB module is in `DevOps-Project-01/infrastructure/modules/alb/`.

## 1. Infrastructure dependency flow

The ALB is created after the VPC, public subnets, route tables, and security groups are available.

```text
VPC
  -> Public subnets
  -> Internet Gateway and public routes
  -> ALB security group
  -> Internet-facing Application Load Balancer
  -> HTTP listener on port 80
  -> Target group on port 8080
  -> Application Auto Scaling Group instances
```

The root module defines the infrastructure dependency in `DevOps-Project-01/infrastructure/main.tf`:

```hcl
module "vpc" {
  source = "./modules/vpc"

  environment     = var.environment
  vpc_cidr       = var.vpc_cidr
  public_subnets  = var.public_subnets
  private_subnets = var.private_subnets
  azs            = var.availability_zones
}

module "security" {
  source = "./modules/security"

  environment             = var.environment
  vpc_id                 = module.vpc.vpc_id
  allowed_ssh_cidr_blocks = var.allowed_ssh_cidr_blocks
}

module "alb" {
  source = "./modules/alb"

  environment    = var.environment
  vpc_id         = module.vpc.vpc_id
  public_subnets = module.vpc.public_subnet_ids
}

module "asg" {
  source = "./modules/asg"

  environment         = var.environment
  vpc_id              = module.vpc.vpc_id
  private_subnet_ids  = module.vpc.private_subnet_ids
  security_group_ids  = [module.security.app_security_group_id]
  target_group_arns   = [module.alb.target_group_arn]
}
```

The ALB receives public subnet IDs from the VPC module. The ASG receives the ALB target-group ARN so future application instances register with the ALB.

## 2. ALB module files

```text
DevOps-Project-01/infrastructure/modules/alb/
├── main.tf
├── variables.tf
└── outputs.tf
```

The module inputs are defined in `variables.tf`:

```hcl
variable "environment" {
  description = "Environment name"
  type        = string
}

variable "vpc_id" {
  description = "VPC ID"
  type        = string
}

variable "public_subnets" {
  description = "List of public subnet IDs"
  type        = list(string)
}
```

The module does not create the public subnets or VPC; it receives them from the VPC module.

## 3. Internet-facing Application Load Balancer

The ALB resource is in `DevOps-Project-01/infrastructure/modules/alb/main.tf`:

```hcl
resource "aws_lb" "main" {
  name               = "${var.environment}-alb"
  internal           = false
  load_balancer_type = "application"
  security_groups    = [aws_security_group.alb.id]
  subnets            = var.public_subnets

  enable_deletion_protection = false

  tags = {
    Name        = "${var.environment}-alb"
    Environment = var.environment
  }
}
```

- `name` includes the environment, such as `dev-alb`.
- `internal = false` creates an internet-facing ALB.
- `load_balancer_type = "application"` creates an HTTP/HTTPS Layer 7 load balancer.
- `security_groups` attaches the ALB security group from the ALB module.
- `subnets` places ALB nodes in the public subnets supplied by the VPC module.
- `enable_deletion_protection = false` allows normal Terraform destruction.
- Tags identify the environment and resource purpose.

The public-subnet route requirement is:

```text
0.0.0.0/0 -> Internet Gateway
```

The public subnets must also have suitable route-table associations. Without those routes or the required security-group rules, the ALB may exist but remain unreachable or unable to forward traffic.

## 4. ALB target group

The target group represents application instances that receive traffic from the ALB:

```hcl
resource "aws_lb_target_group" "main" {
  name     = "${var.environment}-tg"
  port     = 8080
  protocol = "HTTP"
  vpc_id   = var.vpc_id

  health_check {
    enabled             = true
    healthy_threshold   = 2
    interval            = 30
    matcher             = "200"
    path                = "/"
    port                = "traffic-port"
    protocol            = "HTTP"
    timeout             = 5
    unhealthy_threshold = 2
  }

  tags = {
    Name        = "${var.environment}-tg"
    Environment = var.environment
  }
}
```

- `port = 8080` forwards traffic to the Java application port.
- `protocol = "HTTP"` sends HTTP traffic to application targets.
- `vpc_id` places the target group in the project VPC.
- Instances register with this target group through the ASG target-group ARN.

The name, port, protocol, and health-check settings should match the application being deployed.

## 5. Target health check

The target health check is:

```text
Protocol:  HTTP
Path:      /
Expected:  200
Interval:  30 seconds
Timeout:   5 seconds
Healthy:   2 successful checks
Unhealthy: 2 failed checks
Port:      traffic-port
```

`traffic-port` means the health check uses target port `8080` from the target group.

The application must respond with HTTP `200` at `/`. Otherwise, targets remain unhealthy and the ALB does not route application traffic to them.

## 6. HTTP listener

The listener accepts traffic at the ALB and forwards it to the target group:

```hcl
resource "aws_lb_listener" "main" {
  load_balancer_arn = aws_lb.main.arn
  port              = "80"
  protocol          = "HTTP"

  default_action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.main.arn
  }
}
```

The listener:

- Accepts public HTTP traffic on port `80`.
- Uses the ALB ARN as the listener parent.
- Forwards matching traffic to the target group.
- Sends traffic to application targets on target port `8080`.

There is currently no HTTPS listener or ACM certificate resource in this module. Port `443` is allowed by the ALB security group, but no HTTPS listener is configured unless one is added later.

The current request flow is:

```text
Browser
  -> HTTP port 80
  -> ALB listener
  -> target group
  -> application instance port 8080
```

## 7. ALB security group

The ALB module creates a module-local security group:

```hcl
resource "aws_security_group" "alb" {
  name        = "${var.environment}-alb-sg"
  description = "Security group for ALB"
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
```

Allowed traffic is:

| Direction | Protocol/port | Source or destination |
| --- | --- | --- |
| Inbound | TCP 80 | `0.0.0.0/0` |
| Inbound | TCP 443 | `0.0.0.0/0` |
| Outbound | All protocols | `0.0.0.0/0` |

Port `80` has an active listener. Port `443` is allowed but has no listener or certificate in this module.

## 8. ALB to application security relationship

The application security group in `DevOps-Project-01/infrastructure/modules/security/main.tf` allows TCP `8080` from `aws_security_group.alb.id`:

```hcl
ingress {
  from_port       = 8080
  to_port         = 8080
  protocol        = "tcp"
  security_groups = [aws_security_group.alb.id]
}
```

The security chain is therefore conceptually:

```text
Internet
  -> TCP 80/443
  -> ALB security group
  -> TCP 8080
  -> Application security group
  -> Application target
```

## 9. Duplicate ALB security-group definitions

There are currently two ALB security-group implementations:

1. `DevOps-Project-01/infrastructure/modules/alb/main.tf`
2. `DevOps-Project-01/infrastructure/modules/security/main.tf`

The ALB resource attaches the module-local security group:

```hcl
security_groups = [aws_security_group.alb.id]
```

However, the application security group in the security module references `aws_security_group.alb.id`, where `aws_security_group.alb` belongs to the security module.

These are separate AWS security-group resources. To ensure traffic reaches the application, the project should use one ALB security group consistently.

The preferred correction is:

- Keep the ALB security group in the security module.
- Add an ALB security-group input to `modules/alb/variables.tf`.
- Pass `module.security.alb_security_group_id` from `main.tf` to the ALB module.
- Set `security_groups = [var.alb_security_group_id]`.
- Remove the duplicate `aws_security_group "alb"` resource from `modules/alb/main.tf`.
- Keep the application ingress rule referencing that same security-module ALB group.

## 10. ASG integration

The ALB module exports the target-group ARN:

```hcl
module "alb" {
  source = "./modules/alb"

  environment    = var.environment
  vpc_id         = module.vpc.vpc_id
  public_subnets = module.vpc.public_subnet_ids
}

module "asg" {
  source = "./modules/asg"

  target_group_arns = [module.alb.target_group_arn]
}
```

This creates the intended relationship:

```text
ALB
  -> Target group
  -> ASG target-group attachment
  -> EC2 instances in private subnets
```

Instances created by the ASG register with the target group and receive HTTP traffic on port `8080`.

## 11. ALB outputs

The module declares outputs in `DevOps-Project-01/infrastructure/modules/alb/outputs.tf`:

```hcl
output "alb_arn" {
  description = "ALB ARN"
  value       = aws_lb.main.arn
}

output "alb_dns_name" {
  description = "ALB DNS name"
  value       = aws_lb.main.dns_name
}

output "target_group_arn" {
  description = "Target group ARN"
  value       = aws_lb_target_group.main.arn
}
```

Although declared in `outputs.tf`, these outputs provide:

- `alb_arn`: identity of the load balancer.
- `alb_dns_name`: public DNS endpoint for accessing the ALB.
- `target_group_arn`: ARN passed to the ASG for target registration.

## 12. Validation and deployment

Run Terraform from `DevOps-Project-01/infrastructure`:

```bash
terraform init
terraform fmt -recursive
terraform validate
terraform plan
```

Before apply, verify:

- The VPC and public subnets exist.
- Both public subnets have routes to the Internet Gateway.
- The ALB security group allows port `80` from the required source.
- The application security group allows port `8080` from the actual ALB security group.
- The application responds with HTTP `200` at `/` on port `8080`.
- The ASG has been supplied the target-group ARN.

Apply only after reviewing the Terraform plan:

```bash
terraform apply
```

## 13. Complete traffic flow

```text
Internet
  -> Internet Gateway
  -> Public subnet route
  -> Internet-facing ALB
  -> ALB security group: TCP 80/443
  -> HTTP listener: TCP 80
  -> Target group: HTTP 8080
  -> Application security group: TCP 8080
  -> EC2 application instance in private subnet
```

Route tables determine network reachability, while security groups determine whether each connection is allowed.
