# The realm for the people and services of the homelab: GitLab and the Wazuh dashboard sign in here
# (their clients are added when those services exist). Logins use the public name, so unlike the
# master realm this one has no frontend URL of its own.
resource "keycloak_realm" "homelab" {
  realm        = var.app_realm
  enabled      = true
  display_name = var.app_realm_display_name
  ssl_required = "external"

  # No mail server yet: self-service registration and password reset would send nothing.
  registration_allowed     = false
  reset_password_allowed   = false
  verify_email             = false
  login_with_email_allowed = true
  duplicate_emails_allowed = false
  remember_me              = false

  password_policy = "length(14) and notUsername and notEmail and passwordHistory(3)"

  security_defenses {
    brute_force_detection {
      permanent_lockout                = false
      brute_force_strategy             = "LINEAR"
      max_login_failures               = 5
      wait_increment_seconds           = 60
      max_failure_wait_seconds         = 900
      failure_reset_time_seconds       = 43200
      quick_login_check_milli_seconds  = 1000
      minimum_quick_login_wait_seconds = 60
      max_secondary_auth_failures      = 0
    }
  }

  web_authn_policy {
    relying_party_entity_name         = var.app_realm_display_name
    relying_party_id                  = var.public_hostname
    signature_algorithms              = ["ES256", "RS256"]
    attestation_conveyance_preference = "not specified"
    authenticator_attachment          = "cross-platform"
    user_verification_requirement     = "preferred"
    avoid_same_authenticator_register = true
    create_timeout                    = 0
  }

  lifecycle {
    prevent_destroy = true
    ignore_changes  = [browser_flow]
  }
}

resource "keycloak_realm_events" "homelab" {
  realm_id = keycloak_realm.homelab.id

  events_enabled    = true
  events_expiration = 7776000 # 90 days

  admin_events_enabled         = true
  admin_events_details_enabled = false

  enabled_event_types = [
    "LOGIN", "LOGIN_ERROR", "LOGOUT", "LOGOUT_ERROR",
    "CODE_TO_TOKEN", "CODE_TO_TOKEN_ERROR", "CLIENT_LOGIN", "CLIENT_LOGIN_ERROR",
    "UPDATE_PASSWORD", "UPDATE_PASSWORD_ERROR", "UPDATE_TOTP", "REMOVE_TOTP",
    "UPDATE_CREDENTIAL", "REMOVE_CREDENTIAL", "RESET_PASSWORD", "RESET_PASSWORD_ERROR",
    "USER_DISABLED_BY_PERMANENT_LOCKOUT", "USER_DISABLED_BY_TEMPORARY_LOCKOUT",
  ]

  events_listeners = ["jboss-logging"]
}

resource "keycloak_required_action" "homelab_webauthn_register" {
  realm_id = keycloak_realm.homelab.realm
  alias    = "webauthn-register"
  name     = "Webauthn Register"
  enabled  = true
}

resource "keycloak_default_roles" "homelab" {
  realm_id = keycloak_realm.homelab.id
  default_roles = [
    "offline_access",
    "uma_authorization",
    "account/view-profile",
    "account/manage-account",
  ]
}

# Every user needs a passkey here, and Keycloak asks for one at first sign-in.
module "browser_flow_homelab" {
  source = "./modules/passkey_flow"

  realm_id = keycloak_realm.homelab.id
  alias    = "browser-passkey"
  strict   = true
}
