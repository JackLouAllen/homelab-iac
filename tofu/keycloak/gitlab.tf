# GitLab signs in through this client. Confidential (it has a secret GitLab keeps), authorization code
# flow with PKCE, nothing else: no password grant, no service account, no implicit flow.
resource "keycloak_openid_client" "gitlab" {
  realm_id  = keycloak_realm.homelab.id
  client_id = "gitlab"
  name      = "GitLab"
  enabled   = true

  access_type                  = "CONFIDENTIAL"
  standard_flow_enabled        = true
  implicit_flow_enabled        = false
  direct_access_grants_enabled = false
  service_accounts_enabled     = false
  pkce_code_challenge_method   = "S256"

  # Exactly the one callback. No wildcards: a loose redirect list is how codes get stolen.
  valid_redirect_uris = ["https://${var.gitlab_hostname}/users/auth/openid_connect/callback"]
  root_url            = "https://${var.gitlab_hostname}"
  base_url            = "https://${var.gitlab_hostname}"
  web_origins         = []

  # GitLab does not use Keycloak's roles; keep them out of its tokens.
  full_scope_allowed = false
}

# A new client inherits the realm's default scopes (acr, basic, email, profile, roles, web-origins; checked
# on a bare client). GitLab needs three: the subject (basic), the name and username (profile) and the
# email address (email). Naming them narrows the client to those, so no roles claim or other extras go to it.
resource "keycloak_openid_client_default_scopes" "gitlab" {
  realm_id  = keycloak_realm.homelab.id
  client_id = keycloak_openid_client.gitlab.id

  default_scopes = ["basic", "profile", "email"]
}

# Copy this into gitlab.sops.yml as gitlab_oidc_secret (tofu output -raw gitlab_client_secret).
output "gitlab_client_secret" {
  value     = keycloak_openid_client.gitlab.client_secret
  sensitive = true
}
