variable "realm_id" {
  type = string
}

variable "alias" {
  description = "Name of the browser flow this creates and binds."
  type        = string
}

variable "strict" {
  description = <<-EOT
    false: a user who has a passkey must use it, and a user with none signs in with the password alone
    (so a new admin can sign in once to register one; used for the master realm).
    true: every user must use a passkey; Keycloak asks a user who has none to register one.
  EOT
  type        = bool
  default     = false
}
