
resource "random_string" "identifier" {
  length  = 8
  special = false
  upper   = false
}


data "aws_caller_identity" "current" {}

provider "aws" {
  region = var.aws_region
}

# Variables for Region and VPC CIDR
variable "aws_region" {
  description = "The AWS region to create resources in"
  type        = string
  default     = "us-east-1"
}

variable "vpc_cidr" {
  description = "The CIDR block for the VPC"
  type        = string
  default     = "10.0.0.0/16"
}


data "aws_availability_zones" "available" {}


locals {
  azs                     = data.aws_availability_zones.available.names
  required_azs            = 3
  region_has_required_azs = length(local.azs) >= local.required_azs
}


resource "null_resource" "check_az_count" {
  count = local.region_has_required_azs ? 0 : 1
  provisioner "local-exec" {
    command = "echo 'Error: The specified region has fewer than 3 Availability Zones. Please choose a different region.'"
  }
}


resource "aws_vpc" "main" {
  cidr_block = var.vpc_cidr
  tags = {
    Name = "MainVPC-${random_string.identifier.result}"
  }
}


resource "aws_subnet" "public" {
  count                   = local.required_azs
  vpc_id                  = aws_vpc.main.id
  cidr_block              = cidrsubnet(var.vpc_cidr, 4, count.index)
  availability_zone       = local.azs[count.index]
  map_public_ip_on_launch = true

  tags = {
    Name = "PublicSubnet-${local.azs[count.index]}-${random_string.identifier.result}"
  }
}


resource "aws_subnet" "private" {
  count             = local.required_azs
  vpc_id            = aws_vpc.main.id
  cidr_block        = cidrsubnet(var.vpc_cidr, 4, count.index + local.required_azs)
  availability_zone = local.azs[count.index]

  tags = {
    Name = "PrivateSubnet-${local.azs[count.index]}-${random_string.identifier.result}"
  }
}


resource "aws_internet_gateway" "igw" {
  vpc_id = aws_vpc.main.id

  tags = {
    Name = "IGW-${random_string.identifier.result}"
  }
}


resource "aws_route_table" "public" {
  vpc_id = aws_vpc.main.id

  tags = {
    Name = "PublicRouteTable-${random_string.identifier.result}"
  }
}


resource "aws_route" "public_internet_access" {
  route_table_id         = aws_route_table.public.id
  destination_cidr_block = "0.0.0.0/0"
  gateway_id             = aws_internet_gateway.igw.id
}


resource "aws_route_table_association" "public_subnet" {
  count          = local.required_azs
  subnet_id      = aws_subnet.public[count.index].id
  route_table_id = aws_route_table.public.id
}

# Create a Single Private Route Table with Unique Name
resource "aws_route_table" "private" {
  vpc_id = aws_vpc.main.id

  tags = {
    Name = "PrivateRouteTable-${random_string.identifier.result}"
  }
}


resource "aws_eip" "nat" {
  domain = "vpc"
}

resource "aws_nat_gateway" "nat" {
  allocation_id = aws_eip.nat.id
  subnet_id     = aws_subnet.public[0].id # Use the first public subnet for the NAT Gateway

  tags = {
    Name = "MainNATGateway-${random_string.identifier.result}"
  }
}


resource "aws_route" "private_nat_access" {
  route_table_id         = aws_route_table.private.id
  destination_cidr_block = "0.0.0.0/0"
  nat_gateway_id         = aws_nat_gateway.nat.id
}


resource "aws_route_table_association" "private_subnet" {
  count          = local.required_azs
  subnet_id      = aws_subnet.private[count.index].id
  route_table_id = aws_route_table.private.id
}


output "vpc_id" {
  value = aws_vpc.main.id
}

output "public_subnet_ids" {
  value = [for subnet in aws_subnet.public : subnet.id]
}

output "private_subnet_ids" {
  value = [for subnet in aws_subnet.private : subnet.id]
}

output "nat_gateway_id" {
  value = aws_nat_gateway.nat.id
}
