resource "aws_elasticache_subnet_group" "this" {
  name       = "togglemaster-redis"
  subnet_ids = module.vpc.private_subnets
}

resource "aws_security_group" "redis" {
  name        = "togglemaster-redis"
  description = "Libera Redis (6379) apenas a partir dos nos do EKS"
  vpc_id      = module.vpc.vpc_id
}

resource "aws_vpc_security_group_ingress_rule" "redis" {
  security_group_id            = aws_security_group.redis.id
  from_port                    = 6379
  to_port                      = 6379
  ip_protocol                  = "tcp"
  referenced_security_group_id = module.eks.node_security_group_id
}

resource "aws_elasticache_replication_group" "this" {
  replication_group_id = "togglemaster-redis"
  description          = "Redis do evaluation-service"
  engine               = "redis"
  engine_version       = "7.1"
  node_type            = "cache.t3.micro"
  num_cache_clusters   = 1
  port                 = 6379

  subnet_group_name          = aws_elasticache_subnet_group.this.name
  security_group_ids         = [aws_security_group.redis.id]
  at_rest_encryption_enabled = true
}
