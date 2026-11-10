# Per-environment deployment target: one EC2 instance running the app container.
# The same code serves staging and production; differences live in envs/<env>.tfvars
# and each environment has its own state key (envs/<env>.backend.hcl).

terraform {
  required_version = ">= 1.10.0"
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = ">= 5.80, < 7.0"
    }
  }
  backend "s3" {
    use_lockfile = true
    encrypt      = true
  }
}

provider "aws" {
  region = var.region
  default_tags {
    tags = {
      Project     = var.project
      Environment = var.environment
      ManagedBy   = "terraform"
      Stack       = "app"
    }
  }
}

locals {
  name      = "${var.project}-${var.environment}"
  log_group = "/${var.project}/${var.environment}/app"
}

# ---------------------------------------------------------------------------
# Network: default VPC (acceptable per the brief)
# ---------------------------------------------------------------------------
data "aws_vpc" "default" {
  default = true
}

data "aws_subnets" "default" {
  filter {
    name   = "vpc-id"
    values = [data.aws_vpc.default.id]
  }
  filter {
    name   = "default-for-az"
    values = ["true"]
  }
}

resource "aws_security_group" "app" {
  name        = "${local.name}-app"
  description = "${local.name}: HTTP to the app only. No SSH - administration is via SSM."
  vpc_id      = data.aws_vpc.default.id
}

resource "aws_vpc_security_group_ingress_rule" "http" {
  for_each          = toset(var.allowed_ingress_cidrs)
  security_group_id = aws_security_group.app.id
  description       = "App HTTP"
  ip_protocol       = "tcp"
  from_port         = var.host_port
  to_port           = var.host_port
  cidr_ipv4         = each.value
}

# Outbound HTTPS is required to reach ECR, SSM and CloudWatch Logs endpoints.
# (In production this could be narrowed further with VPC endpoints.)
resource "aws_vpc_security_group_egress_rule" "https" {
  security_group_id = aws_security_group.app.id
  description       = "HTTPS to AWS APIs / ECR"
  ip_protocol       = "tcp"
  from_port         = 443
  to_port           = 443
  cidr_ipv4         = "0.0.0.0/0"
}

# dnf package repositories on Amazon Linux are served over HTTP(S); allow HTTP for mirrors.
resource "aws_vpc_security_group_egress_rule" "http" {
  security_group_id = aws_security_group.app.id
  description       = "HTTP for OS package mirrors"
  ip_protocol       = "tcp"
  from_port         = 80
  to_port           = 80
  cidr_ipv4         = "0.0.0.0/0"
}

# ---------------------------------------------------------------------------
# Logs
# ---------------------------------------------------------------------------
resource "aws_cloudwatch_log_group" "app" {
  name              = local.log_group
  retention_in_days = var.log_retention_days
}

# ---------------------------------------------------------------------------
# IAM: instance profile with the minimum the host needs
# ---------------------------------------------------------------------------
data "aws_ecr_repository" "app" {
  name = var.ecr_repository_name
}

data "aws_iam_policy_document" "ec2_trust" {
  statement {
    actions = ["sts:AssumeRole"]
    principals {
      type        = "Service"
      identifiers = ["ec2.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "instance" {
  name               = "${local.name}-instance"
  assume_role_policy = data.aws_iam_policy_document.ec2_trust.json
}

# Required for SSM Run Command / Session Manager (replaces SSH entirely).
resource "aws_iam_role_policy_attachment" "ssm_core" {
  role       = aws_iam_role.instance.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore"
}

data "aws_iam_policy_document" "instance" {
  statement {
    sid       = "EcrAuth"
    actions   = ["ecr:GetAuthorizationToken"]
    resources = ["*"]
  }
  statement {
    sid = "EcrPullAppRepoOnly"
    actions = [
      "ecr:BatchCheckLayerAvailability",
      "ecr:BatchGetImage",
      "ecr:GetDownloadUrlForLayer",
    ]
    resources = [data.aws_ecr_repository.app.arn]
  }
  statement {
    sid = "WriteOwnLogGroupOnly"
    actions = [
      "logs:CreateLogStream",
      "logs:PutLogEvents",
      "logs:DescribeLogStreams",
    ]
    resources = ["${aws_cloudwatch_log_group.app.arn}:*"]
  }
}

resource "aws_iam_role_policy" "instance" {
  name   = "app-least-privilege"
  role   = aws_iam_role.instance.id
  policy = data.aws_iam_policy_document.instance.json
}

resource "aws_iam_instance_profile" "app" {
  name = "${local.name}-instance"
  role = aws_iam_role.instance.name
}

# ---------------------------------------------------------------------------
# Compute
# ---------------------------------------------------------------------------
data "aws_ssm_parameter" "al2023" {
  name = "/aws/service/ami-amazon-linux-latest/al2023-ami-kernel-default-x86_64"
}

resource "aws_instance" "app" {
  ami                    = data.aws_ssm_parameter.al2023.value
  instance_type          = var.instance_type
  subnet_id              = data.aws_subnets.default.ids[0]
  vpc_security_group_ids = [aws_security_group.app.id]
  iam_instance_profile   = aws_iam_instance_profile.app.name

  user_data = templatefile("${path.module}/user_data.sh.tftpl", {
    aws_region        = var.region
    app_env           = var.environment
    log_group         = aws_cloudwatch_log_group.app.name
    log_level         = var.log_level
    host_port         = var.host_port
    app_image         = var.app_image
    deploy_script_b64 = base64encode(file("${path.module}/../../scripts/deploy.sh"))
  })
  user_data_replace_on_change = true

  # IMDSv2 only; hop limit 1 so containers cannot reach instance credentials.
  metadata_options {
    http_tokens                 = "required"
    http_put_response_hop_limit = 1
    http_endpoint               = "enabled"
  }

  root_block_device {
    volume_type = "gp3"
    volume_size = var.root_volume_size
    encrypted   = true
  }

  tags = {
    Name = local.name
  }

  lifecycle {
    # A new AMI release should not force-replace a running instance on every plan.
    ignore_changes = [ami]
  }

  depends_on = [aws_iam_role_policy_attachment.ssm_core]
}
