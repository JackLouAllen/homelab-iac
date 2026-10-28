output "app_realm_issuer" {
  description = "The OIDC issuer URL of the application realm: what GitLab, the Wazuh dashboard and other clients are pointed at."
  value       = "https://${var.login_hostname}/realms/${keycloak_realm.homelab.realm}"
}

output "master_realm_issuer" {
  description = "The master realm's issuer: the admin name, reachable on the tailnet only."
  value       = "https://${var.admin_hostname}/realms/${keycloak_realm.master.realm}"
}
