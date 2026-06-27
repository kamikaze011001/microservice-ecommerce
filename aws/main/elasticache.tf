# aws/main/elasticache.tf  —  [CHECKPOINT — HUMAN ✍️]  (Phase 4b)
#
# WHY THIS FILE EXISTS
# Three services (authorization-server, order-service, inventory-service) gate
# their readiness probe on a live Redis (readiness.include: ...,redis). Until now
# Redis ran as a self-hosted in-cluster Deployment (redis-master.infra). We're
# swapping that for managed Amazon ElastiCache. The apps don't change — they read
# spring.data.redis.host from Secrets Manager, and seed-secrets.sh (Task 3, Claude)
# will point it at the ElastiCache endpoint.
#
# The whole substitution is two moves, and THIS FILE is move #1:
#   move #1 (here):        Terraform creates ElastiCache + a security group that
#                          admits the EKS node SG on 6379.
#   move #2 (seed-secrets): swap the in-cluster DNS host for the ElastiCache endpoint.
#
# Network model — identical to rds.tf (the "IAM of the network" beat):
# ElastiCache lives in the VPC private subnets with NO public access. It is
# reachable ONLY because its security group allows inbound 6379 from the EKS *node*
# security group. SG-to-SG, never a CIDR — the rule follows the nodes as they
# scale/replace. (Exactly what you did for RDS on 3306.)
#
# SECURITY POSTURE — Phase 4b is Option A: transit_encryption_enabled = false and
# NO auth token. This is EXACT local parity (the in-cluster redis is a pure cache,
# no auth, no TLS) and the smallest change to go green. TLS + RedisAUTH are coupled
# on ElastiCache (a token requires transit encryption) and need a core-redis
# rediss:// code change — deliberately deferred to Phase 4d.
#
# ─────────────────────────────────────────────────────────────────────────────
# PART A — [HUMAN ✍️]  the cache security group   resource "aws_security_group" "redis"
#   - vpc_id = module.vpc.vpc_id
#   - ONE ingress rule: protocol "tcp", from_port/to_port = 6379,
#       security_groups = [module.eks.node_security_group_id]   # NOT a cidr_block
#   - egress all: from/to 0, protocol "-1", cidr_blocks = ["0.0.0.0/0"]
# TODO(HUMAN): write resource "aws_security_group" "redis" here
resource "aws_security_group" "redis" {
  vpc_id = module.vpc.vpc_id
  ingress {
    protocol        = "tcp"
    from_port       = 6379
    to_port         = 6379
    security_groups = [module.eks.node_security_group_id]
  }
  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }
}

resource "random_password" "redis_auth" {
  length           = 32
  special          = true
  override_special = "!#$^&*-_=+"
}
# ─────────────────────────────────────────────────────────────────────────────
# PART B — [HUMAN ✍️]  the cache subnet group   resource "aws_elasticache_subnet_group" "main"
#   - name        = "${var.project}-redis"
#   - subnet_ids  = module.vpc.private_subnets    # >=2 AZs, same as the DB subnet group.
#       (Nodes are pinned to private_subnets[0]; ElastiCache is NOT AZ-locked like
#        EBS, so cross-AZ reach from the node to the cache is fine.)
# TODO(HUMAN): write resource "aws_elasticache_subnet_group" "main" here
resource "aws_elasticache_subnet_group" "main" {
  name       = "${var.project}-redis"
  subnet_ids = module.vpc.private_subnets
}
# ─────────────────────────────────────────────────────────────────────────────
# PART C — [HUMAN ✍️]  the Redis node   resource "aws_elasticache_replication_group" "redis"
#   Requirements:
#     - replication_group_id      = "${var.project}-redis"
#     - description                = "microecom cache (Phase 4b, single node)"
#     - engine="redis", engine_version="7.1"
#     - node_type="cache.t4g.micro"            (Graviton, matches the t4g theme)
#     - num_cache_clusters         = 1          (single node — no replica in 4b)
#     - automatic_failover_enabled = false      (required false for a single node)
#     - transit_encryption_enabled = false      (Option A — local parity, no app change)
#     - port                       = 6379
#     - parameter_group_name       = "default.redis7"
#     - subnet_group_name          = aws_elasticache_subnet_group.main.name
#     - security_group_ids         = [aws_security_group.redis.id]
#   🎓 Why aws_elasticache_replication_group with num_cache_clusters=1 (not the
#     simpler aws_elasticache_cluster): the replication group exposes a stable
#     primary_endpoint_address regardless of node count. Phase 4d (add a replica)
#     becomes a one-number change and the endpoint the app reads never moves.
#   Docs: https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/elasticache_replication_group
# TODO(HUMAN): write resource "aws_elasticache_replication_group" "redis" here
resource "aws_elasticache_replication_group" "redis" {
  replication_group_id       = "${var.project}-redis"
  description                = "microecom cache (Phase 4b, single node, TLS+AUTH)"
  engine                     = "redis"
  engine_version             = "7.1"
  node_type                  = "cache.t4g.micro"
  num_cache_clusters         = 1
  automatic_failover_enabled = false
  transit_encryption_enabled = true
  auth_token                 = random_password.redis_auth.result
  port                       = 6379
  parameter_group_name       = "default.redis7"
  subnet_group_name          = aws_elasticache_subnet_group.main.name
  security_group_ids         = [aws_security_group.redis.id]
}
# ─────────────────────────────────────────────────────────────────────────────
# PART D — [HUMAN ✍️]  output (seed-secrets.sh reads this)
#   output "redis_primary_endpoint" {
#     value = aws_elasticache_replication_group.redis.primary_endpoint_address
#   }
#   NOTE: primary_endpoint_address is host only (no :6379). seed-secrets.sh sets
#   spring.data.redis.port separately — keep this host-only, same as rds.tf.
#
# 🎓 Interview prep — be ready to explain:
#   - SG-to-SG ingress on 6379 vs a CIDR allowlist (follows the nodes; no IP drift).
#   - Why ElastiCache is NOT AZ-locked the way an EBS volume is.
#   - Option A vs B: TLS + RedisAUTH are coupled on ElastiCache; enabling them needs
#     a Redisson redis://→rediss:// change in core-redis — that's Phase 4d, not now.
#   - primary_endpoint_address (host) vs configuration_endpoint (cluster mode) —
#     why single-node cluster-mode-disabled uses the primary endpoint.
# TODO(HUMAN): write output "redis_primary_endpoint" here
#
# Write PART A–D above the TODO markers, then tell Claude "review".
# ─────────────────────────────────────────────────────────────────────────────
output "redis_primary_endpoint" {
  value = aws_elasticache_replication_group.redis.primary_endpoint_address
}

# PHASE 4d — TLS in transit + RedisAUTH token. random_password.redis_auth (above)
# feeds auth_token on the replication group; the output below hands the token to
# seed-secrets.sh. ElastiCache couples the two: auth_token requires
# transit_encryption_enabled = true (no "password without TLS").
output "redis_auth_token" {
  value     = random_password.redis_auth.result
  sensitive = true
}
