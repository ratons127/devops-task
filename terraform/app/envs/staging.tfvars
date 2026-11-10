environment        = "staging"
instance_type      = "t3.micro"
log_retention_days = 7
log_level          = "DEBUG"
# Replace with your own public IP (curl ifconfig.me) for testing.
allowed_ingress_cidrs = ["0.0.0.0/0"]
