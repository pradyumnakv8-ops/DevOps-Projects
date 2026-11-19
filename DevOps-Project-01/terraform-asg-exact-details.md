# Terraform Auto Scaling Group — Exact Configuration and Line-by-Line Explanation

This document is based on the exact committed configuration in:

```text
DevOps-Project-01/infrastructure-v2/asg.tf
```

Repository commit: `01d8c03aa1c02fd5b658f720a2156a2bc2c9490d`

## 1. Architecture context

The infrastructure creates a public Application Load Balancer in the public subnets and an application Auto Scaling Group in the private subnets:

```text
Internet
  -> Application Load Balancer
  -> Application target group
  -> Private application EC2 instances
  -> Application security group
```

The application ASG uses two private subnets across two Availability Zones. It is attached to the application target group, and EC2 instances are created from the application launch template.

The complete ASG configuration is:

```hcl
 data "aws_ssm_parameter" "amazon_linux_2023" {
  name = "/aws/service/ami-amazon-linux-latest/al2023-ami-kernel-default-x86_64"
}

resource "aws_launch_template" "application" {
  name_prefix   = "${var.project}-${var.environment}-app-"
  image_id      = var.application_ami_id != "" ? var.application_ami_id : data.aws_ssm_parameter.amazon_linux_2023.value
  instance_type = var.instance_type
  key_name      = var.key_name != "" ? var.key_name : null

  vpc_security_group_ids = [aws_security_group.application.id]

  metadata_options {
    http_endpoint = "enabled"
    http_tokens   = "required"
  }

  tag_specifications {
    resource_type = "instance"

    tags = {
      Name        = "${var.project}-${var.environment}-app-instance"
      Environment = var.environment
      Tier        = "application"
    }
  }

  lifecycle {
    create_before_destroy = true
  }
}

resource "aws_autoscaling_group" "application" {
  name                = "${var.project}-${var.environment}-application-asg"
  min_size            = var.asg_min_size
  max_size            = var.asg_max_size
  desired_capacity    = var.asg_desired_capacity
  vpc_zone_identifier = aws_subnet.private[*].id
  target_group_arns   = [aws_lb_target_group.application.arn]

  health_check_type         = "ELB"
  health_check_grace_period = var.asg_health_check_grace_period

  launch_template {
    id      = aws_launch_template.application.id
    version = aws_launch_template.application.latest_version
  }

  tag {
    key                 = "Name"
    value               = "${var.project}-${var.environment}-app-instance"
    propagate_at_launch = true
  }

  tag {
    key                 = "Environment"
    value               = var.environment
    propagate_at_launch = true
  }

  tag {
    key                 = "Tier"
    value               = "application"
    propagate_at_launch = true
  }

  lifecycle {
    ignore_changes = [desired_capacity]
  }
}

resource "aws_autoscaling_policy" "application_cpu_target_tracking" {
  name                   = "${var.project}-${var.environment}-app-cpu-target"
  autoscaling_group_name = aws_autoscaling_group.application.name
  policy_type            = "TargetTrackingScaling"

  estimated_instance_warmup = var.asg_instance_warmup_seconds

  target_tracking_configuration {
    target_value     = var.asg_cpu_target_value
    disable_scale_in = false

    predefined_metric_specification {
      predefined_metric_type = "ASGAverageCPUUtilization"
    }
  }
}
```

## 2. AMI data source: lines 1–3

```hcl
data "aws_ssm_parameter" "amazon_linux_2023" {
  name = "/aws/service/ami-amazon-linux-latest/al2023-ami-kernel-default-x86_64"
}
```

A Terraform `data` block reads existing AWS information. It does not create or modify an AWS resource.

The SSM parameter name is the AWS public parameter for the latest Amazon Linux 2023 x86-64 AMI in the configured region.

The resolved AMI value is obtained through:

```hcl
data.aws_ssm_parameter.amazon_linux_2023.value
```

This lookup is used only when `var.application_ami_id` is an empty string.

The fallback AMI is a base operating-system AMI. This configuration does not install Java or Tomcat and does not deploy the application into newly launched instances.

## 3. Launch template resource: lines 5–33

```hcl
resource "aws_launch_template" "application" {
```

This creates an EC2 Launch Template named by the supplied prefix. A launch template is a reusable specification for new EC2 instances.

### Name prefix: line 6

```hcl
name_prefix = "${var.project}-${var.environment}-app-"
```

Terraform creates a launch-template name beginning with the project and environment:

```text
java-login-app-dev-app-
```

AWS adds a unique suffix or generated portion to make the complete launch-template name unique.

### AMI selection: line 7

```hcl
image_id = var.application_ami_id != "" ? var.application_ami_id : data.aws_ssm_parameter.amazon_linux_2023.value
```

This conditional expression works as follows:

- If `application_ami_id` is not empty, use that custom AMI.
- If `application_ami_id` is empty, use the latest Amazon Linux 2023 AMI from SSM.

A custom AMI is the preferred option for an application-ready image. The AMI must contain the application, Java runtime, and any required startup configuration.

### Instance type: line 8

```hcl
instance_type = var.instance_type
```

The selected EC2 instance type is supplied by `var.instance_type`. It defaults to `t3.micro`.

### EC2 key pair: line 9

```hcl
key_name = var.key_name != "" ? var.key_name : null
```

- If `key_name` is not empty, EC2 attaches that key pair to the instance.
- If `key_name` is empty, the launch template sends `null`, so no key pair is configured.

The key pair alone does not permit SSH access. SSH/network/security configuration must also permit it.

### Security groups: line 11

```hcl
vpc_security_group_ids = [aws_security_group.application.id]
```

Each launched instance receives the application security group. The referenced security group is declared in `security-groups.tf`.

It allows application traffic on `var.application_port`, default `8080`, when the source is the ALB security group.

### IMDS settings: lines 13–16

```hcl
metadata_options {
  http_endpoint = "enabled"
  http_tokens   = "required"
}
```

- `http_endpoint = "enabled"` enables access to instance metadata.
- `http_tokens = "required"` requires IMDSv2 session tokens.

This prevents unauthorized use of the basic metadata endpoint without a token. An application or agent that uses instance metadata must support IMDSv2.

### Instance tags: lines 20–28

```hcl
tag_specifications {
  resource_type = "instance"

  tags = {
    Name        = "${var.project}-${var.environment}-app-instance"
    Environment = var.environment
    Tier        = "application"
  }
}
```

The launch template assigns these tags to EC2 instances created from it:

- `Name`: identifies the application instance.
- `Environment`: distinguishes environments such as dev or prod.
- `Tier`: identifies the instance as belonging to the application tier.

Tagging launch-template instances and tagging ASG-launched instances are separate mechanisms. This block applies launch-template instance tags. The ASG also contains separate propagated tags.

### Lifecycle behavior: lines 30–32

```hcl
lifecycle {
  create_before_destroy = true
}
```

When Terraform replaces the launch template, it creates the replacement first. It then destroys the old launch template.

This setting does not immediately replace every existing EC2 instance. Existing instances continue running until a replacement process, instance refresh, ASG update, or manual termination occurs.

## 4. ASG resource: lines 35–73

```hcl
resource "aws_autoscaling_group" "application" {
```

This resource creates the application Auto Scaling Group.

### ASG name: line 36

```hcl
name = "${var.project}-${var.environment}-application-asg"
```

For example, with the default project and environment, the ASG name is:

```text
java-login-app-dev-application-asg
```

The ASG name is used for CloudWatch dimensions and operational identification.

### Capacity values: lines 37–39

```hcl
min_size         = var.asg_min_size
max_size         = var.asg_max_size
desired_capacity = var.asg_desired_capacity
```

The defaults are:

```text
min_size         = 2
max_size         = 6
desired_capacity = 2
```

The ASG operates with these rules:

- It should maintain at least two instances.
- It should not exceed six instances.
- It initially starts with two instances.
- CPU target tracking can change the current desired capacity within the minimum and maximum.

The capacity relationship must satisfy:

```text
min_size <= desired_capacity <= max_size
```

The ASG can replace failed instances even when the current desired capacity is not enough to satisfy the minimum and maximum due to a launch failure or termination event.

### Private subnet placement: line 40

```hcl
vpc_zone_identifier = aws_subnet.private[*].id
```

The `[*]` splat expression converts the private-subnet resource list into a list of subnet IDs.

The ASG launches instances in both private subnets. The VPC configuration uses two private CIDRs in separate Availability Zones:

```text
10.20.11.0/24
10.20.12.0/24
```

This provides Multi-AZ instance placement. Instances do not receive public addresses through the private subnet configuration.

### ALB target group: line 41

```hcl
target_group_arns = [aws_lb_target_group.application.arn]
```

This tells the ASG to register every instance it creates with the application target group.

The target group is defined in `alb.tf` as an instance target group for HTTP port `8080`.

The ASG registration flow is:

```text
Launch instance
  -> Register instance with target group
  -> ALB performs health check
  -> Healthy instance receives traffic
```

### Health-check type: line 43

```hcl
health_check_type = "ELB"
```

This makes the ASG consider target health from the load balancer, not only EC2 status checks.

If an instance is running but the application fails the target health check, it is unhealthy from the ASG’s load-balancer health perspective. The ASG can replace it according to ASG replacement behavior.

### Health-check grace period: line 44

```hcl
health_check_grace_period = var.asg_health_check_grace_period
```

The default grace period is 300 seconds.

During this period, newly launched instances are given time to initialize. ELB health-check failures are not used to terminate a just-launched instance until the grace period has elapsed.

The grace period should cover:

- EC2 boot time.
- Java and Tomcat startup.
- Application deployment.
- Application database initialization.
- First successful application health response.

If startup takes longer than the grace period, the ASG can assess the instance too early and replace it.

## 5. Launch-template selection: lines 46–49

```hcl
launch_template {
  id      = aws_launch_template.application.id
  version = aws_launch_template.application.latest_version
}
```

The ASG uses:

- `aws_launch_template.application.id` as the launch-template ID.
- `.latest_version` as the launch-template version.

A launch-template change creates a newer version. The ASG may use the latest version for future launches.

Existing running instances are not automatically reconfigured. An instance refresh or replacement is needed to guarantee that existing instances use the new launch-template version.

## 6. ASG propagated tags: lines 51–67

### Name tag

```hcl
tag {
  key                 = "Name"
  value               = "${var.project}-${var.environment}-app-instance"
  propagate_at_launch = true
}
```

The ASG applies `Name` to instances when they launch.

### Environment tag

```hcl
tag {
  key                 = "Environment"
  value               = var.environment
  propagate_at_launch = true
}
```

This identifies the deployment environment.

### Tier tag

```hcl
tag {
  key                 = "Tier"
  value               = "application"
  propagate_at_launch = true
}
```

This identifies the instance as part of the application tier.

`propagate_at_launch = true` means these tags are copied onto instances when the ASG creates them.

## 7. Desired-capacity lifecycle behavior: lines 69–72

```hcl
lifecycle {
  ignore_changes = [desired_capacity]
}
```

Terraform normally detects and corrects configuration drift for `desired_capacity`.

Here, Terraform ignores subsequent changes to it after creation. This allows the CPU target-tracking policy to update the ASG’s runtime desired capacity without Terraform resetting it to the original Terraform value during a later apply.

Changing `var.asg_desired_capacity` may still update initial state or resource behavior in some lifecycle cases, but scaling operations remain responsible for runtime capacity until another explicit ASG configuration change is applied.

This should not be used to increase or lower `desired_capacity` beyond `min_size` or `max_size`.

## 8. CPU target-tracking policy: lines 75–90

```hcl
resource "aws_autoscaling_policy" "application_cpu_target_tracking" {
```

This creates a CPU-based target-tracking scaling policy.

### Policy name: line 76

```hcl
name = "${var.project}-${var.environment}-app-cpu-target"
```

The policy name uses the project and environment.

### ASG association: line 77

```hcl
autoscaling_group_name = aws_autoscaling_group.application.name
```

The policy is attached to the application ASG.

### Policy type: line 78

```hcl
policy_type = "TargetTrackingScaling"
```

Target tracking automatically creates and manages the CloudWatch alarms needed to adjust ASG capacity toward a metric target.

It is different from the CloudWatch alarm resource: target tracking directly controls desired ASG capacity and is not a separate alarm with `alarm_actions`.

### Instance warm-up: line 80

```hcl
estimated_instance_warmup = var.asg_instance_warmup_seconds
```

The default is 300 seconds.

During warm-up, the policy estimates that a new instance is not fully ready. Its capacity and metric behavior should not immediately be used as if the instance were fully productive.

Warm-up should cover application startup. It is separate from `health_check_grace_period`, but both concern launch readiness.

### Target-tracking block: line 82

```hcl
target_tracking_configuration {
```

This block defines the metric, target, and scale-in behavior.

### Target CPU utilization: line 83

```hcl
target_value = var.asg_cpu_target_value
```

The default is `60`. This means AWS attempts to keep the ASG’s average CPU utilization near 60%.

This is a percentage target, not a hard alarm threshold:

- Above the target for enough time, AWS can increase desired capacity.
- Below the target and able to scale in safely, AWS can reduce desired capacity.
- Scaling remains constrained by `min_size` and `max_size`.

Validation allows only values greater than `0` and less than `100`.

### Scale-in setting: line 84

```hcl
disable_scale_in = false
```

Scale-in is enabled. AWS may terminate instances to reduce capacity when CPU utilization is sufficiently below the target.

Scale-in is also constrained by the ASG’s minimum size and AWS target-tracking safety behavior.

### Predefined CPU metric: lines 86–88

```hcl
predefined_metric_specification {
  predefined_metric_type = "ASGAverageCPUUtilization"
}
```

This selects the predefined average CPU metric across the ASG:

```text
Average CPU utilization of all application ASG instances
```

AWS CloudWatch calculates the metric. Target tracking creates the needed alarms and adjusts desired capacity toward 60% average CPU utilization.

## 9. Default ASG settings

The applicable variable defaults are:

```text
application_ami_id              = ""
instance_type                   = "t3.micro"
key_name                        = ""
application_port                = 8080
health_check_path               = "/"
asg_min_size                    = 2
asg_max_size                    = 6
asg_desired_capacity            = 2
asg_health_check_grace_period   = 300
asg_cpu_target_value            = 60
asg_instance_warmup_seconds     = 300
```

The ASG therefore begins with two application instances and can scale to six.

## 10. Security relationship

The application instance security group allows incoming application traffic only from the ALB security group:

```hcl
from_port       = var.application_port
to_port         = var.application_port
protocol        = "tcp"
security_groups = [aws_security_group.alb.id]
```

The public ALB security group accepts HTTP traffic from `0.0.0.0/0` on port `80`.

The resulting request flow is:

```text
Internet user
  -> ALB security group: TCP 80
  -> Public ALB
  -> HTTP listener: port 80
  -> Target group: HTTP port 8080
  -> Application security group
  -> Healthy private EC2 instance
```

## 11. ALB health-check relationship

The target group performs HTTP health checks with:

```text
Protocol             = HTTP
Port                 = traffic-port
Port value           = 8080
Path                 = /
Matcher              = 200-399
Interval             = 30 seconds
Timeout              = 5 seconds
Healthy threshold    = 2
Unhealthy threshold  = 3
```

A target is healthy after two successful checks. It becomes unhealthy after three failed checks.

Because the ASG uses `health_check_type = "ELB"`, the ALB target health is relevant to ASG instance health and replacement behavior.

## 12. Complete startup and scaling flow

```text
Terraform
  -> Creates launch template
  -> Creates ASG
  -> ASG launches instances in private subnets
  -> Launch template attaches application security group
  -> ASG registers instances with ALB target group
  -> ALB checks application health
  -> ALB sends traffic to healthy instances
  -> CPU target tracking observes ASGAverageCPUUtilization
  -> Policy increases or decreases desired capacity
  -> Capacity remains between minimum and maximum
```

## 13. Deployment requirement

The current launch template has no `user_data` block.

Therefore, it does not:

- Install Java.
- Install Tomcat.
- Deploy a WAR or JAR.
- Configure database or cache connections.
- Create an application health endpoint.

New instances using the fallback AMI do not automatically become healthy application targets.

Before production use, provide either:

- A custom application AMI containing Java, Tomcat, and the deployed application.
- Or secure deployment automation such as user data that retrieves a tested application artifact and starts it.

## 14. Private-network requirement

The current VPC file does not configure NAT gateways or private egress routes.

The private application instances therefore have no confirmed route for package repositories or public artifact repositories.

An application-ready AMI or private artifact service is needed. For internet software updates and artifact downloads, add or use a NAT gateway or another egress mechanism.

## 15. Scaling behavior

With a 60% CPU target and default capacities:

```text
Minimum instances: 2
Initial instances: 2
Maximum instances: 6
CPU target: 60%
Scale-in: enabled
Warm-up: 300 seconds
```

Example behavior:

- If average CPU rises above the target, target tracking increases capacity toward enough instances to reduce average CPU toward 60%.
- If average CPU falls below the target, target tracking can reduce capacity toward the target, subject to scale-in checks.
- It never scales below two instances.
- It never scales above six instances.
- New instances receive time to warm up before their metrics are fully considered.

## 16. Limitations and validation items

Before applying this configuration:

- Set `application_ami_id` to an AMI that contains the application and runtime, or add deployment user data.
- Ensure `/` returns an accepted HTTP `200–399` response on port `8080`.
- Verify private subnets have the required outbound connectivity.
- Configure database credentials and application configuration securely.
- Confirm `min_size <= desired_capacity <= max_size`.
- Confirm `application_port` matches the application listener.
- Confirm `key_name` exists in the deployment region or leave it empty.
- Confirm the AMI architecture matches `t3.micro` and the AWS region.
- Verify the launch-template image, instance type, and security group with `terraform plan`.

Run validation from `DevOps-Project-01/infrastructure-v2`:

```bash
terraform fmt -check -recursive
terraform validate
terraform plan
```
