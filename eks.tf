module "eks" {
  source  = "terraform-aws-modules/eks/aws"
  version = "21.15.1"

  name    = "my-private-cluster-sg"
  kubernetes_version = "1.29"

  vpc_id     = module.vpc.vpc_id
  subnet_ids = module.vpc.private_subnets

  # --- Security: Private API ---
  endpoint_public_access  = false # No internet access to API
  endpoint_private_access = true  # Internal access only
  addons = {
    coredns                = {}
    eks-pod-identity-agent = {
      before_compute = true
    }
    kube-proxy             = {}
    vpc-cni                = {
      before_compute = true
      service_account_role_arn = module.vpc_cni_irsa.arn
    }
  }
  # Allow the Bastion SG to talk to the API Server on port 443
  security_group_additional_rules = {
    ingress_bastion = {
      description              = "Ingress from Bastion"
      protocol                 = "tcp"
      from_port                = 443
      to_port                  = 443
      type                     = "ingress"
      source_security_group_id = aws_security_group.bastion_sg.id
    }
  }
  # --- Authentication ---
  enable_cluster_creator_admin_permissions = true
  authentication_mode                      = "API_AND_CONFIG_MAP"

  # Grant Bastion Role Admin Access via API
  access_entries = {
    bastion = {
      principal_arn = aws_iam_role.bastion_role.arn
      policy_associations = {
        admin = {
          policy_arn = "arn:aws:eks::aws:cluster-access-policy/AmazonEKSClusterAdminPolicy"
          access_scope = {
            type = "cluster"
          }
        }
      }
    }
  }

  # --- Node Groups ---
  eks_managed_node_groups = {
    main = {
      min_size     = 1
      max_size     = 1
      desired_size = 1
      capacity_type = "SPOT"
      instance_types = ["t3.medium", "t3a.medium"]
      labels = {
        "lifecycle" = "Ec2Spot"
      }
      iam_role_additional_policies = {
        AmazonSSMManagedInstanceCore = "arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore"
        AmazonEC2ContainerRegistryReadOnly = "arn:aws:iam::aws:policy/AmazonEC2ContainerRegistryReadOnly"
      }
      metadata_options = {
        http_endpoint               = "enabled"
        http_tokens                 = "required"
        http_put_response_hop_limit = 2
      }
    }
  }
}
module "vpc_cni_irsa" {
  source  = "terraform-aws-modules/iam/aws//modules/iam-role-for-service-accounts"
  version = "~> 6.0"

  name = "vpc-cni-irsa"

  attach_vpc_cni_policy = true
  vpc_cni_enable_ipv4   = true

  oidc_providers = {
    main = {
      provider_arn               = module.eks.oidc_provider_arn
      namespace_service_accounts = ["kube-system:aws-node"]
    }
  }
}

# 1. Create the IAM Role for Worker Nodes
resource "aws_iam_role" "eks_node_role" {
  name = "eks-node-group-role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Action = "sts:AssumeRole"
      Effect = "Allow"
      Principal = {
        Service = "ec2.amazonaws.com"
      }
    }]
  })
}

# 2. Attach Required Policies
# Required for nodes to join the cluster
resource "aws_iam_role_policy_attachment" "worker_node_policy" {
  policy_arn = "arn:aws:iam::aws:policy/AmazonEKSWorkerNodePolicy"
  role       = aws_iam_role.eks_node_role.name
}

# Required for networking (VPC CNI)
resource "aws_iam_role_policy_attachment" "cni_policy" {
  policy_arn = "arn:aws:iam::aws:policy/AmazonEKS_CNI_Policy"
  role       = aws_iam_role.eks_node_role.name
}

# THE FIX: Required for pulling images from ECR
resource "aws_iam_role_policy_attachment" "ecr_read_only" {
  policy_arn = "arn:aws:iam::aws:policy/AmazonEC2ContainerRegistryReadOnly"
  role       = aws_iam_role.eks_node_role.name
}

data "aws_caller_identity" "current" {}

# 1. The Role that users will "put on" to access the cluster
resource "aws_iam_role" "eks_developer_role" {
  name = "eks-developer-access-role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Action = "sts:AssumeRole"
        Effect = "Allow"
        Principal = {
          AWS = "arn:aws:iam::${data.aws_caller_identity.current.account_id}:root"
        }
      }
    ]
  })
}

# 1. Create the IAM Role
resource "aws_iam_role" "eks_edit_role" {
  name = "eks-cluster-editor-role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Action = "sts:AssumeRole"
        Effect = "Allow"
        Principal = {
          # Allow your AWS account root (so IAM users can assume this role)
          AWS = "arn:aws:iam::${data.aws_caller_identity.current.account_id}:root"
        }
      }
    ]
  })
}

# 2. Create the Access Entry (Maps the IAM Role to EKS)
resource "aws_eks_access_entry" "editor_access" {
  cluster_name      = "my-private-cluster-sg"
  principal_arn     = aws_iam_role.eks_edit_role.arn
  kubernetes_groups = ["my-edit-group"] # Optional: Map to custom K8s groups
  type              = "STANDARD"
}

# 3. Attach the "Edit" Policy
resource "aws_eks_access_policy_association" "editor_policy" {
  cluster_name  = "my-private-cluster-sg"
  principal_arn = aws_iam_role.eks_edit_role.arn
  
  # This specific ARN grants the "Edit" ClusterRole
  policy_arn    = "arn:aws:eks::aws:cluster-access-policy/AmazonEKSEditPolicy"

  access_scope {
    type = "cluster" # Grants edit access to ALL namespaces
    # To limit to specific namespaces, use:
    # type       = "namespace"
    # namespaces = ["backend", "frontend"] 
  }
}

# 2. Grant the IAM Group permission to assume the specific role
resource "aws_iam_group_policy" "developer_assume_role" {
  name  = "allow-assume-eks-role"
  group = "eks-viewer" # Replace with your group name

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect   = "Allow"
        Action   = "sts:AssumeRole"
        Resource = aws_iam_role.eks_developer_role.arn
      }
    ]
  })
}
resource "aws_iam_group_policy" "developer_assume_edit_role" {
  name  = "allow-assume-eks-role"
  group = "eks-editor" # Replace with your group name

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect   = "Allow"
        Action   = "sts:AssumeRole"
        Resource = aws_iam_role.eks_edit_role.arn
      }
    ]
  })
}
# 3. Create the Access Entry for the Role
resource "aws_eks_access_entry" "developer_access" {
  cluster_name      = "my-private-cluster-sg"
  principal_arn     = aws_iam_role.eks_developer_role.arn
  kubernetes_groups = ["my-viewer-group"] # Optional: Map to custom K8s groups
  type              = "STANDARD"
}

# 4. Attach a Policy (e.g., Admin or View access)
resource "aws_eks_access_policy_association" "developer_policy" {
  cluster_name  = "my-private-cluster-sg"
  policy_arn    = "arn:aws:eks::aws:cluster-access-policy/AmazonEKSViewPolicy"
  principal_arn = aws_iam_role.eks_developer_role.arn

  access_scope {
    type       = "cluster"
  }
}