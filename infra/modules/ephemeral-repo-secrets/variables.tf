# Ephemeral Repo Secrets Module - Variables

variable "repo_full_name" {
  description = "Full repository name (owner/repo)"
  type        = string

  validation {
    condition     = can(regex("^[^/]+/[^/]+$", var.repo_full_name))
    error_message = "repo_full_name must be in the format 'owner/repo'"
  }
}

variable "secrets" {
  description = "Direct secret values to store (will be stored in Secrets Manager)"
  type        = map(string)
  default     = {}
  sensitive   = true
}

variable "secrets_manager_refs" {
  description = "References to existing Secrets Manager secrets (env_var_name = secret_arn)"
  type        = map(string)
  default     = {}
}

variable "ssm_refs" {
  description = "References to existing SSM parameters (env_var_name = parameter_path)"
  type        = map(string)
  default     = {}
}

variable "name_prefix" {
  description = "Prefix for resource names"
  type        = string
  default     = "ephemeral-env"
}

variable "tags" {
  description = "Additional tags for resources"
  type        = map(string)
  default     = {}
}
