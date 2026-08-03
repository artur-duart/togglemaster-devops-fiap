module "eks" {
  source  = "terraform-aws-modules/eks/aws"
  version = "~> 21.0"

  name               = "togglemaster"
  kubernetes_version = "1.34"

  vpc_id                 = module.vpc.vpc_id
  subnet_ids             = module.vpc.public_subnets
  endpoint_public_access = true

  enable_cluster_creator_admin_permissions = true

  addons = {
    vpc-cni = {
      before_compute = true
    }
    kube-proxy = {}
    coredns    = {}
  }

  eks_managed_node_groups = {
    default = {
      subnet_ids     = module.vpc.private_subnets
      instance_types = ["t3.medium"]
      min_size       = 1
      desired_size   = 2
      max_size       = 3
    }
  }
}
