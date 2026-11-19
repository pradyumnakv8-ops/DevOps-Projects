# Terraform Routing: VPC, Subnets, Routes, and Route Tables

This guide explains the VPC and subnet configuration for `DevOps-Project-01`, followed by the route, route-table, and subnet-association behavior. The example uses explicit Availability Zone names in `ap-south-1`; it does not use a Terraform availability-zone data source.

## 1. What is a VPC?

A **Virtual Private Cloud (VPC)** is a logically isolated network in AWS. It defines the overall IP address range and contains subnets, route tables, and AWS resources such as EC2 instances and RDS databases.

This project uses:

```text
Region:    ap-south-1
VPC CIDR: 10.20.0.0/16
```

The VPC CIDR must not overlap with networks you may later connect through VPN or VPC peering. DNS support and DNS hostnames are enabled so instances and AWS services can use DNS inside the VPC.

## 2. Availability Zones and explicit placement

An Availability Zone (AZ) is a separate location within an AWS Region. We place a public subnet and a private subnet in each of two selected AZs.

This configuration explicitly sets:

```hcl
availability_zones = ["ap-south-1a", "ap-south-1b"]
```

No `aws_availability_zones` data source is used. This gives you direct control over the AZ names in the configuration. Confirm the selected names are available to your AWS account and region before applying. AZ names can map to different physical AZs in different AWS accounts; AZ IDs are useful when consistent physical placement across accounts matters.

## 3. Subnet plan

The VPC is divided into four non-overlapping `/24` subnets:

| Subnet | CIDR | AZ | Intended use |
| --- | --- | --- | --- |
| Public 1 | `10.20.1.0/24` | `ap-south-1a` | Internet-facing ALB or NAT Gateway |
| Public 2 | `10.20.2.0/24` | `ap-south-1b` | Internet-facing ALB or NAT Gateway |
| Private 1 | `10.20.11.0/24` | `ap-south-1a` | Application instances and/or RDS |
| Private 2 | `10.20.12.0/24` | `ap-south-1b` | Application instances and/or RDS |

Every subnet CIDR must be contained in the VPC CIDR and must not overlap another subnet.

## 4. Input variables

The VPC configuration is in `DevOps-Project-01/infrastructure-v2/variables.tf`:

```hcl
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
```

The list order determines placement: item `0` uses the first AZ, and item `1` uses the second AZ. The validations require two items in each list so the subnet indexes line up with the AZ list.

## 5. VPC, subnets, and routing code

The working configuration is in `DevOps-Project-01/infrastructure-v2/vpc.tf`:

```hcl
resource "aws_vpc" "main" {
  cidr_block           = var.vpc_cidr
  enable_dns_support   = true
  enable_dns_hostnames = true

  tags = {
    Name = "${var.project}-${var.environment}-vpc"
  }
}

resource "aws_internet_gateway" "main" {
  vpc_id = aws_vpc.main.id

  tags = {
    Name = "${var.project}-${var.environment}-igw"
  }
}

resource "aws_subnet" "public" {
  count = length(var.public_subnet_cidrs)

  vpc_id                  = aws_vpc.main.id
  cidr_block              = var.public_subnet_cidrs[count.index]
  availability_zone       = var.availability_zones[count.index]
  map_public_ip_on_launch = true

  tags = {
    Name = "${var.project}-${var.environment}-public-${count.index + 1}"
    Tier = "public"
  }
}

resource "aws_subnet" "private" {
  count = length(var.private_subnet_cidrs)

  vpc_id            = aws_vpc.main.id
  cidr_block        = var.private_subnet_cidrs[count.index]
  availability_zone = var.availability_zones[count.index]

  tags = {
    Name = "${var.project}-${var.environment}-private-${count.index + 1}"
    Tier = "private"
  }
}

resource "aws_route_table" "public" {
  vpc_id = aws_vpc.main.id

  tags = {
    Name = "${var.project}-${var.environment}-public-rt"
  }
}

resource "aws_route" "public_internet" {
  route_table_id         = aws_route_table.public.id
  destination_cidr_block = "0.0.0.0/0"
  gateway_id             = aws_internet_gateway.main.id
}

resource "aws_route_table_association" "public" {
  count = length(aws_subnet.public)

  subnet_id      = aws_subnet.public[count.index].id
  route_table_id = aws_route_table.public.id
}

resource "aws_route_table" "private" {
  count = length(aws_subnet.private)

  vpc_id = aws_vpc.main.id

  tags = {
    Name = "${var.project}-${var.environment}-private-rt-${count.index + 1}"
  }
}

resource "aws_route_table_association" "private" {
  count = length(aws_subnet.private)

  subnet_id      = aws_subnet.private[count.index].id
  route_table_id = aws_route_table.private[count.index].id
}
```

### VPC resource

`aws_vpc.main` creates the VPC. It uses `var.vpc_cidr`, enables DNS support and hostnames, and adds a descriptive tag.

### Internet Gateway

`aws_internet_gateway.main` attaches an Internet Gateway to the VPC. The gateway alone does not make subnets public; a route table must direct traffic to it.

### Public subnets

`aws_subnet.public` creates one subnet per entry in `public_subnet_cidrs`. For each subnet:

- `vpc_id` places it in the new VPC.
- `cidr_block` selects its IP range.
- `availability_zone` selects its explicit AZ using the same index.
- `map_public_ip_on_launch = true` assigns public IPv4 addresses by default to EC2 instances launched in that subnet.
- Tags label it as public.

A public IP alone does not provide internet reachability. The public route table, Internet Gateway, and security rules are also relevant.

### Private subnets

`aws_subnet.private` creates one subnet per entry in `private_subnet_cidrs`, in the matching AZ. It does not enable automatic public IP assignment. These subnets are intended for application instances and RDS.

### `count` and `count.index`

`count` creates repeated resources. With two subnet CIDRs, Terraform creates two subnet resources. `count.index` is zero-based:

```text
index 0: first CIDR, ap-south-1a
index 1: second CIDR, ap-south-1b
```

The public and private subnet lists must remain the same length as the AZ list.

## 6. Route, route table, and association

A **route** says where traffic for a destination range should go. A **route table** contains routes. A **route-table association** selects which route table a subnet uses.

These are related but different concepts:

| Item | Responsibility |
| --- | --- |
| Route | Destination CIDR and next hop |
| Route table | Collection of routes used by associated subnets |
| Route-table association | Connects one subnet to one route table |

### VPC local route

AWS automatically creates a local route for the VPC CIDR, such as:

```text
10.20.0.0/16 -> local
```

It allows resources in different VPC subnets to communicate at the network-routing layer. Security groups still need to permit the traffic.

### Public route table and route

`aws_route_table.public` creates a table. `aws_route.public_internet` adds the default IPv4 route:

```text
0.0.0.0/0 -> Internet Gateway
```

`0.0.0.0/0` matches all IPv4 destinations unless a more-specific route matches first.

The `aws_route_table_association.public` resources attach both public subnets to this table:

```text
Public subnet 1 -> public route table
Public subnet 2 -> public route table
```

The intended public subnet path is:

```text
Public resource
  -> public subnet
  -> public route table
  -> 0.0.0.0/0 route
  -> Internet Gateway
  -> internet
```

For inbound access, the resource also needs a public address (or an AWS-managed public endpoint) and suitable security-group and network ACL rules. The ALB is the intended public entry point.

### Private route tables and associations

`aws_route_table.private` creates one private table for each private subnet. `aws_route_table_association.private` maps them one-to-one:

```text
Private subnet 1 -> private route table 1
Private subnet 2 -> private route table 2
```

These tables have the VPC local route but no `0.0.0.0/0` internet route in this first stage. Private resources can communicate within the VPC when security rules permit, but cannot reach general internet destinations.

A subnet uses one route table association. An association is not a route; it determines which routes the subnet uses.

## 7. Internet access for private resources

The private subnets currently have no general outbound internet path. If private EC2 instances later need package downloads or public artifact repositories, choices include:

- NAT Gateway, which provides general outbound connectivity but has hourly and data-processing charges.
- VPC endpoints for specific AWS services such as S3 or Systems Manager.
- A controlled artifact distribution and management approach that avoids general internet egress.

A NAT Gateway does not make private instances directly reachable from the internet.

## 8. Traffic and security summary

```text
Internet
  -> Internet Gateway
  -> public route table
  -> public subnet
  -> internet-facing ALB
  -> application instance in private subnet
  -> RDS in private subnet
```

- Route tables decide where traffic is sent.
- Security groups decide whether traffic is allowed to reach a resource.
- Public/private names and tags do not establish network access by themselves; routes, public addressing, and security rules determine actual connectivity.

## 9. Outputs

`outputs.tf` exposes useful values after apply:

```hcl
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
```

## 10. Validate and deploy

From `DevOps-Project-01/infrastructure-v2`:

```bash
terraform init
terraform fmt -recursive
terraform validate
terraform plan
```

Review the plan to ensure the account, region, AZ names, VPC CIDR, subnet CIDRs, and routes are correct. Then apply only when ready:

```bash
terraform apply
```

The initial private route tables intentionally have no NAT route, so private instances will not have general internet access.
