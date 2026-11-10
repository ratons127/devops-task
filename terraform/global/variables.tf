variable "region" {
  description = "AWS region."
  type        = string
  default     = "ap-south-1"
}

variable "project" {
  description = "Project name; also the value of the Project tag that scopes CI's SSM access."
  type        = string
  default     = "devops-task"
}

variable "github_repository" {
  description = "GitHub repository allowed to assume the CI role, as owner/name."
  type        = string
  validation {
    condition     = can(regex("^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$", var.github_repository))
    error_message = "Must be in the form owner/repo."
  }
}

variable "deploy_environments" {
  description = "GitHub Environments whose deploy jobs may assume the CI role."
  type        = list(string)
  default     = ["staging", "production"]
}

variable "create_github_oidc_provider" {
  description = "Set false if the account already has the GitHub OIDC provider."
  type        = bool
  default     = true
}

variable "ecr_repository_name" {
  type    = string
  default = "devops-task-app"
}

variable "ecr_keep_images" {
  description = "Number of images to retain in ECR."
  type        = number
  default     = 30
}

variable "ecr_force_delete" {
  description = "Allow `terraform destroy` to delete the repo even if it contains images (handy for this assessment)."
  type        = bool
  default     = true
}
