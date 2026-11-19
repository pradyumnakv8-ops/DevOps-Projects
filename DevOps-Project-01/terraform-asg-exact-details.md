# Complete Explanation of the ASG Terraform File

This document explains the complete behavior of the Auto Scaling Group (ASG) configuration in `infrastructure-v2/asg.tf`, including how it uses the AMI lookup, launch template, private subnets, ALB target group, health checks, tags, and CPU scaling policy.

## File being explained

[`DevOps-Project-01/infrastructure-v2/asg.tf`](https://github.com/pradyumnakv8-ops/DevOps-Projects/blob/01d8c03aa1c02fd5b658f720a2156a2bc2c9490d/DevOps-Project-01/infrastructure-v2/asg.tf)

The ASG file does not work in isolation. It refers to variables in `variables.tf`, the application security group in `security-groups.tf`, the target group in `alb.tf`, and private subnet resources in `vpc.tf`.

## 1. Complete `asg.tf` configuration

The following is the committed ASG configuration, shown for reference:

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

  # The selected AMI must already contain the Java application and its runtime,
  # because this VPC configuration currently has no NAT route for private subnets.
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
  target_group_arns    = [aws_lb_target_group.application.arn]

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

  # A target-tracking policy changes desired capacity at runtime.
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

## 2. What the file creates and reads

There are three Terraform blocks in this file:

1. `data "aws_ssm_parameter"` reads the current Amazon Linux 2023 AMI ID from AWS Systems Manager Parameter Store. It does not create an AWS resource.
2. `aws_launch_template` creates a reusable EC2 launch specification.
3. `aws_autoscaling_group` creates and maintains the application EC2 fleet.
4. `aws_autoscaling_policy` attaches automatic CPU target-tracking scaling to that fleet.

The end-to-end intention is:

```text
Terraform reads an AMI ID
  -> creates the EC2 launch template
  -> creates the application ASG in private subnets
  -> ASG launches instances from the template
  -> instances register with the ALB target group
  -> ALB health checks the application
  -> CPU target tracking adjusts group capacity
```

## 3. AMI lookup: lines 1–3

```hcl
data "aws_ssm_parameter" "amazon_linux_2023" {
  name = "/aws/service/ami-amazon-linux-latest/al2023-ami-kernel-default-x86_64"
}
```

- `data` tells Terraform to query information that already exists in AWS rather than create a resource.
- `aws_ssm_parameter` is the AWS provider data source for a Systems Manager Parameter Store parameter.
- `amazon_linux_2023` is Terraform's local name for this lookup.
- `name` identifies AWS's public parameter for the latest standard x86-64 Amazon Linux 2023 AMI.
- The parameter value is accessed later as `data.aws_ssm_parameter.amazon_linux_2023.value`.
- The public parameter resolves to an AMI for the AWS region selected by the provider.

This lookup requires the Terraform runner to have AWS credentials and permission to read the parameter. The EC2 instances do not use this data source at runtime.

## 4. Launch template: lines 5–33

```hcl
resource "aws_launch_template" "application" {
```

A launch template is the recipe AWS uses when it creates each EC2 instance in the ASG. Changing the template affects future launches; by itself, it does not guarantee that already-running instances are replaced.

### 4.1 Template name prefix

```hcl
name_prefix = "${var.project}-${var.environment}-app-"
```

Terraform builds the prefix from the project and environment variables. With the defaults, the prefix begins `java-login-app-dev-app-`. AWS/Terraform appends characters to make the name unique.

### 4.2 AMI choice

```hcl
image_id = var.application_ami_id != "" ? var.application_ami_id : data.aws_ssm_parameter.amazon_linux_2023.value
```

This is a conditional expression:

- If `application_ami_id` is set to a non-empty string, use that custom AMI.
- If it is empty, use the AMI ID returned by the SSM parameter lookup.

The default SSM image is a base operating-system image. It is not automatically an application image. The launch template contains no `user_data` block, so it does not install Java, Tomcat, or the Java application. A production-ready deployment must supply an application-ready AMI or add a separate deployment mechanism.

### 4.3 Instance size

```hcl
instance_type = var.instance_type
```

This selects the EC2 instance type. The current variable default is `t3.micro`. The choice affects CPU, memory, network capabilities, and cost. Verify that the application fits the selected instance size and that the AMI architecture is compatible.

### 4.4 Optional EC2 key pair

```hcl
key_name = var.key_name != "" ? var.key_name : null
```

- A non-empty `key_name` attaches the named EC2 key pair.
- An empty string becomes `null`, so the template does not specify a key pair.

A key pair is only one part of remote access; network routing and security-group rules must also allow the intended access. The current application security group does not open SSH.

### 4.5 Instance security group

```hcl
vpc_security_group_ids = [aws_security_group.application.id]
```

The launch template attaches the application security group to every launched instance. The square brackets make the security-group ID a list, as required by the launch-template argument.

In `security-groups.tf`, this group allows TCP traffic on `var.application_port` (default `8080`) from the ALB security group. Thus, the application port is not opened directly to every internet address by this rule.

### 4.6 EC2 metadata options

```hcl
metadata_options {
  http_endpoint = "enabled"
  http_tokens   = "required"
}
```

- `http_endpoint = "enabled"` enables the EC2 Instance Metadata Service endpoint.
- `http_tokens = "required"` requires IMDSv2 tokens for metadata requests.

This is a security setting that helps prevent unauthorized access to instance metadata. Any application or agent that needs metadata must support IMDSv2.

### 4.7 The inline comment about the AMI and NAT

```hcl
# The selected AMI must already contain the Java application and its runtime,
# because this VPC configuration currently has no NAT route for private subnets.
```

This comment records two operational requirements:

- There is no `user_data` in this template to install or deploy application software.
- The current `vpc.tf` has private route tables but no NAT gateway route, so the instances do not have configured public internet egress for downloading packages at startup.

A prebuilt AMI or a reachable private artifact/deployment service is needed unless private-subnet egress is added.

### 4.8 Launch-template instance tags

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

This applies tags to EC2 instances created from the launch template:

- `Name` provides a descriptive EC2 instance name.
- `Environment` identifies the environment such as `dev`.
- `Tier` identifies the application tier.

The ASG below also defines tags with `propagate_at_launch = true`. Those ASG tags are independently propagated to ASG-launched instances. The tag key/value pairs here intentionally match the ASG tags.

### 4.9 Launch-template replacement lifecycle

```hcl
lifecycle {
  create_before_destroy = true
}
```

When Terraform must replace the launch template, it requests creation of the replacement before destruction of the old one. This reduces the chance of a gap where no template exists.

It does not perform an instance refresh and does not itself replace running EC2 instances. If existing instances must adopt a new template version, an instance refresh or another controlled replacement operation is needed.

## 5. Auto Scaling Group: lines 35–73

```hcl
resource "aws_autoscaling_group" "application" {
```

The ASG maintains a fleet of EC2 instances based on the launch template, health status, capacity bounds, and scaling policies.

### 5.1 Group name

```hcl
name = "${var.project}-${var.environment}-application-asg"
```

This creates a name such as `java-login-app-dev-application-asg`. The name is used in the AWS console, APIs, monitoring dimensions, and by the scaling policy.

### 5.2 Minimum, maximum, and initial desired capacity

```hcl
min_size         = var.asg_min_size
max_size         = var.asg_max_size
desired_capacity = var.asg_desired_capacity
```

The current defaults are:

```text
Minimum: 2 instances
Maximum: 6 instances
Initial desired capacity: 2 instances
```

- `min_size` is the lower bound. The ASG should not scale in below this count.
- `max_size` is the upper bound. Scaling out should not exceed this count.
- `desired_capacity` is the requested starting capacity when the group is created or when Terraform manages that value.

The values must be consistent: `min_size <= desired_capacity <= max_size`. The target-tracking policy changes the running desired capacity within those bounds.

### 5.3 Private subnets and Availability Zones

```hcl
vpc_zone_identifier = aws_subnet.private[*].id
```

`aws_subnet.private` is the list of private subnets created in `vpc.tf`; `[*].id` selects each subnet ID. The current VPC configuration defines two private subnets in two Availability Zones, so AWS can place the instances across both zones.

These are private subnets; the application instances are not given public IPs by this ASG configuration. The VPC configuration currently does not provide NAT egress for these subnets.

### 5.4 Registration with the ALB target group

```hcl
target_group_arns = [aws_lb_target_group.application.arn]
```

The ASG associates launched instances with the application target group defined in `alb.tf`. AWS registers new instances and deregisters instances that leave the group.

The target group currently uses HTTP, the configured application port (default `8080`), and the configured health-check path (default `/`). The ALB forwards requests to targets that pass its health checks.

### 5.5 ELB health checks

```hcl
health_check_type = "ELB"
```

This configures the ASG to use Elastic Load Balancing health status in addition to EC2 health status. If the application target is unhealthy, the ASG can mark the instance unhealthy and replace it according to Auto Scaling behavior.

The ALB target-group health check currently checks HTTP `/` on the target's traffic port and accepts status codes `200–399`. Installing or booting Linux alone does not make an application target healthy; the application must be running and return an accepted response.

### 5.6 Launch health-check grace period

```hcl
health_check_grace_period = var.asg_health_check_grace_period
```

The default is 300 seconds. This gives a new instance time to initialize before ELB health failures can cause ASG replacement decisions.

Set the grace period long enough for the actual boot and application startup time. It does not make an unhealthy application healthy; it only delays when the ASG starts acting on the initial health results.

### 5.7 Select the launch template and version

```hcl
launch_template {
  id      = aws_launch_template.application.id
  version = aws_launch_template.application.latest_version
}
```

- `id` connects the ASG to the launch template above.
- `latest_version` tells AWS to use the newest version of that template for instances it launches.

Existing instances do not automatically change their AMI or settings when a new template version is created. Use a controlled instance refresh or replacement process when existing instances need the new configuration.

### 5.8 ASG tags and propagation

Each block has a `key`, `value`, and `propagate_at_launch = true`:

```hcl
tag {
  key                 = "Name"
  value               = "${var.project}-${var.environment}-app-instance"
  propagate_at_launch = true
}
```

This propagates the `Name` tag to instances at launch.

```hcl
tag {
  key                 = "Environment"
  value               = var.environment
  propagate_at_launch = true
}
```

This propagates the environment label.

```hcl
tag {
  key                 = "Tier"
  value               = "application"
  propagate_at_launch = true
}
```

This propagates the application tier label.

These tags aid filtering, billing, inventory, and operations. The ASG resource tags themselves and the EC2 instance tags are separate objects; `propagate_at_launch` copies the specified tags onto newly launched instances.

### 5.9 Ignore runtime desired-capacity changes

```hcl
lifecycle {
  ignore_changes = [desired_capacity]
}
```

Without this lifecycle rule, Terraform can see that the ASG's live desired capacity differs from the configuration value and attempt to restore the configured value on a later plan/apply.

Target tracking changes desired capacity at runtime. Ignoring changes to this field lets the scaling policy manage its live value instead of Terraform resetting it on every apply. The configured minimum and maximum remain in effect.

Because Terraform ignores this attribute, changing the `asg_desired_capacity` input may not have the expected effect on an existing ASG. Make intentional capacity changes through a planned operational change and review the plan carefully.

## 6. CPU target-tracking scaling policy: lines 75–90

```hcl
resource "aws_autoscaling_policy" "application_cpu_target_tracking" {
```

This policy dynamically adjusts the application ASG to keep a predefined CPU metric near a target.

### 6.1 Policy name and ASG association

```hcl
name                   = "${var.project}-${var.environment}-app-cpu-target"
autoscaling_group_name = aws_autoscaling_group.application.name
```

The first line creates an environment-specific policy name, for example `java-login-app-dev-app-cpu-target`. The second attaches the policy to the application ASG.

### 6.2 Policy type

```hcl
policy_type = "TargetTrackingScaling"
```

Target tracking is a managed scaling policy. AWS creates and manages the CloudWatch alarms needed to adjust capacity toward its target. This is separate from an ordinary CloudWatch alarm that has user-supplied `alarm_actions`.

### 6.3 Instance warm-up

```hcl
estimated_instance_warmup = var.asg_instance_warmup_seconds
```

The current default is 300 seconds. This tells target tracking how long a newly launched instance is expected to take before it contributes fully to scaling decisions.

Warm-up and `health_check_grace_period` are different settings:

- The ASG health-check grace period delays acting on initial load-balancer health results.
- The scaling-policy warm-up informs scaling calculations about newly added capacity.

Both should be set with actual boot and application initialization time in mind.

### 6.4 Target value

```hcl
target_value = var.asg_cpu_target_value
```

The default target is 60 percent average CPU utilization across the ASG. It is a goal, not a hard maximum or an instantaneous trigger. AWS adjusts capacity over time to try to keep the metric near the target.

If average CPU demand is high, AWS can add instances, subject to `max_size`. When CPU demand is low, the policy may remove instances, subject to `min_size` and AWS's scale-in behavior.

### 6.5 Permit scale-in

```hcl
disable_scale_in = false
```

This allows target tracking to scale in as well as scale out. Setting it to `true` would disable scale-in for this policy. With scale-in enabled, the ASG still cannot go below its configured minimum.

### 6.6 CPU metric

```hcl
predefined_metric_specification {
  predefined_metric_type = "ASGAverageCPUUtilization"
}
```

This chooses the AWS predefined metric for average CPU utilization across instances in this ASG. Target tracking uses that metric and its target value to calculate capacity adjustments.

CPU is only one possible measure of application demand. If the application is constrained by request count, latency, memory, or queue depth, CPU target tracking may not alone represent its capacity needs.

## 7. Values supplied by `variables.tf`

The ASG file references these input variables:

| Variable | Current default or source | Purpose |
| --- | --- | --- |
| `project` | `java-login-app` | Prefix for resource names and tags |
| `environment` | `dev` | Environment suffix and tag |
| `application_ami_id` | Empty string | Optional custom application AMI; empty selects the SSM AMI |
| `instance_type` | `t3.micro` | EC2 instance type |
| `key_name` | Empty string | Optional EC2 key pair |
| `application_port` | `8080` | Application port used by SG and target group |
| `health_check_path` | `/` | Target-group health-check path |
| `asg_min_size` | `2` | ASG lower capacity bound |
| `asg_max_size` | `6` | ASG upper capacity bound |
| `asg_desired_capacity` | `2` | Initial desired instance count |
| `asg_health_check_grace_period` | `300` seconds | Grace time for new instances' ELB health |
| `asg_cpu_target_value` | `60` percent | Target-tracking CPU target |
| `asg_instance_warmup_seconds` | `300` seconds | Expected scaling warm-up time |

## 8. Relationship to the ALB and security groups

The supporting resources are in `alb.tf` and `security-groups.tf`:

1. The public ALB accepts HTTP on port 80.
2. Its listener forwards requests to the application target group.
3. The target group uses HTTP on port 8080 and checks `/`.
4. The application security group allows port 8080 from the ALB security group.
5. The ASG registers its EC2 instances with that target group.
6. Healthy instances receive traffic; unhealthy targets are excluded from normal traffic and ELB health can inform ASG replacement.

Traffic path:

```text
Internet client
  -> public ALB, TCP 80
  -> ALB listener
  -> application target group, HTTP 8080
  -> application security group
  -> healthy EC2 instance in a private subnet
```

## 9. What happens when Terraform applies the configuration

At a high level, Terraform:

1. Reads the latest Amazon Linux 2023 AMI parameter unless a custom AMI ID is supplied.
2. Creates or updates the launch template.
3. Creates or updates the ASG in the private subnet IDs.
4. Requests the initial desired instance count, bounded by the minimum and maximum.
5. AWS launches instances using the launch template and attaches the application security group.
6. The ASG registers the instances with the ALB target group.
7. The ALB checks the configured health path and port.
8. The ASG uses ELB health status after the grace period when evaluating instance health.
9. The target-tracking policy monitors average ASG CPU and adjusts desired capacity toward the target, subject to the capacity bounds.

Terraform describes and manages infrastructure; it does not itself run inside the EC2 instances or deploy the application with this file.

## 10. Critical operational limitations

### The default AMI does not include the application

The fallback SSM parameter supplies a base Amazon Linux 2023 image. The launch template has no user data, so it does not install Java or Tomcat, fetch a WAR/JAR, configure database connectivity, or start the application. Unless a custom application AMI is supplied, the instance is unlikely to pass the application health check.

### Private subnets have no configured NAT route

The current VPC file creates private route tables but does not define NAT gateways or default routes through NAT. Instances therefore do not have configured internet egress to download packages from public repositories. A prebuilt AMI, VPC endpoints for suitable AWS services, or a separately configured egress path is needed for deployment dependencies.

### The current design is one application tier

This ASG file creates a Tomcat/application ASG behind the existing public ALB. It does not create the README's separate Nginx frontend ASG, public NLB, or internal NLB.

### No explicit instance refresh

Selecting `latest_version` makes future launches use the latest launch-template version. It does not automatically roll existing instances. Plan a controlled instance refresh when the AMI or launch-template settings change.

### CPU target does not guarantee application performance

CPU target tracking scales based on average CPU. It does not directly monitor response latency, request count, memory, or database saturation. Load test the application and choose metrics and capacity bounds appropriate to the workload.

## 11. Validation checklist

Before deployment, verify:

- A custom `application_ami_id` contains the Java runtime, deployed application, and required startup configuration, or another deployment process exists.
- The application responds on port `8080` and the configured health path returns an accepted HTTP status (`200–399`).
- Private-subnet network connectivity supports the chosen image and deployment method.
- `application_port` matches the application and target-group port.
- `min_size <= desired_capacity <= max_size`.
- The AMI exists in the configured region and has the architecture expected by the instance type.
- The key pair exists in the configured region if `key_name` is supplied.
- Database credentials and other secrets are delivered securely, not embedded in source or user data.
- The plan is reviewed for instance replacement, capacity changes, and cost before applying.

Run from `DevOps-Project-01/infrastructure-v2`:

```bash
terraform fmt -check -recursive
terraform validate
terraform plan
```
