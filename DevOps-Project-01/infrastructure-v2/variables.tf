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
  description = "Explicit Availability Zones to use for subnet placement"
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
  description = "CIDR ranges for private subnets, in the same order as availability_zones"
  type        = list(string)
  default     = ["10.20.11.0/24", "10.20.12.0/24"]

  validation {
    condition     = length(var.private_subnet_cidrs) == 2
    error_message = "Provide exactly two private subnet CIDRs."
  }
}
