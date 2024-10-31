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
variable "bucket_prefix" {
  description = "The prefix for the S3 bucket name."
  type        = string
  default     = "webapp-bucket"
}

variable "force_destroy" {
  description = "Boolean to determine if the S3 bucket should be forcibly destroyed, even if not empty."
  type        = bool
  default     = true
}

variable "sse_algorithm" {
  description = "The server-side encryption algorithm to use for the S3 bucket."
  type        = string
  default     = "AES256"
}

variable "transition_days" {
  description = "Number of days before transitioning to a different storage class."
  type        = number
  default     = 30
}

variable "storage_class" {
  description = "The storage class to transition objects to after the specified number of days."
  type        = string
  default     = "STANDARD_IA"
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

variable "account_id" {
  type    = string
  default = "982081064063"
}

variable "root_volume_type" {
  description = "Root volume type"
  type        = string
  default     = "gp2"
}

variable "domain" {
  type    = string
  default = "demo.vardhan.click"
}

variable "app_port" {
  description = "Port on which your application runs"
  type        = number
  default     = 3000
}

variable "custom_ami_id" {
  description = "The AMI ID to use for the EC2 instance"
  type        = string
  default     = "ami-0b3fa2051aea53e1a" # Replace with your actual AMI ID
}

variable "db_password" {
  description = "The password for RDS"
  type        = string
  default     = "vacbookpro"
}

variable "existing_hosted_zone_id" {
  description = "The ID of the existing hosted zone in the dev AWS account"
  type        = string
  default     = "Z0066931O72YGWEOWWBG" # Replace with your actual hosted zone ID
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
  cidr_block              = cidrsubnet(var.vpc_cidr, 4, count.index + length(local.azs))
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

# NAT Gateway (for private subnet internet access)
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

# IAM Role for EC2 to access S3 and CloudWatch
resource "aws_iam_role" "ec2_role" {
  name = "ec2_role_with_s3_and_cloudwatch_access"

  assume_role_policy = jsonencode({
    Version = "2012-10-17",
    Statement = [
      {
        Action = "sts:AssumeRole",
        Principal = {
          Service = "ec2.amazonaws.com"
        },
        Effect = "Allow",
        Sid    = ""
      }
    ]
  })

  tags = {
    Name = "EC2Role-${random_string.identifier.result}"
  }
}
data "aws_caller_identity" "current" {}

# S3 Bucket Access Policy (least privilege)
resource "aws_iam_policy" "s3_access_policy" {
  name = "S3AccessPolicy-${random_string.identifier.result}"

  policy = jsonencode({
    Version = "2012-10-17",
    Statement = [
      {
        Action = [
          "s3:GetObject",
          "s3:ListBucket"
        ],
        Effect = "Allow",
        Resource = [
          "${aws_s3_bucket.webapp_bucket.arn}",
          "${aws_s3_bucket.webapp_bucket.arn}/*"
        ]
      }
    ]
  })
}

# CloudWatch Agent Policy (least privilege)
resource "aws_iam_policy" "cloudwatch_access_policy" {
  name = "CloudWatchAccessPolicy-${random_string.identifier.result}"

  policy = jsonencode({
    Version = "2012-10-17",
    Statement = [
      {
        Action = [
          "logs:CreateLogGroup",
          "logs:CreateLogStream",
          "logs:PutLogEvents"
        ],
        Effect = "Allow",
        Resource = [
          "arn:aws:logs:${var.aws_region}:${data.aws_caller_identity.current.account_id}:log-group:/aws/ec2/*"
        ]
      },
      {
        Action = [
          "cloudwatch:PutMetricData"
        ],
        Effect   = "Allow",
        Resource = "*",
        Condition = {
          "StringEquals" : {
            "cloudwatch:namespace" : "AWS/EC2"
          }
        }
      }
    ]
  })
}

# Attach Policies to the IAM Role
resource "aws_iam_role_policy_attachment" "attach_s3_access" {
  role       = aws_iam_role.ec2_role.name
  policy_arn = aws_iam_policy.s3_access_policy.arn
}

resource "aws_iam_role_policy_attachment" "attach_cloudwatch_access" {
  role       = aws_iam_role.ec2_role.name
  policy_arn = aws_iam_policy.cloudwatch_access_policy.arn
}

# Instance Profile to attach the IAM Role to the EC2 instance
resource "aws_iam_instance_profile" "ec2_instance_profile" {
  name = "ec2_instance_profile_with_s3_and_cloudwatch_access"
  role = aws_iam_role.ec2_role.name
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
    from_port       = 3306
    to_port         = 3306
    protocol        = "tcp"
    security_groups = [aws_security_group.app_sg.id]
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

resource "random_uuid" "bucket_uuid" {}

resource "aws_s3_bucket" "webapp_bucket" {
  bucket = "${var.bucket_prefix}-${random_uuid.bucket_uuid.result}"
  acl    = "private"

  force_destroy = var.force_destroy

  server_side_encryption_configuration {
    rule {
      apply_server_side_encryption_by_default {
        sse_algorithm = var.sse_algorithm
      }
    }
  }
}

resource "aws_s3_bucket_lifecycle_configuration" "webapp_lifecycle" {
  bucket = aws_s3_bucket.webapp_bucket.id

  rule {
    id     = "TransitionToStandardIA"
    status = "Enabled"

    transition {
      days          = var.transition_days
      storage_class = var.storage_class
    }
  }
}

# RDS Instance
resource "aws_db_instance" "rds_instance" {
  identifier             = "csye6225"
  engine                 = "mysql"
  instance_class         = "db.t3.micro"
  allocated_storage      = 20
  storage_type           = "gp2"
  username               = "csye6225"
  password               = var.db_password
  db_subnet_group_name   = aws_db_subnet_group.rds_subnet_group.name
  parameter_group_name   = aws_db_parameter_group.rds_pg.name
  publicly_accessible    = false
  vpc_security_group_ids = [aws_security_group.db_sg.id]
  skip_final_snapshot    = true
  multi_az               = false
  db_name                = "csye6225"

  tags = {
    Name = "RDSInstance-${random_string.identifier.result}"
  }
}

# RDS Subnet Group
resource "aws_db_subnet_group" "rds_subnet_group" {
  name       = "rds-subnet-group-${random_string.identifier.result}"
  subnet_ids = [for subnet in aws_subnet.private : subnet.id]

  tags = {
    Name = "RDSSubnetGroup-${random_string.identifier.result}"
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

# IAM Role for S3 and CloudWatch access
resource "aws_iam_role" "S3andCloudwatch" {
  name = "S3andCloudwatch"

  assume_role_policy = jsonencode({
    Version = "2012-10-17",
    Statement = [
      {
        Effect = "Allow",
        Principal = {
          Service = "ec2.amazonaws.com"
        },
        Action = "sts:AssumeRole"
      }
    ]
  })

  tags = {
    Name = "S3andCloudwatchRole-${random_string.identifier.result}"
  }
}

# Attach Amazon-managed CloudWatchAgentServerPolicy to the role
resource "aws_iam_role_policy_attachment" "attach_cloudwatch_agent_policy" {
  role       = aws_iam_role.S3andCloudwatch.name
  policy_arn = "arn:aws:iam::aws:policy/CloudWatchAgentServerPolicy"
}
# Create S3 Upload Policy
resource "aws_iam_policy" "s3_upload" {
  name        = "s3_upload"
  description = "Policy for uploading images to S3"

  policy = jsonencode({
    Version = "2012-10-17",
    Statement = [
      {
        Effect = "Allow",
        Action = [
          "s3:PutObject",
          "s3:GetObject",
          "s3:DeleteObject"
        ],
        Resource = "arn:aws:s3:::*/*" # Replace with actual bucket name or variable
      }
    ]
  })
}


# Attach custom S3 policy to the role
resource "aws_iam_role_policy_attachment" "attach_s3_pic_upload_policy" {
  role       = aws_iam_role.S3andCloudwatch.name
  policy_arn = aws_iam_policy.s3_upload.arn
}


# Create an instance profile for the EC2 instance and attach the role
resource "aws_iam_instance_profile" "S3andCloudwatch_instance_profile" {
  name = "S3andCloudwatchInstanceProfile"
  role = aws_iam_role.S3andCloudwatch.name
}

# Update EC2 instance to use the new instance profile with S3 and CloudWatch access
resource "aws_instance" "web" {
  ami                         = var.custom_ami_id
  instance_type               = var.instance_type
  key_name                    = var.key_pair_name
  subnet_id                   = aws_subnet.public[0].id
  vpc_security_group_ids      = [aws_security_group.app_sg.id]
  associate_public_ip_address = true
  iam_instance_profile        = aws_iam_instance_profile.S3andCloudwatch_instance_profile.name

  root_block_device {
    volume_size           = var.root_volume_size
    volume_type           = var.root_volume_type
    delete_on_termination = true
  }

  user_data = <<-EOF
              #!/bin/bash
              DB_HOST_ONLY=$(echo "${aws_db_instance.rds_instance.endpoint}" | cut -d ':' -f 1)
              
              # Create .env file with DB, app, and S3 bucket details
              echo "" > /home/csye6225/app/.env
              echo "DB_name=csye6225" >> /home/csye6225/app/.env
              echo "DB_password=${var.db_password}" >> /home/csye6225/app/.env
              echo "DB_host=$DB_HOST_ONLY" >> /home/csye6225/app/.env
              echo "PORT=${var.app_port}" >> /home/csye6225/app/.env
              echo "DEFAULT_PORT=3001" >> /home/csye6225/app/.env
              echo "DB_username=csye6225" >> /home/csye6225/app/.env
              echo "S3_BUCKET_NAME=${aws_s3_bucket.webapp_bucket.bucket}" >> /home/csye6225/app/.env

              # Configure CloudWatch Agent
              sudo tee /opt/aws/amazon-cloudwatch-agent/etc/amazon-cloudwatch-agent.json > /dev/null << 'CONFIG'
              {
                "agent": {
                  "metrics_collection_interval": 60,
                  "logfile": "/var/log/amazon-cloudwatch-agent/amazon-cloudwatch-agent.log"
                },
                "logs": {
                  "logs_collected": {
                    "files": {
                      "collect_list": [
                        {
                          "file_path": "/home/csye6225/app/app.log",
                          "log_group_name": "my-log-group",
                          "log_stream_name": "{instance_id}-app-log",
                          "timestamp_format": "%Y-%m-%d %H:%M:%S"
                        }
                      ]
                    }
                  }
                },
                "metrics": {
                  "metrics_collected": {
                    "cpu": {
                      "measurement": [
                        "cpu_usage_idle",
                        "cpu_usage_iowait",
                        "cpu_usage_user",
                        "cpu_usage_system"
                      ],
                      "metrics_collection_interval": 60
                    },
                    "mem": {
                      "measurement": [
                        "mem_used_percent"
                      ],
                      "metrics_collection_interval": 60
                    }
                  }
                }
              }
              CONFIG

              sudo /opt/aws/amazon-cloudwatch-agent/bin/amazon-cloudwatch-agent-ctl -a fetch-config -m ec2 -c file:/opt/aws/amazon-cloudwatch-agent/etc/amazon-cloudwatch-agent.json -s
              sudo systemctl restart amazon-cloudwatch-agent

              systemctl daemon-reload
              systemctl restart myapp.service
              EOF

  tags = {
    Name = "WebInstance-${random_string.identifier.result}"
  }
}


# Route 53 A Record in the existing hosted zone
resource "aws_route53_record" "webapp" {
  zone_id = var.existing_hosted_zone_id
  name    = var.domain # Change if using a subdomain
  type    = "A"
  ttl     = "300"
  records = [aws_instance.web.public_ip] # Automatically uses EC2 instance's public IP
}

# Outputs
output "vpc_id" {
  value = aws_vpc.main.id
}

output "public_subnet_ids" {
  value = [for subnet in aws_subnet.public : subnet.id]
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

output "ec2_public_ip" {
  value = aws_instance.web.public_ip
}

output "route53_record_name" {
  value = aws_route53_record.webapp.name
}
