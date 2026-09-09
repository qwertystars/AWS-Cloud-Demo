variable "region" {
  description = "AWS region for the classroom demo."
  type        = string
  default     = "ap-south-1"
}

variable "project_prefix" {
  description = "Unique prefix for this demo's resources (maximum 24 characters)."
  type        = string
  default     = "aws-class-demo"
  validation {
    condition     = can(regex("^[a-z][a-z0-9-]{0,22}[a-z0-9]$", var.project_prefix))
    error_message = "Use 2–24 lowercase letters, numbers or hyphens; start with a letter and end with a letter or number."
  }
}

variable "desired_count" {
  description = "Number of tasks; at least two are needed to demonstrate balancing."
  type        = number
  default     = 2
  validation {
    condition     = var.desired_count >= 2 && var.desired_count <= 4 && floor(var.desired_count) == var.desired_count
    error_message = "Choose an integer from 2 to 4 to keep this demo small."
  }
}

variable "task_cpu" {
  description = "Fargate CPU units; deliberately limited to small classroom sizes."
  type        = number
  default     = 256
  validation {
    condition     = contains([256, 512], var.task_cpu)
    error_message = "Use 256 or 512 CPU units."
  }
}

variable "task_memory" {
  description = "Fargate memory in MiB."
  type        = number
  default     = 512
  validation {
    condition     = (var.task_cpu == 256 && contains([512, 1024, 2048], var.task_memory)) || (var.task_cpu == 512 && contains([1024, 2048, 3072, 4096], var.task_memory))
    error_message = "CPU 256 supports 512/1024/2048 MiB; CPU 512 supports 1024/2048/3072/4096 MiB."
  }
}
