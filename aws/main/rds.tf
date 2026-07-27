# aws/main/rds.tf  —  [CHECKPOINT — HUMAN ✍️]  (Phase 4a, Task 1)
#
# WHY THIS FILE EXISTS
# Until now MySQL ran as a self-hosted StatefulSet pod (master + 2 slaves) backed
# by EBS volumes. We're swapping that for managed Amazon RDS: one primary
# (writes) + one read replica (reads). The apps don't change — they read their
# JDBC URLs from Secrets Manager, and seed-secrets.sh (Task 3, Claude) will point
# spring.datasource.master.* at the primary and slave1/slave2.* at the replica.
#
# The whole substitution is two moves, and THIS FILE is move #1:
#   move #1 (here):        Terraform creates RDS + a security group that admits
#                          the EKS node SG on 3306.
#   move #2 (seed-secrets): swap the in-cluster DNS host for the RDS endpoint.
#
# Network model — the Phase-4 "IAM of the network" beat:
# RDS lives in the VPC private subnets with NO public access. It is reachable
# ONLY because its security group allows inbound 3306 from the EKS *node*
# security group. SG-to-SG, never a CIDR — the rule follows the nodes as they
# scale/replace, so there is no IP to drift. (Same idea you'll repeat for Redis.)
#
# ─────────────────────────────────────────────────────────────────────────────
# PART A — [HUMAN ✍️]  the DB security group   resource "aws_security_group" "rds"
#   - vpc_id = module.vpc.vpc_id
#   - ONE ingress rule: protocol "tcp", from_port/to_port = 3306,
#       security_groups = [module.eks.node_security_group_id]   # NOT a cidr_block
#   - egress all: from/to 0, protocol "-1", cidr_blocks = ["0.0.0.0/0"]
resource "aws_security_group" "rds" {
  vpc_id = module.vpc.vpc_id

  ingress {
    protocol        = "tcp"
    from_port       = 3306
    to_port         = 3306
    security_groups = [module.eks.node_security_group_id]
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }
}
# ─────────────────────────────────────────────────────────────────────────────
# PART B — [HUMAN ✍️]  the DB subnet group   resource "aws_db_subnet_group" "main"
#   - subnet_ids = module.vpc.private_subnets    # BOTH private subnets:
#       RDS requires a subnet group spanning >=2 AZs even for a single-AZ instance.
#       (Our nodes are pinned to private_subnets[0]; RDS is NOT AZ-locked like EBS,
#        so cross-AZ reach from the node to the DB is fine.)
resource "aws_db_subnet_group" "main" {
  subnet_ids = module.vpc.private_subnets
}
# ─────────────────────────────────────────────────────────────────────────────
# PART C — [HUMAN ✍️]  the RDS primary   module "rds"
#   source  = "terraform-aws-modules/rds/aws"
#   version = "~> 6.0"
#   Requirements:
#     - identifier            = "${var.project}-mysql"
#     - engine="mysql", engine_version="8.0", family="mysql8.0", major_engine_version="8.0"
#     - instance_class="db.t4g.micro"   (Graviton, matches the t4g node theme)
#     - allocated_storage=20
#     - db_name="ecommerce_dev", username="admin"   (NOT "root" — RDS reserves it)
#     - password=var.db_master_password, manage_master_user_password=false
#     - port=3306
#     - multi_az=false, publicly_accessible=false        (sandbox cost / security)
#     - create_db_subnet_group=false                     (you made it in PART B)
#     - db_subnet_group_name = aws_db_subnet_group.main.name
#     - vpc_security_group_ids = [aws_security_group.rds.id]
#     - skip_final_snapshot=true, deletion_protection=false  (ephemeral; destroys clean)
#     - backup_retention_period=7  (REQUIRED >0 — PART D's read replica is built from
#         the source's automated backups; 0 => CreateDBInstanceReadReplica fails)
#   Docs: https://registry.terraform.io/modules/terraform-aws-modules/rds/aws/latest
module "rds" {
  source                      = "terraform-aws-modules/rds/aws"
  version                     = "~> 6.0"
  identifier                  = "${var.project}-mysql"
  engine                      = "mysql"
  engine_version              = "8.0"
  family                      = "mysql8.0"
  major_engine_version        = "8.0"
  instance_class              = "db.t4g.micro"
  db_name                     = "ecommerce_dev"
  username                    = "admin"
  password                    = var.db_master_password
  port                        = 3306
  allocated_storage           = 20
  multi_az                    = false
  publicly_accessible         = false
  create_db_subnet_group      = false
  db_subnet_group_name        = aws_db_subnet_group.main.name
  vpc_security_group_ids      = [aws_security_group.rds.id]
  skip_final_snapshot         = true
  deletion_protection         = false
  manage_master_user_password = false
  # A read replica (PART D) is built from the source's automated backups, so the
  # primary MUST have backups on (retention > 0) or CreateDBInstanceReadReplica
  # fails with InvalidDBInstanceState. apply_immediately enables backups on the
  # already-created primary now (brief outage) instead of at the maintenance window.
  backup_retention_period     = 7
  apply_immediately           = true
}
# ─────────────────────────────────────────────────────────────────────────────
# PART D — [HUMAN ✍️]  the read replica   module "rds_replica"
#   Same source/version "~> 6.0". A replica inherits engine/db_name/credentials
#   from its source, so you OMIT db_name/username/password and instead set:
#     - identifier            = "${var.project}-mysql-replica"
#     - replicate_source_db   = module.rds.db_instance_identifier
#     - instance_class="db.t4g.micro", port=3306
#     - create_db_subnet_group=false (same-region replica inherits the source's subnet group — do NOT set db_subnet_group_name)
#     - vpc_security_group_ids = [aws_security_group.rds.id]
#     - skip_final_snapshot=true
#   🎓 Be ready to explain: the app keeps its master/slave routing datasource
#     unchanged — both slave1.url and slave2.url will point at this one replica.
#     "Replica count is config, not code."
module "rds_replica" {
  source                 = "terraform-aws-modules/rds/aws"
  version                = "~> 6.0"
  identifier             = "${var.project}-mysql-replica"
  instance_class         = "db.t4g.micro"
  port                   = 3306
  replicate_source_db    = module.rds.db_instance_identifier
  create_db_subnet_group = false
  # Same-region replica: OMIT db_subnet_group_name — it inherits the source's
  # subnet group. Setting it forces replicate_source_db to be an ARN (provider rule).
  vpc_security_group_ids = [aws_security_group.rds.id]
  skip_final_snapshot    = true
  create_db_option_group    = false   # replica inherits the source's option group
  create_db_parameter_group = false   # replica inherits the source's parameter group
}
# ─────────────────────────────────────────────────────────────────────────────
# PART E — [HUMAN ✍️]  outputs (seed-secrets.sh + seed-rds.sh read these)
#   output "rds_primary_endpoint" { value = module.rds.db_instance_address }
#   output "rds_replica_endpoint" { value = module.rds_replica.db_instance_address }
#   NOTE: db_instance_address = host only (no :3306). The JDBC URL template in
#   seed-secrets.sh adds the port — keep these host-only.
#
# 🎓 Interview prep — be ready to explain:
#   - SG-to-SG ingress vs a CIDR allowlist (follows the nodes; no IP drift).
#   - Why a subnet group needs >=2 AZs even when multi_az=false.
#   - db_instance_address (host) vs db_instance_endpoint (host:port) — why we
#     export the host and let the URL template own the port.
#   - manage_master_user_password=false here: we feed the same password to the
#     seed via a sensitive output (Task 2) so there's ONE source of truth; the
#     RDS-managed-secret alternative adds a second indirection to learn later.
#
# Write PART A–E below, then tell Claude "review".
# (variable "db_master_password" + the sensitive output land in Task 2 — Claude.)
# ─────────────────────────────────────────────────────────────────────────────
output "rds_primary_endpoint" {
  value = module.rds.db_instance_address
}
output "rds_replica_endpoint" {
  value = module.rds_replica.db_instance_address
}