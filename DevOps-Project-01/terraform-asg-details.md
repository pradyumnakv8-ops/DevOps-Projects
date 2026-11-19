# Terraform Auto Scaling Group (ASG) Resources

This document explains the EC2 launch template and Auto Scaling Group resources used by `DevOps-Project-01`, together with their configuration and behavior.

Resource location:

```text
DevOps-Project-01/infrastructure/modules/asg/main.tf
DevOps-Project-01/infrastructure/modules/asg/variables.tf
DevOps-Project-01/infrastructure/modules/asg/outputs.tf
```

## 1. Auto Scaling Architecture

```text
Launch Template
  -> Defines AMI, instance type, security groups, key pair, and startup data

Auto Scaling Group
  -> Creates instances in private subnets
  -> Maintains minimum, maximum, and desired capacity
  -> Registers instances with the ALB target group
  -> Uses ELB health checks

ALB
  -> Sends application traffic to healthy EC2 instances
```

## 2. Launch template resource

```hcl
resource "aws_launch_template" "main" {
  name_prefix   = "${var.environment}-lt"
  image_id      = "ami-0c02fb55956c7d316"
  instance_type = var.instance_type
  key_name      = var.key_name

  vpc_security_group_ids = var.security_group_ids

  user_data = base64encode(<<-EOF
    #!/bin/bash
    yum update -y
    yum install -y java-11-amazon-corretto
    yum install -y tomcat
    systemctl enable tomcat
    systemctl start tomcat
  EOF
  )

  tag_specifications {
    resource_type = "instance"
    tags = {
      Name        = "${var.environment}-web-instance"
      Environment = var.environment
    }
  }

  lifecycle {
    create_before_destroy = true
  }
}
```

### 2.1 Name prefix

```hcl
name_prefix = "${var.environment}-lt"
```

This sets the launch-template name prefix. The environment is included in the name, for example:

```text
 dev-lt
```

AWS may append additional characters to create a unique launch-template name.

### 2.2 AMI

```hcl
image_id = "ami-0c02fb55956c7d316"
```

This selects the Amazon Machine Image used to create EC2 instances. The configured value is intended for Amazon Linux 2.

AMI IDs are region-specific. The AMI must exist in the deployment region or instance creation will fail.

### 2.3 Instance type

```hcl
instance_type = var.instance_type
```

The EC2 instance type is supplied through the module input:

```hcl
variable "instance_type" {
  description = "EC2 instance type"
  type        = string
}
```

The root module supplies `var.instance_type` when calling the ASG module.

### 2.4 SSH key pair

```hcl
key_name = var.key_name
```

This associates the EC2 key pair supplied through `key_name` with each launched instance.

For SSH access to work, the key pair must:

- Exist in the deployment region.
- Be included in `var.key_name`.
- Be reachable through the private network and bastion host.
- Be permitted by the application security group.

### 2.5 Security groups

```hcl
vpc_security_group_ids = var.security_group_ids
```

This assigns one or more security groups to the EC2 instances.

The root module passes the application security group:

```hcl
security_group_ids = [module.security.app_security_group_id]
```

That security group allows:

- TCP `8080` from the ALB security group.
- TCP `22` from the bastion security group.

### 2.6 Instance startup script

```hcl
user_data = base64encode(<<-EOF
  #!/bin/bash
  yum update -y
  yum install -y java-11-amazon-corretto
  yum install -y tomcat
  systemctl enable tomcat
  systemctl start tomcat
EOF
)
```

The launch template automatically encodes this shell script in Base64. EC2 executes it when the instance starts.

The script performs these operations:

1. Runs `yum update -y`.
2. Installs Java 11 Amazon Corretto.
3. Installs Tomcat.
4. Enables Tomcat at system startup.
5. Starts Tomcat immediately.

By default, Tomcat normally listens on port `8080`.

The script installs the Java runtime and Tomcat, but it does not copy or deploy the Java application artifact.

Consequently, these additional deployment steps are still required:

- Build the application artifact.
- Copy the WAR or JAR file to the instance.
- Deploy or configure it for Tomcat or the application runtime.
- Ensure `/` returns HTTP `200` for the target health check.

### 2.7 Instance tags

```hcl
tag_specifications {
  resource_type = "instance"
  tags = {
    Name        = "${var.environment}-web-instance"
    Environment = var.environment
  }
}
```

Every instance created from the launch template receives:

- `Name = dev-web-instance`
- `Environment = dev`, when `environment = dev`

The launch template tags the EC2 resource created from the template. These tags are separate from the ASG resource tags.

### 2.8 Lifecycle behavior

```hcl
lifecycle {
  create_before_destroy = true
}
```

This lifecycle setting instructs Terraform to create a replacement launch template before destroying the old one.

This helps avoid a period in which no launch-template resource exists during replacement.

## 3. Auto Scaling Group resource

```hcl
resource "aws_autoscaling_group" "main" {
  name                = "${var.environment}-asg"
  vpc_zone_identifier = var.private_subnet_ids
  target_group_arns   = var.target_group_arns
  health_check_type   = "ELB"

  health_check_grace_period = 300

  min_size         = var.min_size
  max_size         = var.max_size
  desired_capacity = var.desired_capacity

  launch_template {
    id      = aws_launch_template.main.id
    version = "$Latest"
  }

  tag {
    key                 = "Name"
    value               = "${var.environment}-web-instance"
    propagate_at_launch = true
  }

  tag {
    key                 = "Environment"
    value               = var.environment
    propagate_at_launch = true
  }
}
```

### 3.1 ASG name

```hcl
name = "${var.environment}-asg"
```

This names the Auto Scaling Group using the environment, for example:

```text
 dev-asg
```

### 3.2 Private subnets

```hcl
vpc_zone_identifier = var.private_subnet_ids
```

This tells the ASG where to launch instances.

The root module supplies:

```hcl
private_subnet_ids = module.vpc.private_subnet_ids
```

The EC2 instances are therefore placed in private subnets rather than public subnets.

This architecture requires outbound internet access, such as a NAT gateway or equivalent, if the startup script must access package repositories or AWS services.

### 3.3 ALB target groups

```hcl
target_group_arns = var.target_group_arns
```

This associates the ASG with the supplied ALB target groups.

The root module supplies:

```hcl
target_group_arns = [module.alb.target_group_arn]
```

The ASG registers its instances with the target group. The ALB can then route traffic to healthy instances.

### 3.4 Health-check type

```hcl
health_check_type = "ELB"
```

The ASG uses load-balancer health checks instead of relying only on EC2 status checks.

A newly launched instance must satisfy the ALB target health check before it is considered healthy by the ASG.

The target group currently performs HTTP health checks against:

```text
Protocol: HTTP
Port: traffic-port
Path: /
Matcher: 200
```

An instance with an ELB health state of unhealthy may be replaced by the ASG when unhealthy replacement behavior is satisfied.

### 3.5 Health-check grace period

```hcl
health_check_grace_period = 300
```

The ASG waits 300 seconds after launching a new instance before considering ELB health-check failures when determining whether to replace it.

This grace period allows time for:

- EC2 instance startup.
- Package installation.
- Java and Tomcat startup.
- Application deployment.
- Initial application initialization.

If the application is not ready after 300 seconds, the ASG can treat it as unhealthy according to its health behavior.

### 3.6 Capacity settings

```hcl
min_size         = var.min_size
max_size         = var.max_size
desired_capacity = var.desired_capacity
```

These values control ASG capacity:

- `min_size` is the minimum number of running instances.
- `max_size` is the maximum number of running instances.
- `desired_capacity` is the target number of instances.

The ASG attempts to maintain the desired capacity, subject to its minimum and maximum limits.

Example:

```text
min_size = 1
max_size = 3
desired_capacity = 2
```

The ASG maintains two instances, never fewer than one, and never more than three.

The root module supplies these values from:

```text
var.asg_min_size
var.asg_max_size
var.asg_desired_capacity
```

### 3.7 Launch template selection

```hcl
launch_template {
  id      = aws_launch_template.main.id
  version = "$Latest"
}
```

The ASG uses:

- `aws_launch_template.main.id` as the launch-template ID.
- `$Latest` to use the newest launch-template version.

A new launch-template version or ASG configuration update can cause instances to be replaced according to Terraform and ASG behavior.

### 3.8 ASG tags

```hcl
tag {
  key                 = "Name"
  value               = "${var.environment}-web-instance"
  propagate_at_launch = true
}

tag {
  key                 = "Environment"
  value               = var.environment
  propagate_at_launch = true
}
```

These tags are propagated to EC2 instances launched by the ASG:

- `Name`
- `Environment`

`propagate_at_launch = true` makes the tags available on the instances at creation time.

## 4. ASG module variables

```hcl
variable "environment" {
  description = "Environment name"
  type        = string
}

variable "vpc_id" {
  description = "VPC ID"
  type        = string
}

variable "private_subnet_ids" {
  description = "List of private subnet IDs"
  type        = list(string)
}

variable "security_group_ids" {
  description = "List of security group IDs"
  type        = list(string)
}

variable "target_group_arns" {
  description = "List of target group ARNs"
  type        = list(string)
}

variable "instance_type" {
  description = "EC2 instance type"
  type        = string
}

variable "key_name" {
  description = "SSH key pair name"
  type        = string
}

variable "min_size" {
  description = "Minimum size of ASG"
  type        = number
}

variable "max_size" {
  description = "Maximum size of ASG"
  type        = number
}

variable "desired_capacity" {
  description = "Desired capacity of ASG"
  type        = number
}
```

These variables connect the ASG resource to the VPC, security, ALB, and root infrastructure configuration.

## 5. ASG module output

```hcl
output "asg_name" {
  description = "Auto Scaling Group name"
  value       = aws_autoscaling_group.main.name
}
```

The `asg_name` output returns the name of the created ASG.

The root monitoring module receives it:

```hcl
module "monitoring" {
  source = "./modules/monitoring"

  environment    = var.environment
  rds_instance_id = module.rds.rds_instance_id
  asg_name        = module.asg.asg_name
}
```

## 6. Root module ASG integration

```hcl
module "asg" {
  source = "./modules/asg"

  environment         = var.environment
  vpc_id              = module.vpc.vpc_id
  private_subnet_ids  = module.vpc.private_subnet_ids
  security_group_ids  = [module.security.app_security_group_id]
  target_group_arns   = [module.alb.target_group_arn]
  instance_type       = var.instance_type
  key_name            = var.key_name
  min_size            = var.asg_min_size
  max_size            = var.asg_max_size
  desired_capacity    = var.asg_desired_capacity
}
```

The root module supplies:

- VPC information.
- Private subnet IDs.
- The application security group.
- The ALB target-group ARN.
- EC2 instance settings.
- ASG capacity settings.

## 7. Resource traffic and launch flow

```text
Root configuration
  -> Launch template
  -> Auto Scaling Group
  -> EC2 instances in private subnets
  -> Application security group
  -> Registration with ALB target group
  -> ELB health checks
  -> Application traffic on port 8080
```

The application traffic path is:

```text
Internet
  -> ALB public endpoint
  -> ALB listener on port 80
  -> Target group
  -> Healthy EC2 instance on port 8080
```

## 8. Capacity and replacement behavior

The ASG maintains its desired instance count.

- If an instance is terminated, the ASG launches a replacement.
- If ELB health fails after the grace period, the instance can be replaced according to ASG health behavior.
- Scaling actions can change capacity within the minimum and maximum limits.
- The template version and configuration determine how replacements are created.

The configuration does not include scheduled scaling or CloudWatch alarm-based scaling policies, so it only provides direct Auto Scaling resource capacity without an explicit policy-based scaling rule.

## 9. Configuration findings

### Hard-coded AMI

The AMI ID is hard-coded. It should be replaced with a region-appropriate AMI or a recent Amazon Linux AMI lookup using an AWS AMI data source.

### Missing application deployment

The user data installs Java and Tomcat but does not deploy the application. It may need to copy artifacts from S3, a build pipeline, or another deployment system.

### Private-subnet availability

Instances in private subnets require a NAT gateway or another egress path for package updates and external downloads.

### Tomcat and health endpoint

Tomcat startup alone does not ensure that `/` returns HTTP `200`. The application must be deployed and configured with a healthy endpoint.

### Duplicate ASG output declaration

The ASG module currently declares `output "asg_name"` in both:

- `variables.tf`
- `outputs.tf`

One duplicate declaration must be removed before Terraform validation.

Terraform output declarations belong in `outputs.tf`, not `variables.tf`.

## 10. Validation

Run Terraform from `DevOps-Project-01/infrastructure`:

```bash
terraform fmt -recursive
terraform validate
terraform plan
```

Before apply, verify:

- The launch-template AMI exists in the deployment region.
- The EC2 key pair exists in the deployment region.
- The private subnets have outbound connectivity.
- The application security group permits traffic on port `8080` from the ALB.
- The application security group permits SSH only from the bastion where required.
- The ASG target group ARN is valid.
- Tomcat can start on port `8080`.
- The deployed application responds with HTTP `200` at `/`.
- Capacity values satisfy `min_size <= desired_capacity <= max_size`.
- The duplicate `asg_name` output declaration is removed.
