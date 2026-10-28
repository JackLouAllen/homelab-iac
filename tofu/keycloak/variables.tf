variable "keycloak_url" {
  description = "Where the provider reaches Keycloak: the private admin name, over the tailnet."
  type        = string
  default     = "https://auth-admin.vaultnet.xyz"
}

variable "keycloak_version" {
  description = "Keycloak server version the provider should assume (see versions.tf)."
  type        = string
  default     = "26.8.1"
}

variable "keycloak_additional_headers" {
  description = "Extra HTTP headers on every request. Empty except in the local test bench."
  type        = map(string)
  default     = {}
}

variable "public_hostname" {
  description = "Public name for logins: the hostname of every realm except master."
  type        = string
  default     = "auth.jacklouallen.info"
}

variable "admin_hostname" {
  description = "Private name of the master realm and the admin console (tailnet only)."
  type        = string
  default     = "auth-admin.vaultnet.xyz"
}

variable "app_realm" {
  description = "The realm that holds the users and clients of the homelab's services."
  type        = string
  default     = "homelab"
}

variable "app_realm_display_name" {
  type    = string
  default = "Homelab"
}
