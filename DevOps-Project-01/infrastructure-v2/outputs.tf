output "vpc_id" {
  description = "ID of the VPC"
  value       = aws_vpc.main.id
}

output "availability_zones" {
  description = "Explicit Availability Zones used by the subnets"
  value       = var.availability_zones
}

output "public_subnet_ids" {
  description = "IDs of the public subnets"
  value       = aws_subnet.public[*].id
}

output "private_subnet_ids" {
  description = "IDs of the private subnets"
  value       = aws_subnet.private[*].id
}

output "alb_dns_name" {
  description = "DNS name of the public application load balancer"
  value       = aws_lb.application.dns_name
}

output "alb_arn" {
  description = "ARN of the public application load balancer"
  value       = aws_lb.application.arn
}

output "application_target_group_arn" {
  description = "ARN of the application target group"
  value       = aws_lb_target_group.application.arn
}

output "application_asg_name" {
  description = "Name of the application Auto Scaling Group"
  value       = aws_autoscaling_group.application.name
}

output "application_security_group_id" {
  description = "ID of the application instance security group"
  value       = aws_security_group.application.id
}

output "database_endpoint" {
  description = "DNS endpoint of the private MySQL database"
  value       = aws_db_instance.mysql.address
}

output "database_port" {
  description = "MySQL port"
  value       = aws_db_instance.mysql.port
}

output "database_name" {
  description = "Initial database name"
  value       = aws_db_instance.mysql.db_name
}

output "database_master_secret_arn" {
  description = "Secrets Manager ARN containing the RDS-managed master credentials"
  value       = aws_db_instance.mysql.master_user_secret[0].secret_arn
}

output "database_security_group_id" {
  description = "ID of the database security group"
  value       = aws_security_group.database.id
}
