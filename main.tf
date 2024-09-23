#                                   #
#               VPC                 #
#                                   #
# The available availability zones in the region are obtained.
# We filter to select only the zones that do not require "opt-in".
# "Opt-in" zones are often incompatible with key services like managed node groups in EKS.
# This excludes local zones, which are not currently supported with EKS.
# Ensures greater stability and reliability for production deployments.
data "aws_availability_zones" "available" {
  filter {
    name   = "opt-in-status"
    values = ["opt-in-not-required"]
  }
}

# We define a local variable for the cluster name.
# A random suffix is concatenated to ensure the name is unique.
locals {
  cluster_name = "proof-eks-${random_string.suffix.result}"
}

# Generates a random 8-character string to use as a suffix in the cluster name.
resource "random_string" "suffix" {
  length  = 8
  special = false # No special characters
}

# Terraform VPC module to create the necessary network for the cluster.
module "vpc" {
  source  = "terraform-aws-modules/vpc/aws"
  version = "5.8.1"

  name = "proof-vpc"

  cidr = "10.0.0.0/16" 
  # Fault tolerance. Distribution across multiple availability zones (AZs):
  #     Private and public subnets in three different availability zones (three /24 for each).
  #     This means that if one availability zone experiences a failure or goes down, the other subnets in the remaining AZs can continue to function.
  azs  = slice(data.aws_availability_zones.available.names, 0, 3)  # We select the first three availability zones that do not require "opt-in".

  # Creation of three distinct subnets to increase security and follow best practices:
  #     Private subnets protect critical Kubernetes resources by not being accessible from outside, while public subnets handle external traffic.
  private_subnets = ["10.0.1.0/24", "10.0.2.0/24", "10.0.3.0/24"]
  public_subnets  = ["10.0.4.0/24", "10.0.5.0/24", "10.0.6.0/24"]

  enable_nat_gateway   = true  # Enable NAT Gateway to allow resources in private subnets to access the internet.
  single_nat_gateway   = true  # Use only one NAT Gateway to reduce costs (this is cheaper than having one per zone).
  enable_dns_hostnames = true  # Enable DNS so resources within the VPC can resolve domain names.

  # Tags for the public subnets so that Kubernetes recognizes them as subnets for external load balancers (ELB).
  public_subnet_tags = {
    "kubernetes.io/role/elb" = 1
  }

  # Tags for the private subnets so that Kubernetes recognizes them as subnets for internal load balancers (internal to the VPC).
  private_subnet_tags = {
      "kubernetes.io/role/internal-elb" = 1
    }
}


#                                   #
#               EKS                 #
#                                   #
# Terraform EKS module that simplifies the creation and management of EKS clusters and associated resources such as IAM users and roles in AWS.
#
# Features:
# - Simplified configuration of the EKS cluster, including node group creation and integration with AWS services.
# - Automatic management of users and permissions through IAM Roles.
# - Integration with add-ons such as the EBS CSI driver, facilitating the management of persistent volumes.
# - Automatic scaling of node groups.
# 
# Best practices implemented:
# - Use of private subnets for the nodes so they are not accessible from the internet.
# - Configuration of multiple node groups with scalability settings to ensure high availability and adjustment based on demand.
# - Integration with IAM and OIDC for precise permission management, ensuring that only necessary services have access to resources.
# - Use of Amazon Linux 2 AMIs optimized for the AWS environment, as Linux is always a good option.
module "eks" {
  source  = "terraform-aws-modules/eks/aws"
  version = "20.8.5"

  cluster_name    = local.cluster_name
  cluster_version = "1.29"

  cluster_endpoint_public_access           = true
  enable_cluster_creator_admin_permissions = true

  cluster_addons = {
    # Adds the CSI driver for Amazon EBS, necessary for managing persistent volumes.
    aws-ebs-csi-driver = {
      service_account_role_arn = module.irsa-ebs-csi.iam_role_arn
    }
  }

  vpc_id     = module.vpc.vpc_id
  subnet_ids = module.vpc.private_subnets # Uses private subnets for the nodes, increasing security

  eks_managed_node_group_defaults = {
    ami_type = "AL2_x86_64" # Amazon Linux 2 x86_64

  }

  # Configuring multiple node groups with minimum, maximum, and desired sizes to enable high 
  # availability and automatic scaling based on demand.
  eks_managed_node_groups = {
    # Definition of Node Group 1
    one = {
      name = "node-group-1"

      instance_types = ["t3.small"]

      min_size     = 1
      max_size     = 3
      desired_size = 2
    }
    # Definition of Node group 2
    two = {
      name = "node-group-2"

      instance_types = ["t3.small"]

      min_size     = 1
      max_size     = 2
      desired_size = 1
    }
  }
}

# IAM policy required for the EBS CSI driver.
data "aws_iam_policy" "ebs_csi_policy" {
  arn = "arn:aws:iam::aws:policy/service-role/AmazonEBSCSIDriverPolicy"
}

module "irsa-ebs-csi" {
  source  = "terraform-aws-modules/iam/aws//modules/iam-assumable-role-with-oidc"
  version = "5.39.0"

  create_role                   = true
  role_name                     = "AmazonEKSTFEBSCSIRole-${module.eks.cluster_name}"
  provider_url                  = module.eks.oidc_provider
  role_policy_arns              = [data.aws_iam_policy.ebs_csi_policy.arn]
  oidc_fully_qualified_subjects = ["system:serviceaccount:kube-system:ebs-csi-controller-sa"]
}

#                                   #
#              FLUXCD               #
#                                   #
# Resource to configure the FluxCD bootstrap with a Git repository to initialize the GitOps-based workflow.
#
# Features:
# - Configures the repository path and namespace for FluxCD resources.
# - Sets the synchronization interval and logging level for operation tracking.
# - Uses a container registry (ghcr.io/fluxcd) to obtain FluxCD images.
# 
# Best practices:
# - Keeps synchronization configurations in a dedicated namespace (`flux-system`), ensuring a clear separation of FluxCD resources.
# - Configures the synchronization interval and log level to control the frequency of updates and the detail of logged information.


resource "flux_bootstrap_git" "this" {
  path = "clusters/my-cluster"
  namespace = "flux-system"
  interval = "1m"
  log_level = "info"
  secret_name = "flux-git-auth"
  registry = "ghcr.io/fluxcd"
}

# Resource to create a Kubernetes secret that stores access credentials to the Git repository.
# This secret is used by FluxCD to authenticate access to the Git repository from which it synchronizes configurations.
# The secret is defined in the FluxCD namespace (`flux-system`).
# It uses the "Opaque" secret type to store arbitrary data.
# The token is stored in the variable `github_token`.
resource "kubernetes_secret" "flux_git_auth" {
  metadata {
    name      = "flux-git-auth"
    namespace = "flux-system"
  }

  data = {
    username = "git"
    password = var.github_token
  }

  type = "Opaque"
}

# Resource to deploy Prometheus and Grafana on Kubernetes using Helm.
# Reasons to use Helm instead of an AWS provider or other tools:
#
# 1. Management Ease:
#    - Helm provides a standardized and simplified way to manage applications on Kubernetes.
#    - Prometheus is automatically installed as the full Prometheus stack, and node-exporter is added to the pods. This is crucial.
#
# 2. Security:
#    - Helm allows managing configurations by using values instead of directly writing configurations in Kubernetes resources.
#
# 4. Best Practices:
#    - Helm encourages best practices by providing an organized structure for deploying applications, managing updates, and configuring resources.



resource "helm_release" "prometheus" {
  name       = "prometheus"
  repository = "https://prometheus-community.github.io/helm-charts"
  chart      = "prometheus"
  version    = "25.27.0"  
  namespace  = "monitoring"

  set {
    name  = "server.persistentVolume.enabled"
    value = "true"
  }

  set {
    name  = "server.persistentVolume.size"
    value = "4Gi"  
  }

  set {
    name  = "server.persistentVolume.storageClass"
    value = "gp2"  
  }

  set {
    name  = "service.port"
    value = "9090"  
  }

  set {
    name  = "server.service.targetPort"
    value = "9090"  
  }
}

resource "helm_release" "grafana" {
  name       = "grafana"
  repository = "https://grafana.github.io/helm-charts"
  chart      = "grafana"
  version    = "8.5.0"  
  namespace  = "monitoring"

  set {
    name  = "persistence.enabled"
    value = "true"
  }

  set {
    name  = "persistence.size"
    value = "4Gi"  
  }

  set {
    name  = "persistence.storageClass"
    value = "gp2"  
  }

  set {
    name  = "admin.password"
    value = "admin" 
  }

  set {
  name  = "service.port"
  value = "3000"  
  }
}

resource "kubernetes_namespace" "monitoring" {
  metadata {
    name = "monitoring"
    labels = {
      "app.kubernetes.io/part-of" = "monitoring"
    }
  }
}