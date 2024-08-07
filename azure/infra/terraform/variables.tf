variable "location" {
  description = "The location/region where the AKS cluster will be created."
  type        = string
  default     = "eastus"
}

variable "psql_admin_user" {
  description = "The PostgreSQL admin user."
  type        = string
  default     = "psqladmin"
}