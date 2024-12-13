#  VPC Creation
resource "aws_vpc" "main" {
  cidr_block = var.vpc_cidr
}

# Public Subnet Creation
resource "aws_subnet" "public" {
  count = 2
  vpc_id                  = aws_vpc.main.id
  cidr_block              = var.public_subnet_cidrs[count.index]
  map_public_ip_on_launch = true
  availability_zone       = ["us-west-2a", "us-west-2b"][count.index]
}

# Private Subnet Creation
resource "aws_subnet" "private" {
  count = 2
  vpc_id            = aws_vpc.main.id
  cidr_block        = var.private_subnet_cidrs[count.index]
  availability_zone = ["us-west-2a", "us-west-2b"][count.index]
}

# Internet Gateway Creation
resource "aws_internet_gateway" "main" {
  vpc_id = aws_vpc.main.id
}

# Route Table for Public Subnet
resource "aws_route_table" "public" {
  vpc_id = aws_vpc.main.id

  route {
    cidr_block = "0.0.0.0/0"
    gateway_id = aws_internet_gateway.main.id
  }
}

# Route Table Association for Public Subnet
resource "aws_route_table_association" "public" {
  count          = 2
  subnet_id      = aws_subnet.public[count.index].id
  route_table_id = aws_route_table.public.id
}

# Security Group for Public Subnet
resource "aws_security_group" "sinha_public_sg" {
  vpc_id = aws_vpc.main.id

  ingress {
    from_port   = 80
    to_port     = 80
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  ingress {
    from_port   = 22
    to_port     = 22
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }
}

# Security Group for Private Subnet
resource "aws_security_group" "sinha_private_sg" {
  vpc_id = aws_vpc.main.id

  ingress {
    from_port       = 0
    to_port         = 0
    protocol        = "-1"
    security_groups = [aws_security_group.sinha_public_sg.id]
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }
}

# Launch Template for Public EC2 Instances
resource "aws_launch_template" "sinha_public_instance" {
  name          = "sinha-public-instance-template"
  instance_type = var.instance_type
  image_id      = var.ami_id
  iam_instance_profile {
    name = aws_iam_instance_profile.sinha_public_role.name
  }
  vpc_security_group_ids = [aws_security_group.sinha_public_sg.id]
}

# Auto Scaling Group for Public EC2 Instances
resource "aws_autoscaling_group" "sinha_public_asg" {
  desired_capacity    = 2
  max_size            = 3
  min_size            = 1
  vpc_zone_identifier = [
    aws_subnet.public[0].id,
    aws_subnet.public[1].id
  ]
  launch_template {
    id      = aws_launch_template.sinha_public_instance.id
    version = "$Latest"
  }
  target_group_arns = [aws_lb_target_group.sinha_app_targets.arn]
}

# Private EC2 Instance
resource "aws_instance" "sinha_private_instance" {
  ami                    = var.ami_id
  instance_type          = var.instance_type
  subnet_id              = aws_subnet.private[0].id
  vpc_security_group_ids = [aws_security_group.sinha_private_sg.id]
}

# Application Load Balancer
resource "aws_lb" "sinha_application_lb" {
  name               = "sinha-app-lb"
  internal           = false
  load_balancer_type = "application"
  security_groups    = [aws_security_group.sinha_public_sg.id]
  subnets            = [
    aws_subnet.public[0].id,
    aws_subnet.public[1].id
  ]
}

# Target Group for Application Load Balancer
resource "aws_lb_target_group" "sinha_app_targets" {
  name     = "sinha-app-targets"
  port     = 80
  protocol = "HTTP"
  vpc_id   = aws_vpc.main.id
}

# Listener for Application Load Balancer
resource "aws_lb_listener" "sinha_app_listener" {
  load_balancer_arn = aws_lb.sinha_application_lb.arn
  port              = 80
  protocol          = "HTTP"
  default_action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.sinha_app_targets.arn
  }
}

# Network Load Balancer
resource "aws_lb" "sinha_network_lb" {
  name               = "sinha-net-lb"
  internal           = true
  load_balancer_type = "network"
  subnets            = [
    aws_subnet.private[0].id,
    aws_subnet.private[1].id
  ]
}

# Target Group for Network Load Balancer
resource "aws_lb_target_group" "sinha_network_targets" {
  name     = "sinha-net-targets"
  port     = 80
  protocol = "TCP"
  vpc_id   = aws_vpc.main.id
}

# Listener for Network Load Balancer
resource "aws_lb_listener" "sinha_net_listener" {
  load_balancer_arn = aws_lb.sinha_network_lb.arn
  port              = 80
  protocol          = "TCP"
  default_action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.sinha_network_targets.arn
  }
}

# S3 Bucket
resource "aws_s3_bucket" "sinha_private_bucket" {
  bucket = "sinha-private-bucket"
}

resource "aws_s3_bucket_ownership_controls" "sinha_private_bucket_ownership_controls" {
  bucket = aws_s3_bucket.sinha_private_bucket.id
  rule {
    object_ownership = "BucketOwnerPreferred"
  }
}

resource "aws_s3_bucket_acl" "sinha_private_bucket_acl" {
  depends_on = [aws_s3_bucket_ownership_controls.sinha_private_bucket_ownership_controls]
  bucket     = aws_s3_bucket.sinha_private_bucket.id
  acl        = "private"
}

resource "aws_s3_bucket_versioning" "sinha_s3_versioning" {
  bucket = aws_s3_bucket.sinha_private_bucket.id
  versioning_configuration {
    status = "Enabled"
  }
}

# IAM Role
resource "aws_iam_role" "sinha_public_role" {
  name               = "sinha-public-role"
  assume_role_policy = jsonencode({
    Version = "2012-10-17",
    Statement = [
      {
        Action    = "sts:AssumeRole",
        Effect    = "Allow",
        Principal = { Service = "ec2.amazonaws.com" }
      }
    ]
  })
}

# IAM Policy for S3 Access
resource "aws_iam_policy" "sinha_s3_access" {
  name        = "sinha-s3-access-unique"
  description = "Full access to the S3 bucket"
  policy      = jsonencode({
    Version = "2012-10-17",
    Statement = [
      {
        Action   = ["s3:*"],
        Effect   = "Allow",
        Resource = [aws_s3_bucket.sinha_private_bucket.arn, "${aws_s3_bucket.sinha_private_bucket.arn}/*"]
      }
    ]
  })
}

# Attach IAM Policy to Role
resource "aws_iam_role_policy_attachment" "sinha_attach_policy" {
  role       = aws_iam_role.sinha_public_role.name
  policy_arn = aws_iam_policy.sinha_s3_access.arn
}

# IAM Instance Profile
resource "aws_iam_instance_profile" "sinha_public_role" {
  name = "sinha-public-instance-profile-unique"
  role = aws_iam_role.sinha_public_role.name
}
