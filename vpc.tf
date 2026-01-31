module "vpc" {
  source  = "terraform-aws-modules/vpc/aws"
  version = "~> 6.0.0"

  name = "eks-vpc-sg"
  cidr = "10.0.0.0/16"

  azs             = ["ap-southeast-1a", "ap-southeast-1b", "ap-southeast-1c"]
  private_subnets = ["10.0.1.0/24", "10.0.2.0/24", "10.0.3.0/24"]
  public_subnets  = ["10.0.101.0/24", "10.0.102.0/24", "10.0.103.0/24"]

  # NAT Gateway required for private nodes to download images/patches
  enable_nat_gateway = true
  single_nat_gateway = true # Set false for production High Availability
  enable_vpn_gateway = false

  # DNS attributes ARE REQUIRED for endpoints to work
  enable_dns_hostnames = true
  enable_dns_support   = true

  # This allows the module to manage the security group for the interface endpoints
  create_database_subnet_group = false

  # Required tags for ALB Controller discovery
  public_subnet_tags = {
    "kubernetes.io/role/elb" = "1"
  }
  private_subnet_tags = {
    "kubernetes.io/role/internal-elb" = "1"
  }
}
module "vpc_endpoints" {
  source  = "terraform-aws-modules/vpc/aws//modules/vpc-endpoints"
  version = "~> 5.0"

  vpc_id = module.vpc.vpc_id

  # Create a security group that allows HTTPS from within the VPC
  security_group_ids = [aws_security_group.vpc_endpoints.id]

  endpoints = {
    ecr_api = {
      service             = "ecr.api"
      private_dns_enabled = true
      subnet_ids          = module.vpc.private_subnets
    },
    ecr_dkr = {
      service             = "ecr.dkr"
      private_dns_enabled = true
      subnet_ids          = module.vpc.private_subnets
    }
    s3 = {
      service         = "s3"
      service_type    = "Gateway"
      route_table_ids = module.vpc.private_route_table_ids
    }
  }
}

# Accompanying Security Group
resource "aws_security_group" "vpc_endpoints" {
  name_prefix = "vpc-endpoints-"
  description = "Allow TLS inbound from VPC for ECR"
  vpc_id      = module.vpc.vpc_id

  ingress {
    from_port   = 443
    to_port     = 443
    protocol    = "tcp"
    cidr_blocks = [module.vpc.vpc_cidr_block]
  }
}