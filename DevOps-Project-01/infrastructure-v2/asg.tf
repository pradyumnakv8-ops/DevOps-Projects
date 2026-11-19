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
