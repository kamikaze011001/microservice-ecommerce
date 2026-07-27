---
name: rds-replica-inherits-source-parameter-groups
description: terraform-aws-modules/rds read-replica block must set create_db_option_group=false + create_db_parameter_group=false, or apply fails on missing engine metadata
metadata: { type: convention, date: 2026-07-24 }
---

`aws/main/rds.tf` PART D (`module "rds_replica"`) is a cross-region-style read
replica of the primary. The `terraform-aws-modules/rds/aws` module **defaults**
`create_db_option_group = true` and `create_db_parameter_group = true`. Those
submodules require `engine_name` / `major_engine_version` / `family` — which a
replica block legitimately omits (a replica inherits the source DB's engine). So a
bare replica block fails `terraform apply` with:

```
Missing required argument: "engine_name" (in module.rds_replica.module.db_option_group)
Missing required argument: "family"      (in module.rds_replica.module.db_parameter_group)
```

**Fix (persisted, lines 127–128 of rds.tf):**
```hcl
create_db_option_group    = false   # replica inherits the source's option group
create_db_parameter_group = false   # replica inherits the source's parameter group
```

A read replica shares its source's option/parameter groups by design, so creating
new empty ones for it is both wrong and impossible-without-engine-metadata. Set both
to `false` and the replica inherits from the primary. Applies to any replica built
with this module.
