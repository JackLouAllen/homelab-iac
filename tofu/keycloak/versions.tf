terraform {
  required_version = ">= 1.8"

  required_providers {
    keycloak = {
      source  = "keycloak/keycloak"
      version = "~> 5.10"
    }
  }
}

# The service account's credentials come from KEYCLOAK_CLIENT_ID and KEYCLOAK_CLIENT_SECRET,
# exported per shell session from a tmpfs copy of the sops file. The client is "tofu" in the master
# realm with the admin role; see the notes in docs/KEYCLOAK_TOFU.md.
provider "keycloak" {
  url = var.keycloak_url

  # Keycloak 26.4+ reports its version only to a service account with an extra role. Stating it
  # avoids granting that role; keep it in step with keycloak_image in the keycloak role.
  keycloak_version = var.keycloak_version

  # Only the local test bench needs this (scripts/keycloak-bench.sh).
  additional_headers = var.keycloak_additional_headers
}
