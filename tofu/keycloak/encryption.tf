# This state holds the client secrets Keycloak generates, so it is encrypted before it leaves the
# machine. The passphrase must not be in Git: the key provider is defined in the TF_ENCRYPTION
# environment variable, from a tmpfs copy of the sops file, for example:
#
#   export TF_ENCRYPTION='key_provider "pbkdf2" "state" { passphrase = "..." }'
#
# Losing the passphrase loses the state. `enforced` makes plain state an error, not a fallback.
terraform {
  encryption {
    method "aes_gcm" "state" {
      keys = key_provider.pbkdf2.state
    }

    state {
      method   = method.aes_gcm.state
      enforced = true
    }

    plan {
      method   = method.aes_gcm.state
      enforced = true
    }
  }
}
