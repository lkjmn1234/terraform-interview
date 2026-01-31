# --- 1. IAM Role for Bastion ---
resource "aws_iam_role" "bastion_role" {
  name = "bastion_role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Action = "sts:AssumeRole"
      Effect = "Allow"
      Principal = { Service = "ec2.amazonaws.com" }
    }]
  })
}

# Allow Bastion to "Describe" the cluster (required to generate kubeconfig)
resource "aws_iam_role_policy" "bastion_policy" {
  name = "bastion_eks_read_policy"
  role = aws_iam_role.bastion_role.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect   = "Allow"
      Action   = ["eks:DescribeCluster", "eks:ListClusters"]
      Resource = "*"
    }]
  })
}

resource "aws_iam_instance_profile" "bastion_profile" {
  name = "bastion_profile"
  role = aws_iam_role.bastion_role.name
}

# --- 2. Security Group ---
resource "aws_security_group" "bastion_sg" {
  name   = "bastion-sg"
  vpc_id = module.vpc.vpc_id

  # Inbound SSH (Restrict to your IP for security)
  ingress {
    from_port   = 22
    to_port     = 22
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"] # ⚠️ REPLACE with your specific IP e.g. "203.0.113.5/32"
  }

  # Outbound ALL (Required for GitHub access and reaching EKS API)
  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }
}

# --- 3. EC2 Instance ---
data "aws_ami" "amazon_linux_2023" {
  most_recent = true
  owners      = ["amazon"]
  filter {
    name   = "name"
    values = ["al2023-ami-2023.*-x86_64"]
  }
}

resource "aws_instance" "bastion" {
  ami                         = data.aws_ami.amazon_linux_2023.id
  instance_type               = "t3.micro"
  subnet_id                   = module.vpc.public_subnets[0]
  vpc_security_group_ids      = [aws_security_group.bastion_sg.id]
  iam_instance_profile        = aws_iam_instance_profile.bastion_profile.name
  associate_public_ip_address = true
  key_name                    = "my-ssh-key" # ⚠️ Ensure this key pair exists in AWS

  # --- ADD THIS BLOCK FOR SPOT ---
  instance_market_options {
    market_type = "spot"
    spot_options {
      # "one-time" means the instance is not recreated automatically by AWS if killed 
      # (Terraform will recreate it on next apply). 
      # Use "persistent" if you were using an interruption behavior like "stop".
      spot_instance_type = "one-time"
    }
  }
  
  # Installs Git (for public github), AWS CLI, and Kubectl
  user_data = <<-EOF
              #!/bin/bash
              yum update -y
              yum install -y git aws-cli
              
              # Install kubectl (Region specific download)
              curl -O https://s3.us-west-2.amazonaws.com/amazon-eks/1.29.0/2024-01-04/bin/linux/amd64/kubectl
              chmod +x ./kubectl
              mv ./kubectl /usr/local/bin
              EOF

  tags = { Name = "eks-bastion-sg" }
}

output "bastion_public_ip" {
  value = aws_instance.bastion.public_ip
}