terraform {
  backend "s3" {
    bucket = "rndx-terraform-backend"
    key    = "terraform-env"
    region = "ap-northeast-2"
  }
}

locals {
  env_name         = "staging"
  aws_region       = "ap-northeast-2"
  k8s_cluster_name = "ms-cluster"
}

variable "mysql_password" {
  type        = string
  description = "Expected to be retrieved from environment variable TF_VAR_mysql_password"
}

provider "aws" {
  region = local.aws_region
}

data "aws_eks_cluster" "msur" {
  name = module.aws-kubernetes-cluster.eks_cluster_id
}

# Network Configuration
module "aws-network" {
  source = "github.com/devrndx/module-aws-network"

  env_name              = local.env_name
  vpc_name              = "msur-VPC"
  cluster_name          = local.k8s_cluster_name
  aws_region            = local.aws_region
  main_vpc_cidr         = "10.10.0.0/16"
  public_subnet_a_cidr  = "10.10.0.0/18"
  public_subnet_b_cidr  = "10.10.64.0/18"
  private_subnet_a_cidr = "10.10.128.0/18"
  private_subnet_b_cidr = "10.10.192.0/18"
}

# EKS Configuration 
module "aws-kubernetes-cluster" {
  source = "github.com/devrndx/module-aws-kubernetes"

  ms_namespace       = "microservices"
  env_name           = local.env_name
  aws_region         = local.aws_region
  cluster_name       = local.k8s_cluster_name
  vpc_id             = module.aws-network.vpc_id
  cluster_subnet_ids = module.aws-network.subnet_ids


  nodegroup_subnet_ids     = module.aws-network.private_subnet_ids
  nodegroup_disk_size      = "20"
  nodegroup_instance_types = ["t3.medium"]
  nodegroup_desired_size   = 1
  nodegroup_min_size       = 1
  nodegroup_max_size       = 5
}

# Create namespace
# Use kubernetes provider to work with the kubernetes cluster API
provider "kubernetes" {
  #  load_config_file       = false
  cluster_ca_certificate = base64decode(data.aws_eks_cluster.msur.certificate_authority.0.data)
  host                   = data.aws_eks_cluster.msur.endpoint
  exec {
    api_version = "client.authentication.k8s.io/v1alpha1"
    command     = "aws-iam-authenticator"
    args        = ["token", "-i", "${data.aws_eks_cluster.msur.name}"]
  }
}

# Create a namespace for microservice pods
resource "kubernetes_namespace" "ms-namespace" {
  metadata {
    name = "microservices"
  }
}

# GitOps Configuration
module "argo-cd-server" {
  source = "github.com/devrndx/module-argo-cd"

  aws_region            = local.aws_region
  kubernetes_cluster_id = data.aws_eks_cluster.msur.id

  kubernetes_cluster_name      = module.aws-kubernetes-cluster.eks_cluster_name
  kubernetes_cluster_cert_data = module.aws-kubernetes-cluster.eks_cluster_certificate_data
  kubernetes_cluster_endpoint  = module.aws-kubernetes-cluster.eks_cluster_endpoint

  eks_nodegroup_id = module.aws-kubernetes-cluster.eks_cluster_nodegroup_id
}

# Create Traefik
module "traefik" {
  source = "github.com/devrndx/ms-traefik"

  aws_region                   = local.aws_region
  kubernetes_cluster_id        = data.aws_eks_cluster.msur.id
  kubernetes_cluster_name      = module.aws-kubernetes-cluster.eks_cluster_name
  kubernetes_cluster_cert_data = module.aws-kubernetes-cluster.eks_cluster_certificate_data
  kubernetes_cluster_endpoint  = module.aws-kubernetes-cluster.eks_cluster_endpoint

  eks_nodegroup_id = module.aws-kubernetes-cluster.eks_cluster_nodegroup_id
}
