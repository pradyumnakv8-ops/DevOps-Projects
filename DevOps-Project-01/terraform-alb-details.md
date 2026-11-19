# Terraform Application Load Balancer: Line-by-Line Explanation

This document explains the ALB configuration in `DevOps-Project-01/infrastructure/modules/alb/main.tf` one section at a time.

## 1. ALB resource

```hcl
resource "aws_lb" "main" {
```

This creates an Application Load Balancer in AWS:

- `name` assigns it a name such as `dev-alb`.
- `internal = false` makes it internet-facing.
- `load_balancer_type = "application"` enables HTTP/HTTPS traffic handling.
- `security_groups` attaches the ALB security group.
- `subnets` places the ALB across the public subnets supplied by the VPC module.
- `enable_deletion_protection = false` permits Terraform to destroy it.

```hcl
tags = {
  Name        = "${var.environment}-alb"
  Environment = var.environment
}
```

The tags help identify and manage the ALB.

## 2. Target group

```hcl
resource "aws_lb_target_group" "main" {
```

A target group contains the application instances:

- `name` identifies the target group.
- `port = 8080` sends traffic to the Java application port.
- `protocol = "HTTP"` uses HTTP between the ALB and targets.
- `vpc_id` places the target group in the project VPC.

The target group does not start application instances. The ASG supplies targets later.

## 3. Target health check

```hcl
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
```

- `enabled = true` performs periodic health checks.
- `path = "/"` checks the application root path.
- `matcher = "200"` treats HTTP status `200` as healthy.
- `interval = 30` checks every 30 seconds.
- `timeout = 5` allows five seconds for a response.
- `healthy_threshold = 2` requires two successful checks.
- `unhealthy_threshold = 2` requires two failures.
- `port = "traffic-port"` uses target port `8080`.
- `protocol = "HTTP"` uses HTTP for health checks.

The application must return HTTP `200` from `/`, or ALB targets may remain unhealthy.

## 4. HTTP listener

```hcl
resource "aws_lb_listener" "main" {
```

The listener receives client requests:

- `load_balancer_arn` associates it with the ALB.
- `port = "80"` listens for HTTP traffic.
- `protocol = "HTTP"` handles HTTP requests.

```hcl
default_action {
  type             = "forward"
  target_group_arn = aws_lb_target_group.main.arn
}
```

Every unmatched request is forwarded to the target group. The resulting flow is:

```text
Browser
  -> Port 80
  -> ALB listener
  -> Target group
  -> EC2 port 8080
```

## 5. ALB security group

```hcl
resource "aws_security_group" "alb" {
```

This security group controls traffic entering and leaving the ALB.

### Inbound HTTP

```hcl
from_port   = 80
to_port     = 80
cidr_blocks = ["0.0.0.0/0"]
```

Port `80` is reachable from every IPv4 address.

### Inbound HTTPS

```hcl
from_port   = 443
to_port     = 443
cidr_blocks = ["0.0.0.0/0"]
```

Port `443` is allowed, but this file does not create an HTTPS listener or attach an SSL certificate.

### Outbound traffic

```hcl
protocol    = "-1"
cidr_blocks = ["0.0.0.0/0"]
```

`-1` allows all protocols outbound, permitting the ALB to reach application targets.

## 6. Complete request flow

```text
Internet
  -> TCP port 80
  -> ALB security group
  -> ALB listener
  -> Target group
  -> HTTP port 8080
  -> Application instance
```

## 7. Dependency

The ALB resource uses:

```text
var.environment
var.vpc_id
var.public_subnets
aws_security_group.alb.id
aws_lb.main.arn
aws_lb_target_group.main.arn
```

Therefore, the VPC, public subnets, and security group must exist before the ALB module can be successfully deployed.
