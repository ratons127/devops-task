environment        = "production"
instance_type      = "t3.small"
log_retention_days = 30
log_level          = "INFO"
root_volume_size   = 20
# Real production would sit behind an ALB; only the ALB security group would be allowed here.
allowed_ingress_cidrs = ["0.0.0.0/0"]
