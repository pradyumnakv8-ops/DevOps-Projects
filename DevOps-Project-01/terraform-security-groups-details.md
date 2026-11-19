# Terraform Security Groups: Line-by-Line Discussion

This document contains the security-group discussion for `DevOps-Project-01`.

## 1. What is a security group?

A security group is a virtual firewall attached to AWS resources such as EC2 instances, load balancers, and RDS databases.

It controls which inbound and outbound traffic is allowed for the attached resource.

Important points:

- Security groups control allowed inbound and outbound traffic.
- Security-group rules are allow-only; traffic that is not allowed is blocked automatically.
- Security groups are stateful. If inbound traffic is allowed, the response traffic is allowed automatically.
- Outbound traffic should be controlled explicitly in a hardened configuration.
- Security groups can reference another security group or a CIDR range.
- Route tables determine the network path; security groups determine whether traffic is permitted.

## 2. ALB security group

The ALB security group allows public HTTP and HTTPS traffic:

```text
Internet -> ALB security group: TCP 80/443
```

The rules are:

```text
Inbound TCP 80  from 0.0.0.0/0
Inbound TCP 443 from 0.0.0.0/0
```

Port `80` is used for HTTP traffic. Port `443` is used for HTTPS traffic when an HTTPS listener and certificate are configured.

The ALB security group also allows outbound traffic so the ALB can connect to application targets.

## 3. Application security group

The application security group allows traffic from the ALB and bastion host:

```text
ALB security group     -> Application security group: TCP 8080
Bastion security group -> Application security group: TCP 22
```

### Application traffic

The application listens on port `8080`. Only resources associated with the ALB security group should be allowed to reach this port:

```hcl
from_port       = 8080
to_port         = 8080
protocol        = "tcp"
security_groups = [aws_security_group.alb.id]
```

This means the application port is not exposed directly to the whole internet. Requests should arrive through the ALB.

### SSH administration

The application security group allows SSH on port `22` from the bastion security group:

```text
Bastion security group -> Application security group: TCP 22
```

This keeps direct SSH access to the application instances restricted to the bastion host.

The application security group also allows outbound traffic as configured in the module.

## 4. Database security group

The database security group permits MySQL traffic only from the application security group:

```text
Application security group -> Database security group: TCP 3306
```

Port `3306` is the MySQL port. The database should not allow MySQL traffic directly from the internet.

The rule uses the application security group as the source, which means only resources associated with that security group can initiate database connections:

```hcl
from_port       = 3306
to_port         = 3306
protocol        = "tcp"
security_groups = [aws_security_group.app.id]
```

The database security group also allows outbound traffic as configured in the module.

## 5. Bastion security group

The bastion security group allows inbound SSH traffic on port `22` from the CIDR blocks specified by `var.allowed_ssh_cidr_blocks`:

```text
Administrator IP or trusted network -> Bastion: TCP 22
```

The bastion then provides the controlled administration path to private application instances.

The current default value of `allowed_ssh_cidr_blocks` is:

```text
0.0.0.0/0
```

This allows SSH attempts from any IPv4 address and should not be used as the final production setting.

Restrict it to a trusted administrator IP, VPN CIDR, or another controlled network. For one fixed public IPv4 address, use a `/32` CIDR:

```text
203.0.113.10/32
```

The bastion security group allows outbound traffic as configured in the module.

## 6. Expected traffic relationships

```text
Internet -> ALB security group: TCP 80/443
ALB security group -> App security group: TCP 8080
Bastion security group -> App security group: TCP 22
App security group -> Database security group: TCP 3306
```

This creates the intended layered access model:

```text
Internet
  -> ALB
  -> Application instances
  -> Database
```

Administrative access follows a separate path:

```text
Administrator
  -> Bastion host
  -> Application instances over SSH
```

## 7. Security-group references

A security-group reference as an ingress source restricts traffic to resources associated with the referenced security group. It does not mean that the entire VPC CIDR is allowed.

For example:

```hcl
security_groups = [aws_security_group.alb.id]
```

allows traffic from resources using the ALB security group. It is more restrictive than allowing the entire VPC CIDR with `cidr_blocks`.

Security-group references are useful for expressing application relationships:

```text
ALB group -> application group -> database group
```

## 8. Security groups and route tables

Security groups and route tables perform different jobs:

| Resource | Responsibility |
| --- | --- |
| Route table | Determines where traffic is sent |
| Security group | Determines whether traffic is permitted |

A route must exist before traffic can reach its destination. A security-group rule must also allow the traffic.

For example, the ALB request flow requires both:

```text
Public subnet route table
  -> Internet Gateway

ALB security group
  -> Allows TCP 80/443

Application security group
  -> Allows TCP 8080 from the ALB security group
```

A security group cannot create a missing network route, and a route table cannot override a blocked security-group rule.

## 9. Stateful behavior

Security groups are stateful. When an allowed connection is established, response traffic is automatically permitted, even if a separate inbound rule for the response is not defined.

For example:

```text
ALB -> Application: TCP 8080
Application -> ALB: response traffic automatically allowed
```

The same behavior applies to an allowed application-to-database connection and its response.

## 10. Complete security flow

```text
Internet
  -> ALB security group: TCP 80/443
  -> Application security group: TCP 8080
  -> Application instance
  -> Database security group: TCP 3306
  -> RDS MySQL database
```

Administrative flow:

```text
Trusted administrator CIDR
  -> Bastion security group: TCP 22
  -> Application security group: TCP 22
  -> Application instance
```

## 11. Module and output usage

The security groups are created by the security module. The root configuration passes the resulting security-group IDs to other modules.

The application security group is passed to the Auto Scaling Group:

```hcl
module "asg" {
  source = "./modules/asg"

  security_group_ids = [module.security.app_security_group_id]
}
```

The database security group is passed to the RDS module:

```hcl
module "rds" {
  source = "./modules/rds"

  security_group_ids = [module.security.db_security_group_id]
}
```

The security module exports security-group IDs so other modules can use the groups without duplicating resource definitions.

## 12. Important security warning

The bastion SSH rule currently defaults to `0.0.0.0/0`. This is broad and exposes port `22` to the entire internet.

Before using the configuration in a real environment:

- Restrict `allowed_ssh_cidr_blocks` to trusted administrator IPs or VPN ranges.
- Avoid exposing application SSH directly to the internet.
- Allow application SSH only from the bastion security group.
- Allow database access only from the application security group.
- Keep public access limited to the ALB listener ports.

The intended final access model is:

```text
Public users       -> ALB on TCP 80/443
ALB                -> Application on TCP 8080
Bastion            -> Application on TCP 22
Application        -> Database on TCP 3306
```
