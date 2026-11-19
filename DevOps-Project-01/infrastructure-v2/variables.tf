variable "project" {
  description = "Project name used in AWS resource names"
  type        = string
  default     = "java-login-app"
}

variable "environment" {
  description = "Environment name, such as dev or prod"
  type        = string
  default     = "dev"
}

variable "aws_region" {
  description = "AWS region for the infrastructure"
  type        = string
  default     = "ap-south-1"
}

variable "vpc_cidr" {
  description = "IPv4 CIDR range for the VPC"
  type        = string
  default     = "10.20.0.0/16"
}

variable "availability_zones" {
  description = "Two Availability Zones used for subnet placement"
  type        = list(string)
  default     = ["ap-south-1a", "ap-south-1b"]

  validation {
    condition     = length(var.availability_zones) == 2
    error_message = "Provide exactly two Availability Zones, one for each subnet pair."
  }
}

variable "public_subnet_cidrs" {
  description = "CIDR ranges for the public subnets, in the same order as availability_zones"
  type        = list(string)
  default     = ["10.20.1.0/24", "10.20.2.0/24"]

  validation {
    condition     = length(var.public_subnet_cidrs) == 2
    error_message = "Provide exactly two public subnet CIDRs."
  }
}

variable "private_subnet_cidrs" {
  description = "CIDR ranges for the private subnets, in the same order as availability_zones"
  type        = list(string)
  default     = ["10.20.11.0/24", "10.20.12.0/24"]

  validation {
    condition     = length(var.private_subnet_cidrs) == 2
    error_message = "Provide exactly two private subnet CIDRs."
  }
}

variable "application_ami_id" {
  description = "Optional AMI containing the deployed Java application; empty uses the latest Amazon Linux 2023 AMI"
  type        = string
  default     = ""
}

variable "instance_type" {
  description = "EC2 instance type for the application ASG"
  type        = string
  default     = "t3.micro"
}

variable "key_name" {
  description = "Optional EC2 key pair name; leave empty to disable key-pair login"
  type        = string
  default     = ""
}

variable "application_port" {
  description = "Port on which the application listens"
  type        = number
  default     = 8080
}

variable "health_check_path" {
  description = "HTTP path checked by the ALB target group"
  type        = string
  default     = "/"
}

variable "asg_min_size" {
  description = "Minimum number of application instances"
  type        = number
  default     = 2
}

variable "asg_max_size" {
  description = "Maximum number of application instances"
  type        = number
  default     = 6
}

variable "asg_desired_capacity" {
  description = "Initial desired number of application instances"
  type        = number
  default     = 2
}

variable "asg_health_check_grace_period" {
  description = "Seconds after launch before ELB health failures can trigger replacement"
  type        = number
  default     = 300
}

variable "asg_cpu_target_value" {
  description = "Target average CPU utilization percentage for ASG target tracking"
  type        = number
  default     = 60

  validation {
    condition     = var.asg_cpu_target_value > 0 && var.asg_cpu_target_value < 100
    error_message = "asg_cpu_target_value must be greater than 0 and less than 100."
  }
}

variable "asg_instance_warmup_seconds" {
  description = "Seconds a new instance warms up before its metrics affect scaling"
  type        = number
  default     = 300
}
