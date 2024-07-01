resource "azurerm_postgresql_server" "example" {
  resource_group_name              = azurerm_resource_group.example.name
  location                         = azurerm_resource_group.example.location
  name                             = "psql-${local.random_name}"
  sku_name                         = "B_Gen5_2"
  storage_mb                       = 5120
  backup_retention_days            = 7
  geo_redundant_backup_enabled     = false
  auto_grow_enabled                = true
  administrator_login              = var.psql_admin_user
  administrator_login_password     = random_password.password.result
  version                          = "9.5"
  ssl_enforcement_enabled          = true
}

resource "azurerm_postgresql_firewall_rule" "example" {
  resource_group_name = azurerm_resource_group.example.name
  server_name         = azurerm_postgresql_server.example.name
  name                = "AllowAllWindowsAzureIps"
  start_ip_address    = "0.0.0.0"
  end_ip_address      = "0.0.0.0"
}

resource "azurerm_postgresql_database" "example" {
  name                = "mlflow"
  resource_group_name = azurerm_resource_group.example.name
  server_name         = azurerm_postgresql_server.example.name
  charset             = "UTF8"
  collation           = "English_United States.1252"
}