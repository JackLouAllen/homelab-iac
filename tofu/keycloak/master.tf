# The master realm: the admin account, the admin console and this module's own service account
# live here. It exists from Keycloak's first start, so it is imported, never created, and it must
# never be destroyed.
#
# Writing a realm replaces whatever the provider does not know about: an attribute set by hand and
# not declared below is deleted on apply. Compare scripts/keycloak-realm-snapshot.sh output before
# and after the first apply.
import {
  to = keycloak_realm.master
  id = "master"
}

resource "keycloak_realm" "master" {
  realm   = "master"
  enabled = true

  # The console's sign-in follows the realm's frontend URL: with the public name here, the admin
  # console fails with "Timeout when waiting for 3rd party check iframe message" (the master
  # realm is not served on the public name).
  attributes = {
    frontendUrl = "https://${var.admin_hostname}"
  }

  ssl_required = "external"

  security_defenses {
    brute_force_detection {
      # Temporary lockout: a permanent one lets anyone who knows the username lock the admin out.
      permanent_lockout = false
      # Linear: every failure past the threshold lengthens the wait (the default only does at multiples).
      brute_force_strategy             = "LINEAR"
      max_login_failures               = 5
      wait_increment_seconds           = 60
      max_failure_wait_seconds         = 900
      failure_reset_time_seconds       = 43200
      quick_login_check_milli_seconds  = 1000
      minimum_quick_login_wait_seconds = 60
      # 0 disables the permanent lockout after second-factor failures; a passkey cannot be guessed,
      # so the setting would only give an attacker a way to lock the sole admin out.
      max_secondary_auth_failures = 0
    }
  }

  web_authn_policy {
    relying_party_entity_name         = "Homelab"
    relying_party_id                  = var.admin_hostname
    signature_algorithms              = ["ES256", "RS256"]
    attestation_conveyance_preference = "not specified"
    authenticator_attachment          = "cross-platform"
    user_verification_requirement     = "preferred"
    avoid_same_authenticator_register = true
    create_timeout                    = 0
  }

  lifecycle {
    prevent_destroy = true

    # The browser flow is bound by keycloak_authentication_bindings below; the realm resource's own
    # argument defaults to "browser" and would fight it.
    ignore_changes = [browser_flow]
  }
}

# Login and admin events: successful ones reach the journal through the jboss-logging listener
# (see the keycloak role) and from there Wazuh; saving them also keeps a window in the database.
resource "keycloak_realm_events" "master" {
  realm_id = keycloak_realm.master.id

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

# Without this enabled, the account page offers no security key and the WebAuthn authenticator
# cannot ask a user to register one.
import {
  to = keycloak_required_action.master_webauthn_register
  id = "master/webauthn-register"
}

resource "keycloak_required_action" "master_webauthn_register" {
  realm_id = keycloak_realm.master.realm
  alias    = "webauthn-register"
  name     = "Webauthn Register"
  enabled  = true
}

# Every user in the master realm gets the account console roles. Without them the token has no
# "account" audience and the account page fails with 401s.
resource "keycloak_default_roles" "master" {
  realm_id = keycloak_realm.master.id
  default_roles = [
    "offline_access",
    "uma_authorization",
    "account/view-profile",
    "account/manage-account",
  ]
}

# Password, then a passkey for any user who has one registered. A user with no passkey yet skips the
# second step, so a new admin can still sign in once to register one.
module "browser_flow" {
  source = "./modules/passkey_flow"

  realm_id = keycloak_realm.master.id
  alias    = "browser-passkey"
  strict   = false
}
