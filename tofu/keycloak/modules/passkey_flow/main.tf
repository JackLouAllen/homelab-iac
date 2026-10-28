# A browser flow: an existing session (cookie), or a password followed by a passkey. Bound as the
# realm's browser flow, so the realm resource must ignore changes to its own browser_flow argument.
resource "keycloak_authentication_flow" "this" {
  realm_id    = var.realm_id
  alias       = var.alias
  description = "Cookie, or password followed by a passkey. Managed by OpenTofu."
}

resource "keycloak_authentication_execution" "cookie" {
  realm_id          = var.realm_id
  parent_flow_alias = keycloak_authentication_flow.this.alias
  authenticator     = "auth-cookie"
  requirement       = "ALTERNATIVE"
}

resource "keycloak_authentication_subflow" "forms" {
  realm_id          = var.realm_id
  parent_flow_alias = keycloak_authentication_flow.this.alias
  alias             = "${var.alias} forms"
  provider_id       = "basic-flow"
  requirement       = "ALTERNATIVE"

  depends_on = [keycloak_authentication_execution.cookie]
}

resource "keycloak_authentication_execution" "password" {
  realm_id          = var.realm_id
  parent_flow_alias = keycloak_authentication_subflow.forms.alias
  authenticator     = "auth-username-password-form"
  requirement       = "REQUIRED"
}

# Strict: the passkey step sits directly in the flow.
resource "keycloak_authentication_execution" "passkey_strict" {
  count = var.strict ? 1 : 0

  realm_id          = var.realm_id
  parent_flow_alias = keycloak_authentication_subflow.forms.alias
  authenticator     = "webauthn-authenticator"
  requirement       = "REQUIRED"

  depends_on = [keycloak_authentication_execution.password]
}

# Not strict: the passkey step runs only for a user who has one ("condition - user configured").
resource "keycloak_authentication_subflow" "second_factor" {
  count = var.strict ? 0 : 1

  realm_id          = var.realm_id
  parent_flow_alias = keycloak_authentication_subflow.forms.alias
  alias             = "${var.alias} second factor"
  provider_id       = "basic-flow"
  requirement       = "CONDITIONAL"

  depends_on = [keycloak_authentication_execution.password]
}

resource "keycloak_authentication_execution" "user_configured" {
  count = var.strict ? 0 : 1

  realm_id          = var.realm_id
  parent_flow_alias = keycloak_authentication_subflow.second_factor[0].alias
  authenticator     = "conditional-user-configured"
  requirement       = "REQUIRED"
}

resource "keycloak_authentication_execution" "passkey_if_configured" {
  count = var.strict ? 0 : 1

  realm_id          = var.realm_id
  parent_flow_alias = keycloak_authentication_subflow.second_factor[0].alias
  authenticator     = "webauthn-authenticator"
  requirement       = "REQUIRED"

  depends_on = [keycloak_authentication_execution.user_configured]
}

resource "keycloak_authentication_bindings" "this" {
  realm_id     = var.realm_id
  browser_flow = keycloak_authentication_flow.this.alias

  depends_on = [
    keycloak_authentication_execution.passkey_strict,
    keycloak_authentication_execution.passkey_if_configured,
  ]
}
