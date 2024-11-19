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
variable "API_key" {
  type    = string
  default = "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"
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
  default     = "ami-0a0dbc8efe4b86973" # Replace with your actual AMI ID
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

# Public Subnet (for ALB)
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
# Create SNS Publish Policy
resource "aws_iam_policy" "sns_publish" {
  name        = "sns_publish_policy"
  description = "Policy to allow publishing messages to SNS"

  policy = jsonencode({
    Version = "2012-10-17",
    Statement = [
      {
        Effect   = "Allow",
        Action   = "sns:Publish",
        Resource = "arn:aws:sns:*:*:*" # Replace with specific SNS topic ARN(s) if you want to limit access
      }
    ]
  })
}

# Attach the SNS Publish policy to the S3andCloudwatch role
resource "aws_iam_role_policy_attachment" "attach_sns_publish_policy" {
  role       = aws_iam_role.S3andCloudwatch.name
  policy_arn = aws_iam_policy.sns_publish.arn
}


# Application Security Group
resource "aws_security_group" "app_sg" {
  name   = "application-sg"
  vpc_id = aws_vpc.main.id

  # Inbound rule to allow traffic only from Load Balancer Security Group on port 3000
  ingress {
    from_port       = 3000
    to_port         = 3000
    protocol        = "tcp"
    security_groups = [aws_security_group.load_balancer_sg.id] # Reference Load Balancer Security Group
    description     = "Allow traffic from Load Balancer on port 3000"
  }
  ingress {
    from_port   = 22
    to_port     = 22
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  # Egress rule to allow all outbound traffic
  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = {
    Name = "AppSecurityGroup"
  }
}

# Update DB Security Group to allow access from Lambda
resource "aws_security_group" "db_sg" {
  vpc_id = aws_vpc.main.id
  name   = "DBSecurityGroup-${random_string.identifier.result}"

  ingress {
    from_port = 3306
    to_port   = 3306
    protocol  = "tcp"
    security_groups = [
      aws_security_group.app_sg.id,
      aws_security_group.Lambda_sg.id # Added Lambda SG here
    ]
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

# S3 Bucket for Web Application
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

# Load Balancer Security Group
resource "aws_security_group" "load_balancer_sg" {
  name        = "load-balancer-security-group"
  description = "Security group for load balancer to access the web application"
  vpc_id      = aws_vpc.main.id

  ingress {
    from_port   = 80
    to_port     = 80
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
    description = "Allow HTTP traffic from anywhere"
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
    description = "Allow all outbound traffic"
  }

  tags = {
    Name = "LoadBalancerSG"
  }
}

# Application Load Balancer
resource "aws_lb" "app_lb" {
  name               = "app-load-balancer"
  internal           = false
  load_balancer_type = "application"
  security_groups    = [aws_security_group.load_balancer_sg.id]
  subnets            = [for subnet in aws_subnet.public : subnet.id]

  tags = {
    Name = "AppLoadBalancer"
  }
}

# Target Group for ALB
resource "aws_lb_target_group" "app_tg" {
  name     = "app-target-group"
  port     = var.app_port
  protocol = "HTTP"
  vpc_id   = aws_vpc.main.id
  health_check {
    path                = "/healthz"
    port                = "traffic-port"
    protocol            = "HTTP"
    interval            = 30
    timeout             = 5
    healthy_threshold   = 2
    unhealthy_threshold = 2
  }

  tags = {
    Name = "AppTargetGroup"
  }
}

# Load Balancer Listener
resource "aws_lb_listener" "app_lb_listener" {
  load_balancer_arn = aws_lb.app_lb.arn
  port              = 80
  protocol          = "HTTP"

  default_action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.app_tg.arn
  }
}
#launch_template
resource "aws_launch_template" "csye6225_asg" {
  name          = "csye6225_asg"
  image_id      = var.custom_ami_id
  instance_type = var.instance_type
  key_name      = var.key_pair_name
  iam_instance_profile {
    name = aws_iam_instance_profile.S3andCloudwatch_instance_profile.name
  }

  network_interfaces {
    associate_public_ip_address = true
    security_groups             = [aws_security_group.app_sg.id]
  }

  user_data = base64encode(<<-EOF
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
              echo "SNS_TOPIC_ARN=${aws_sns_topic.my_topic.arn}" >> /home/csye6225/app/.env

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
  )
}


# Auto Scaling Group
resource "aws_autoscaling_group" "webapp_asg" {
  desired_capacity = 3
  max_size         = 5
  min_size         = 3
  launch_template {
    id      = aws_launch_template.csye6225_asg.id
    version = "$Latest"
  }

  vpc_zone_identifier       = [for subnet in aws_subnet.public : subnet.id]
  health_check_type         = "EC2"
  health_check_grace_period = 300
  default_cooldown          = 60

  tag {
    key                 = "Name"
    value               = "WebAppInstance"
    propagate_at_launch = true
  }

  lifecycle {
    create_before_destroy = true
  }
}

# Auto Scaling Attachments to Target Group
resource "aws_autoscaling_attachment" "asg_attachment" {
  autoscaling_group_name = aws_autoscaling_group.webapp_asg.name
  lb_target_group_arn    = aws_lb_target_group.app_tg.arn
}

# CloudWatch Alarms for Auto Scaling Policies
resource "aws_cloudwatch_metric_alarm" "scale_up_alarm" {
  alarm_name          = "scale-up-cpu"
  comparison_operator = "GreaterThanThreshold"
  evaluation_periods  = 2
  metric_name         = "CPUUtilization"
  namespace           = "AWS/EC2"
  period              = 120
  statistic           = "Average"
  threshold           = 10
  alarm_actions       = [aws_autoscaling_policy.scale_up_policy.arn]

  dimensions = {
    AutoScalingGroupName = aws_autoscaling_group.webapp_asg.name
  }
}

resource "aws_cloudwatch_metric_alarm" "scale_down_alarm" {
  alarm_name          = "scale-down-cpu"
  comparison_operator = "LessThanThreshold"
  evaluation_periods  = 2
  metric_name         = "CPUUtilization"
  namespace           = "AWS/EC2"
  period              = 120
  statistic           = "Average"
  threshold           = 8
  alarm_actions       = [aws_autoscaling_policy.scale_down_policy.arn]

  dimensions = {
    AutoScalingGroupName = aws_autoscaling_group.webapp_asg.name
  }
}

resource "aws_autoscaling_policy" "scale_up_policy" {
  name                   = "scale_up_policy"
  scaling_adjustment     = 1
  adjustment_type        = "ChangeInCapacity"
  cooldown               = 60
  autoscaling_group_name = aws_autoscaling_group.webapp_asg.name
}

resource "aws_autoscaling_policy" "scale_down_policy" {
  name                   = "scale_down_policy"
  scaling_adjustment     = -1
  adjustment_type        = "ChangeInCapacity"
  cooldown               = 60
  autoscaling_group_name = aws_autoscaling_group.webapp_asg.name
}

# Route 53 A Record for Load Balancer
resource "aws_route53_record" "webapp_alias" {
  zone_id = var.existing_hosted_zone_id
  name    = var.domain # Replace with "dev.example.com" or "demo.example.com"
  type    = "A"

  alias {
    name                   = aws_lb.app_lb.dns_name
    zone_id                = aws_lb.app_lb.zone_id
    evaluate_target_health = true
  }
}
# Create SNS Topic
resource "aws_sns_topic" "my_topic" {
  name = "my_sns_topic"
}

# IAM Role for Lambda Function
resource "aws_iam_role" "lambda_role" {
  name = "lambda_role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17",
    Statement = [{
      Action = "sts:AssumeRole",
      Effect = "Allow",
      Principal = {
        Service = "lambda.amazonaws.com"
      }
    }]
  })
}

# IAM Policy for Lambda Function
resource "aws_iam_policy" "lambda_policy" {
  name = "lambda_policy"

  policy = jsonencode({
    Version = "2012-10-17",
    Statement = [
      # Permissions for CloudWatch Logs
      {
        Effect = "Allow",
        Action = [
          "logs:CreateLogGroup",
          "logs:CreateLogStream",
          "logs:PutLogEvents"
        ],
        Resource = "arn:aws:logs:*:*:*"
      },
      # Permissions for VPC Access
      {
        Effect = "Allow",
        Action = [
          "ec2:CreateNetworkInterface",
          "ec2:DescribeNetworkInterfaces",
          "ec2:DeleteNetworkInterface"
        ],
        Resource = "*"
      }
      # Add any other permissions your Lambda function requires
    ]
  })
}

# Attach the policy to the role
resource "aws_iam_role_policy_attachment" "lambda_policy_attachment" {
  role       = aws_iam_role.lambda_role.name
  policy_arn = aws_iam_policy.lambda_policy.arn
}

# Lambda Security Group
resource "aws_security_group" "Lambda_sg" {
  name        = "lambda-security-group"
  description = "Security group for Lambda function"
  vpc_id      = aws_vpc.main.id

  # No ingress rules needed for Lambda
  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = {
    Name = "LambdaSecurityGroup"
  }
}



# Package Lambda code
data "archive_file" "lambda_zip" {
  type        = "zip"
  source_dir  = "/Users/vardhankaranam/Desktop/lambda" # Update with your code directory
  output_path = "${path.module}/lambda_function.zip"
}


# Create Lambda Function
resource "aws_lambda_function" "my_lambda" {
  function_name = "my_lambda_function"
  filename      = data.archive_file.lambda_zip.output_path
  handler       = "index.handler" # Update if your handler file is different
  runtime       = "nodejs18.x"    # Update to your Node.js runtime version
  role          = aws_iam_role.lambda_role.arn

  # VPC Configuration
  vpc_config {
    subnet_ids         = [for subnet in aws_subnet.private : subnet.id]
    security_group_ids = [aws_security_group.Lambda_sg.id]
  }

  # Environment Variables
  environment {
    variables = {
      RDS_DB_NAME      = "csye6225"
      RDS_HOST         = element(split(":", aws_db_instance.rds_instance.endpoint), 0) # Hostname only
      RDS_PASSWORD     = var.db_password
      RDS_USERNAME     = "csye6225"
      SENDGRID_API_KEY = var.API_key
    }
  }

  # Optional settings
  timeout     = 30
  memory_size = 128
}


# Allow SNS to invoke Lambda
resource "aws_lambda_permission" "allow_sns" {
  statement_id  = "AllowExecutionFromSNS"
  action        = "lambda:InvokeFunction"
  function_name = aws_lambda_function.my_lambda.function_name
  principal     = "sns.amazonaws.com"
  source_arn    = aws_sns_topic.my_topic.arn
}

# SNS Subscription to Lambda Function
resource "aws_sns_topic_subscription" "lambda_subscription" {
  topic_arn = aws_sns_topic.my_topic.arn
  protocol  = "lambda"
  endpoint  = aws_lambda_function.my_lambda.arn
}

# Outputs
output "vpc_id" {
  value = aws_vpc.main.id
}

output "public_subnet_ids" {
  value = [for subnet in aws_subnet.public : subnet.id]
}

output "rds_endpoint" {
  value = aws_db_instance.rds_instance.endpoint
}

output "db_sg_id" {
  value = aws_security_group.db_sg.id
}

output "route53_record_name" {
  value = aws_route53_record.webapp_alias.name
}
