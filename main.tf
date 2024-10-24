# Variables
variable "aws_region" {
  description = "The AWS region to create resources in"
  type        = string
  default     = "us-east-1"
}

variable "vpc_cidr" {
  description = "The CIDR block for the VPC"
  type        = string
  default     = "172.16.0.0/16"
}

variable "instance_type" {
  description = "EC2 instance type"
  type        = string
  default     = "t2.micro"
}

variable "key_pair_name" {
  description = "EC2 key pair name"
  type        = string
  default     = "ec2_key"
}

variable "root_volume_size" {
  description = "Root volume size in GB"
  type        = number
  default     = 25
}

variable "root_volume_type" {
  description = "Root volume type"
  type        = string
  default     = "gp2"
}

variable "app_port" {
  description = "Port on which your application runs"
  type        = number
  default     = 8080
}

variable "custom_ami_id" {
  description = "The AMI ID to use for the EC2 instance"
  type        = string
  default     = "ami-0928cdc80b68fdd9e"
}

variable "db_password" {
  description = "The password for RDS"
  type        = string
  default     = "vacbookpro"
}

# Random identifier for tagging resources
resource "random_string" "identifier" {
  length  = 8
  special = false
  upper   = false
}

# Provider
provider "aws" {
  region = var.aws_region
}

# Availability Zones Data
data "aws_availability_zones" "available" {}

locals {
  azs = slice(data.aws_availability_zones.available.names, 0, 3)
}

# VPC
resource "aws_vpc" "main" {
  cidr_block = var.vpc_cidr
  tags = {
    Name = "VPC-${random_string.identifier.result}"
  }
}

# Public Subnet (for EC2)
resource "aws_subnet" "public" {
  count                   = length(local.azs)
  vpc_id                  = aws_vpc.main.id
  cidr_block              = cidrsubnet(var.vpc_cidr, 4, count.index)
  availability_zone       = local.azs[count.index]
  map_public_ip_on_launch = true

  tags = {
    Name = "PublicSubnet-${local.azs[count.index]}-${random_string.identifier.result}"
  }
}

# Private Subnet (for RDS)
resource "aws_subnet" "private" {
  count                   = length(local.azs)
  vpc_id                  = aws_vpc.main.id
  cidr_block              = cidrsubnet(var.vpc_cidr, 4, count.index + length(local.azs)) # Offset to avoid overlap with public subnets
  availability_zone       = local.azs[count.index]
  map_public_ip_on_launch = false

  tags = {
    Name = "PrivateSubnet-${local.azs[count.index]}-${random_string.identifier.result}"
  }
}

# Internet Gateway
resource "aws_internet_gateway" "igw" {
  vpc_id = aws_vpc.main.id

  tags = {
    Name = "IGW-${random_string.identifier.result}"
  }
}

# Route Table for Public Subnet
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
  count          = length(local.azs)
  subnet_id      = aws_subnet.public[count.index].id
  route_table_id = aws_route_table.public.id
}

# NAT Gateway (to allow private subnet instances like RDS to access the internet)
resource "aws_eip" "nat" {
  count = 1
  vpc   = true
}

resource "aws_nat_gateway" "nat_gw" {
  allocation_id = aws_eip.nat[0].id
  subnet_id     = aws_subnet.public[0].id

  tags = {
    Name = "NATGateway-${random_string.identifier.result}"
  }
}

# Route Table for Private Subnet
resource "aws_route_table" "private" {
  vpc_id = aws_vpc.main.id

  tags = {
    Name = "PrivateRouteTable-${random_string.identifier.result}"
  }
}

resource "aws_route" "private_internet_access" {
  route_table_id         = aws_route_table.private.id
  destination_cidr_block = "0.0.0.0/0"
  nat_gateway_id         = aws_nat_gateway.nat_gw.id
}

resource "aws_route_table_association" "private_subnet" {
  count          = length(local.azs)
  subnet_id      = aws_subnet.private[count.index].id
  route_table_id = aws_route_table.private.id
}

# Application Security Group
resource "aws_security_group" "app_sg" {
  vpc_id = aws_vpc.main.id
  name   = "application security group-${random_string.identifier.result}"

  ingress {
    from_port   = 22
    to_port     = 22
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  ingress {
    from_port   = 80
    to_port     = 80
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  ingress {
    from_port   = 443
    to_port     = 443
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  ingress {
    from_port   = var.app_port
    to_port     = var.app_port
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = {
    Name = "AppSG-${random_string.identifier.result}"
  }
}

# DB Security Group
resource "aws_security_group" "db_sg" {
  vpc_id = aws_vpc.main.id
  name   = "DBSecurityGroup-${random_string.identifier.result}"

  ingress {
    from_port        = 3306
    to_port          = 3306
    protocol         = "tcp"
    security_groups  = [aws_security_group.app_sg.id] # Application security group as source
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = {
    Name = "DBSG-${random_string.identifier.result}"
  }
}

# RDS Parameter Group
resource "aws_db_parameter_group" "rds_pg" {
  name        = "rds-pg-${random_string.identifier.result}"
  family      = "mysql8.0" 
  description = "Custom parameter group for RDS instance"

  tags = {
    Name = "RDSParameterGroup-${random_string.identifier.result}"
  }
}

# RDS Subnet Group (using private subnets)
resource "aws_db_subnet_group" "rds_subnet_group" {
  name       = "rds-subnet-group-${random_string.identifier.result}"
  subnet_ids = [for subnet in aws_subnet.private : subnet.id]

  tags = {
    Name = "RDSSubnetGroup-${random_string.identifier.result}"
  }
}

# RDS Instance
resource "aws_db_instance" "rds_instance" {
  identifier              = "csye6225"
  engine                  = "mysql"
  instance_class          = "db.t3.micro"
  allocated_storage       = 20
  storage_type            = "gp2"
  username                = "csye6225"
  password                = var.db_password
  parameter_group_name    = aws_db_parameter_group.rds_pg.name
  db_subnet_group_name    = aws_db_subnet_group.rds_subnet_group.name
  publicly_accessible     = false
  vpc_security_group_ids  = [aws_security_group.db_sg.id]
  skip_final_snapshot     = true
  multi_az                = false
  db_name                 = "csye6225"

  tags = {
    Name = "RDSInstance-${random_string.identifier.result}"
  }
}

resource "aws_instance" "web" {
  ami                         = var.custom_ami_id
  instance_type               = var.instance_type
  key_name                    = var.key_pair_name
  subnet_id                   = aws_subnet.public[0].id
  vpc_security_group_ids      = [aws_security_group.app_sg.id]
  associate_public_ip_address = true

  root_block_device {
    volume_size           = var.root_volume_size
    volume_type           = var.root_volume_type
    delete_on_termination = true
  }

  # User Data to pass RDS endpoint without port and update .env file
  user_data = <<-EOF
              #!/bin/bash
              DB_HOST_ONLY=$(echo "${aws_db_instance.rds_instance.endpoint}" | cut -d ':' -f 1)
              
              # Clear the existing .env file
              echo "" > /home/csye6225/app/.env
              
              # Write new values to .env
              echo "DB_name=csye6225" >> /home/csye6225/app/.env
              echo "DB_password=vacbookpro" >> /home/csye6225/app/.env
              echo "DB_host=$DB_HOST_ONLY" >> /home/csye6225/app/.env
              echo "PORT=3000" >> /home/csye6225/app/.env
              echo "DEFAULT_PORT=3001" >> /home/csye6225/app/.env
              echo "DB_username=csye6225" >> /home/csye6225/app/.env
              
              # Restart the service after updating .env file
              systemctl daemon-reload
              systemctl restart myapp.service
              EOF

  tags = {
    Name = "WebInstance-${random_string.identifier.result}"
  }
}



# Outputs
output "vpc_id" {
  value = aws_vpc.main.id
}

output "public_subnet_ids" {
  value = [for subnet in aws_subnet.public : subnet.id]
}

output "private_subnet_ids" {
  value = [for subnet in aws_subnet.private : subnet.id]
}

output "instance_id" {
  value = aws_instance.web.id
}

output "rds_endpoint" {
  value = aws_db_instance.rds_instance.endpoint
}

output "db_sg_id" {
  value = aws_security_group.db_sg.id
}
