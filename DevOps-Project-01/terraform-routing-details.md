# Terraform Routing: Routes, Route Tables, and Associations

This document explains the routing components used in the `DevOps-Project-01` AWS VPC. It covers VPC/subnet planning, routes, route tables, route-table associations, public routing, private routing, and Terraform resource relationships.

## What is a VPC?

A **Virtual Private Cloud (VPC)** is a logically isolated virtual network inside AWS. It owns the overall IP address range used by resources placed inside it.

For this project:

```text
VPC CIDR: 10.20.0.0/16
Region: ap-south-1
```

The VPC provides an address space, DNS support, subnets, routing, Internet Gateway attachment, and network isolation.

A VPC CIDR should not overlap with networks that may connect to it through VPC peering or VPN. Use `/16` as a planning range and divide it into smaller subnet CIDRs.

Terraform creates the VPC with:

```hcl
resource "aws_vpc" "main" {
  cidr_block           = var.vpc_cidr
  enable_dns_support   = true
  enable_dns_hostnames = true

  tags = {
    Name = "${var.project}-${var.environment}-vpc"
  }
}
```

- `cidr_block` defines the VPC address range.
- `enable_dns_support` enables AWS-provided DNS resolution in the VPC.
- `enable_dns_hostnames` enables DNS hostnames for supported AWS resources.

## Why use public and private subnets?

We divide the VPC into smaller subnet ranges placed across two Availability Zones. This separates internet-facing resources from internal application and database resources.

```text
VPC: 10.20.0.0/16
├── Public subnet 1: 10.20.1.0/24  (Availability Zone 1)
├── Public subnet 2: 10.20.2.0/24  (Availability Zone 2)
├── Private subnet 1: 10.20.11.0/24 (Availability Zone 1)
└── Private subnet 2: 10.20.12.0/24 (Availability Zone 2)
```

Each subnet range must fit inside the VPC CIDR and must not overlap another subnet.

## What is an Availability Zone?

An Availability Zone is a separate location within an AWS Region. Public and private subnets should be placed in at least two Availability Zones when the infrastructure is intended to tolerate a zonal failure.

Instead of hardcoding AZ names, Terraform discovers two available zones:

```hcl
data "aws_availability_zones" "available" {
  state = "available"

  filter {
    name   = "opt-in-status"
    values = ["opt-in-not-required"]
  }
}

locals {
  availability_zones = slice(
    data.aws_availability_zones.available.names,
    0,
    2
  )
}
```

This avoids assuming names such as `ap-south-1a` or `ap-south-1b`. AWS account availability can vary.

## Public subnets

A public subnet is a subnet whose associated route table has a route to an Internet Gateway.

Terraform creates the two public subnets with:

```hcl
resource "aws_subnet" "public" {
  count = length(var.public_subnet_cidrs)

  vpc_id                  = aws_vpc.main.id
  cidr_block              = var.public_subnet_cidrs[count.index]
  availability_zone       = local.availability_zones[count.index]
  map_public_ip_on_launch = true

  tags = {
    Name = "${var.project}-${var.environment}-public-${count.index + 1}"
    Tier = "public"
  }
}
```

The resource has one subnet for each CIDR in `public_subnet_cidrs`:

```hcl
public_subnet_cidrs = [
  "10.20.1.0/24",
  "10.20.2.0/24"
]
```

- `vpc_id` places the subnet inside `aws_vpc.main`.
- `cidr_block` assigns the subnet address range.
- `availability_zone` selects a zone for that subnet.
- `map_public_ip_on_launch = true` gives EC2 instances launched in the subnet a public IPv4 address by default.

Public subnets are intended for internet-facing entry points, for example:

- Application Load Balancer
- NAT Gateway
- Bastion host, if explicitly required

Assigning a public IP alone does not make routing public. The subnet needs:

1. A route to an Internet Gateway.
2. An associated route table.
3. Appropriate security-group rules.
4. A resource that needs public connectivity.

## Private subnets

A private subnet does not assign public IPs to resources and has no direct internet route in the initial design.

Terraform creates the private subnets with:

```hcl
resource "aws_subnet" "private" {
  count = length(var.private_subnet_cidrs)

  vpc_id            = aws_vpc.main.id
  cidr_block        = var.private_subnet_cidrs[count.index]
  availability_zone = local.availability_zones[count.index]

  tags = {
    Name = "${var.project}-${var.environment}-private-${count.index + 1}"
    Tier = "private"
  }
}
```

Example private CIDRs:

```hcl
private_subnet_cidrs = [
  "10.20.11.0/24",
  "10.20.12.0/24"
]
```

Private subnets are intended for:

- EC2 application instances
- RDS database instances
- Internal services
- Container or Kubernetes nodes

Do not assign RDS or application instances a public IP merely to make them reachable. Restrict them with private placement and security-group rules instead.

Private subnets can communicate with other resources inside the VPC through the VPC local route. They cannot currently reach the general internet because their route tables have no `0.0.0.0/0` route.

## Internet Gateway

An Internet Gateway connects a VPC to the internet:

```hcl
resource "aws_internet_gateway" "main" {
  vpc_id = aws_vpc.main.id

  tags = {
    Name = "${var.project}-${var.environment}-igw"
  }
}
```

The Internet Gateway is attached to the VPC, but routing determines whether a subnet can use it.

## Network routing overview

Routing determines where an IP packet goes after it leaves a subnet. It answers questions such as:

- Can this resource reach another resource in the VPC?
- Can this resource reach the internet?
- Which gateway or network device should receive outbound traffic?

Routing and security serve different purposes:

| Component | Purpose |
| --- | --- |
| VPC | Logical network boundary. |
| Subnet | Smaller IP range within the VPC and within an Availability Zone. |
| Route / route table | Selects the next destination for an IP address range. |
| Internet Gateway | Provides VPC-to-internet routing. |
| Security group | Allows or denies traffic for an AWS resource. |
| Network ACL | Adds optional subnet-level packet filtering. |

A packet can have a valid route but still be blocked by a security group or network ACL.

## VPC routing layout

The project uses public and private subnets:

```text
VPC: 10.20.0.0/16
├── Public subnet 1: 10.20.1.0/24
├── Public subnet 2: 10.20.2.0/24
├── Private subnet 1: 10.20.11.0/24
└── Private subnet 2: 10.20.12.0/24
```

Intended traffic flow:

```text
Internet
  -> Internet Gateway
  -> Public route table
  -> Public subnets
  -> Application Load Balancer
  -> Application instances in private subnets
  -> RDS in private subnets
```

## Route

A route specifies a destination CIDR block and where matching traffic should be sent.

Example:

```hcl
resource "aws_route" "public_internet" {
  route_table_id         = aws_route_table.public.id
  destination_cidr_block = "0.0.0.0/0"
  gateway_id             = aws_internet_gateway.main.id
}
```

The route means:

```text
0.0.0.0/0 -> Internet Gateway
```

### Route fields

- `route_table_id`: The route table containing this route.
- `destination_cidr_block`: The destination IP range that matches this route.
- `gateway_id`: The next destination for matching traffic.

Other route targets can include a NAT Gateway, transit gateway, peering connection, virtual private gateway, or network interface.

## CIDR destination matching

`0.0.0.0/0` matches all IPv4 destinations. AWS chooses the most-specific matching route.

Examples:

```text
10.20.0.0/16 -> local VPC route
10.21.0.0/16 -> peering or transit gateway route
0.0.0.0/0    -> Internet Gateway or NAT Gateway route
```

The VPC normally creates a local route automatically:

```text
10.20.0.0/16 -> local
```

The local route allows resources in this VPC to communicate with each other. For example:

```text
Application subnet: 10.20.11.0/24
RDS in private subnet: 10.20.12.0/24
```

The private application-to-RDS communication matches the VPC local route rather than the internet route.

## Route table

A route table is a collection of routes associated with one or more subnets.

When traffic leaves a subnet, AWS checks the route table associated with that subnet.

### Public route table

A public route table has a route to an Internet Gateway:

```hcl
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
```

Conceptually:

```text
Public route table
├── 10.20.0.0/16 -> local
└── 0.0.0.0/0 -> Internet Gateway
```

Both public subnets may use this route table.

### Private route tables

Private subnets use private route tables. For the initial network stage, they have no `0.0.0.0/0` route:

```hcl
resource "aws_route_table" "private" {
  count = length(aws_subnet.private)

  vpc_id = aws_vpc.main.id

  tags = {
    Name = "${var.project}-${var.environment}-private-rt-${count.index + 1}"
  }
}
```

Conceptually:

```text
Private route table 1
└── 10.20.0.0/16 -> local

Private route table 2
└── 10.20.0.0/16 -> local
```

No default route is present in these route tables, so private subnets cannot reach the general internet in the current design.

Using separate private route tables allows future routing policies to differ between Availability Zones or subnet groups.

## Route table association

A route table association connects a subnet to a route table.

```hcl
resource "aws_route_table_association" "public" {
  count = length(aws_subnet.public)

  subnet_id      = aws_subnet.public[count.index].id
  route_table_id = aws_route_table.public.id
}
```

This creates one association for each public subnet:

```text
Public subnet 1 -> Public route table
Public subnet 2 -> Public route table
```

Private subnet associations work similarly:

```hcl
resource "aws_route_table_association" "private" {
  count = length(aws_subnet.private)

  subnet_id      = aws_subnet.private[count.index].id
  route_table_id = aws_route_table.private[count.index].id
}
```

This creates:

```text
Private subnet 1 -> Private route table 1
Private subnet 2 -> Private route table 2
```

A subnet uses one route table. Associating a subnet with a route table replaces its previous explicit route-table association.

A route-table association is not a route. It determines which route table will be used by a subnet.

## Public traffic flow

For outbound traffic from a resource in a public subnet:

```text
Resource
  -> Public subnet
  -> Public route table
  -> 0.0.0.0/0 route
  -> Internet Gateway
  -> Internet
```

For inbound traffic:

```text
Internet
  -> Internet Gateway
  -> Public route table
  -> Public subnet
  -> Resource security group
  -> Resource
```

The Internet Gateway alone does not permit access. The resource must:

- Have a public IP address, such as an ALB or explicitly assigned EC2 IP
- Have a route back to the internet
- Be allowed by a security group
- Be allowed by a network ACL

## Private traffic flow

For traffic between private resources:

```text
Application instance
  -> Private subnet route table
  -> Local VPC route
  -> RDS private address
```

The private route table must contain the VPC CIDR local route.

For general internet traffic in the current design:

```text
Application instance
  -> Private subnet route table
  -> No 0.0.0.0/0 route
  -> Internet blocked
```

This prevents private EC2 and RDS resources from having unrestricted internet egress.

## NAT Gateway alternative

For private EC2 instances that need outbound internet access, add NAT Gateways and routes.

Typical Terraform pattern:

```hcl
resource "aws_eip" "nat" {
  count  = length(aws_subnet.public)
  domain = "vpc"
}

resource "aws_nat_gateway" "main" {
  count = length(aws_subnet.public)

  allocation_id = aws_eip.nat[count.index].id
  subnet_id     = aws_subnet.public[count.index].id
}

resource "aws_route" "private_internet" {
  count = length(aws_route_table.private)

  route_table_id         = aws_route_table.private[count.index].id
  destination_cidr_block = "0.0.0.0/0"
  nat_gateway_id         = aws_nat_gateway.main[count.index].id
}
```

This sends private subnet outbound traffic through a NAT Gateway in the corresponding public subnet:

```text
Private subnet
  -> Private route table
  -> 0.0.0.0/0 route
  -> NAT Gateway
  -> Internet Gateway
  -> Internet
```

NAT Gateways have hourly and data-processing charges. NAT Gateways also do not make private instances publicly reachable from the internet.

For management and package access, consider VPC endpoints or AWS Systems Manager Session Manager instead of automatically adding internet routing.

## Terraform dependency chain

The routing resources have this dependency structure:

```text
VPC
  -> Internet Gateway
  -> Route table
  -> Route
  -> Subnets
  -> Route table association
```

Terraform references infer dependencies:

```hcl
vpc_id = aws_vpc.main.id
```

The route table depends on the VPC.

```hcl
gateway_id = aws_internet_gateway.main.id
```

The route depends on the Internet Gateway.

```hcl
subnet_id = aws_subnet.public[count.index].id
```

The association depends on the subnet.

```hcl
route_table_id = aws_route_table.public.id
```

The association depends on the public route table.

## Security summary

The public design uses:

- Public subnets
- Internet Gateway
- Public route table
- Public route table associations
- An internet-facing Application Load Balancer
- ALB security-group rules

The private design uses:

- Private subnets
- Separate private route tables
- Private route-table associations
- No default internet route
- EC2 and RDS network placement
- Security groups for traffic restrictions

Route tables control network direction, but security groups remain required to control which traffic is allowed to reach a resource.
