terraform {

  # Protect the tfstate by storing it in an S3 bucket and applying a LOCK 
  # using DynamoDB to prevent multiple people from writing to it at the same time.
  backend "s3" {
    bucket         = "mi-proof-tfstate-bucket"
    key            = "ruta/a/mi/archivo.tfstate"
    region         = "eu-west-1"             
    dynamodb_table = "mi-tabla-dynamo-lock"    
    encrypt        = true                      
  }

  # Configuration of providers and version in Terraform
  # 
  # This section defines the necessary providers for the Terraform project:
  #
  # - `aws`: Provider to manage AWS resources.
  # - `random`: Provider to generate random values.
  # - `tls`: Provider to manage TLS certificates and keys.
  # - `flux`: Provider to manage FluxCD resources in Kubernetes.
  # - `github`: Provider to manage GitHub resources.
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.47.0"
    }

    random = {
      source  = "hashicorp/random"
      version = "~> 3.6.1"
    }

    tls = {
      source  = "hashicorp/tls"
      version = "~> 4.0.5"
    }

    flux = {
      source  = "fluxcd/flux"
      version = ">= 1.2"
    }

    github = {
      source  = "integrations/github"
      version = ">= 6.1"
    }
  }

  required_version = "~> 1.3"
}

# Configuration of providers for the infrastructure

# AWS provider
provider "aws" {
  region = var.region
}

# Kubernetes Provider: Configured to connect to the Kubernetes cluster in EKS using the cluster's endpoint, 
# authentication token, and the cluster authority certificate obtained from the EKS cluster data.
provider "kubernetes" {
  host              = data.aws_eks_cluster.cluster.endpoint
  token             = data.aws_eks_cluster_auth.cluster.token
  cluster_ca_certificate = base64decode(data.aws_eks_cluster.cluster.certificate_authority[0].data)
}

# GitHub Provider.
provider "github" {
  owner = var.github_org
  token = var.github_token
}


# Configuration of providers and resources for Flux CD and Kubernetes
#
# 
# - Flux Provider: Configured to interact with the Kubernetes cluster and the Git repository that contains the configuration manifests.
#   - Kubernetes Configuration: The EKS cluster endpoint, authentication token, and authority certificate are used to connect to Kubernetes.
#   - Git Configuration: The URL of the Git repository is set, along with the necessary credentials (username and token) to access the repository. 
#                        This allows Flux CD to synchronize and deploy configurations from the Git repository.
#
# - Kubernetes Namespace: The `flux-system` namespace is created in Kubernetes, which is used by Flux CD to manage and store its own configuration and synchronization resources.

provider "flux" {
  kubernetes = {
    host                   = data.aws_eks_cluster.cluster.endpoint
    cluster_ca_certificate = base64decode(data.aws_eks_cluster.cluster.certificate_authority[0].data)
    token                  = data.aws_eks_cluster_auth.cluster.token
  }

  git = {
    url = "https://github.com/${var.github_org}/${var.github_repository}.git"
    http = {
      username = "git" # Este puede ser cualquier string al usar un personal access token
      password = var.github_token
    }
  }
}



resource "kubernetes_namespace" "flux_system" {
  metadata {
    name = "flux-system"
    labels = {
      "app.kubernetes.io/instance"            = "flux-system"
      "app.kubernetes.io/part-of"             = "flux"
      "app.kubernetes.io/version"             = "v2.3.0"
      "kustomize.toolkit.fluxcd.io/name"      = "flux-system"
      "kustomize.toolkit.fluxcd.io/namespace" = "flux-system"
    }
  }
}

# Configuration of providers and necessary data for Helm and EKS
#
# - Helm Provider:
#   - Kubernetes Config: Configures the Helm provider to use the Kubernetes configuration file (`~/.kube/config`), 
#                        which contains the connection information to the Kubernetes cluster. This allows Helm to interact with the cluster to install and manage charts.
#                        To do this, kubectl must have been previously configured to connect to the cluster.

provider "helm" {
  kubernetes {
    config_path = "~/.kube/config"  
  }
}

# AWS EKS Data Sources:
#   - aws_eks_cluster: Retrieves information about the EKS cluster using the cluster name provided by the `eks` module. This includes details like the cluster endpoint and authority certificate.
#   - aws_eks_cluster_auth: Retrieves authentication information for the EKS cluster, such as the access token required to authenticate Kubernetes API requests.

data "aws_eks_cluster" "cluster" {
  name = module.eks.cluster_name
}

data "aws_eks_cluster_auth" "cluster" {
  name = module.eks.cluster_name
}

