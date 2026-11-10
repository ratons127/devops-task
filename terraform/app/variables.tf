variable "region" {
  type    = string
  default = "ap-south-1"
}

variable "project" {
  type    = string
  default = "devops-task"
}

variable "environment" {
  description = "Deployment environment."
  type        = string
  validation {
    condition     = contains(["staging", "production"], var.environment)
    error_message = "environment must be staging or production."
  }
}

variable "instance_type" {
  type    = string
  default = "t3.micro"
}

variable "root_volume_size" {
  description = "Root EBS volume size in GiB."
  type        = number
  default     = 16
}

variable "host_port" {
  description = "Port exposed on the instance (container listens on 8080)."
  type        = number
  default     = 80
}

variable "allowed_ingress_cidrs" {
  description = "CIDRs allowed to reach the app port. Restrict this to your IP for testing."
  type        = list(string)
}

variable "log_retention_days" {
  type    = number
  default = 14
}

variable "log_level" {
  type    = string
  default = "INFO"
}

variable "ecr_repository_name" {
  type    = string
  default = "devops-task-app"
}

variable "app_image" {
  description = "Optional image to start on first boot. Normally left empty; CI deploys the image."
  type        = string
  default     = ""
}
