variable "region" {
  description = "AWS region"
  type        = string
  default     = "eu-west-1"
}

variable "github_token" {
  description = "GitHub token"
  sensitive   = true
  type        = string
  default     = ""
}

variable "github_org" {
  description = "GitHub organization"
  type        = string
  default     = "nstrlabs"
}

variable "github_repository" {
  description = "GitHub repository"
  type        = string
  default     = "proof-sre-candidate-guillermo-muriel"
}