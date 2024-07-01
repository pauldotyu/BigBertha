output "rg_name" {
  value = azurerm_resource_group.example.name
}

output "aks_name" {
  value = azurerm_kubernetes_cluster.example.name
}

output "eh_fqdn" {
  value = "${azurerm_eventhub_namespace.example.name}.servicebus.windows.net"
}

output "eh_name" {
  value = azurerm_eventhub.example.name
}

output "eh_default_primary_key_name" {
  value = "RootManageSharedAccessKey"
}

output "eh_default_primary_key" {
  value     = azurerm_eventhub_namespace.example.default_primary_key
  sensitive = true
}

output "psql_fqdn" {
  value = "${azurerm_postgresql_server.example.name}.postgres.database.azure.com"
}

output "psql_admin_user" {
  value = var.psql_admin_user
}

output "psql_admin_password" {
  value     = random_password.password.result
  sensitive = true
}