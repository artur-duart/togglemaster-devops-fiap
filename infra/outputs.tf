output "vpc_id" {
  description = "ID da VPC criada."
  value       = module.vpc.vpc_id
}

output "public_subnet_ids" {
  description = "IDs das subnets publicas (EKS e Load Balancers)."
  value       = module.vpc.public_subnets
}

output "private_subnet_ids" {
  description = "IDs das subnets privadas (RDS e ElastiCache)."
  value       = module.vpc.private_subnets
}
