resource "azurerm_kubernetes_cluster" "example" {
  resource_group_name       = azurerm_resource_group.example.name
  location                  = azurerm_resource_group.example.location
  name                      = "aks-${local.random_name}"
  dns_prefix                = "aks-${local.random_name}"
  workload_identity_enabled = true
  oidc_issuer_enabled       = true

  default_node_pool {
    name                = "default"
    vm_size             = "Standard_D2s_v4"
    enable_auto_scaling = true
    max_count           = 10
    min_count           = 4

    upgrade_settings {
      drain_timeout_in_minutes      = 0
      max_surge                     = "10%"
      node_soak_duration_in_minutes = 0
    }
  }

  identity {
    type = "SystemAssigned"
  }

  monitor_metrics {
    annotations_allowed = "*"
    labels_allowed      = "*"
  }

  oms_agent {
    log_analytics_workspace_id      = azurerm_log_analytics_workspace.example.id
    msi_auth_for_monitoring_enabled = true
  }

  key_vault_secrets_provider {
    secret_rotation_enabled  = true
    secret_rotation_interval = "1m"
  }

  workload_autoscaler_profile {
    keda_enabled = true
  }

  lifecycle {
    ignore_changes = [
      azure_policy_enabled,
      microsoft_defender,
    ]
  }
}

resource "azapi_update_resource" "example" {
  type        = "Microsoft.ContainerService/managedClusters@2024-03-02-preview"
  resource_id = azurerm_kubernetes_cluster.example.id

  body = {
    properties = {
      aiToolchainOperatorProfile = {
        enabled = true
      }
    }
  }
}

data "azurerm_user_assigned_identity" "example" {
  resource_group_name = azurerm_kubernetes_cluster.example.node_resource_group
  name                = "ai-toolchain-operator-${azurerm_kubernetes_cluster.example.name}"
}

resource "azurerm_role_assignment" "example" {
  scope                = azurerm_kubernetes_cluster.example.id
  principal_id         = data.azurerm_user_assigned_identity.example.principal_id
  role_definition_name = "Contributor"
}

resource "azurerm_federated_identity_credential" "example" {
  resource_group_name = azurerm_kubernetes_cluster.example.node_resource_group
  parent_id           = data.azurerm_user_assigned_identity.example.id
  issuer              = azurerm_kubernetes_cluster.example.oidc_issuer_url
  name                = "kaito-federated-identity"
  subject             = "system:serviceaccount:kube-system:kaito-gpu-provisioner"
  audience            = ["api://AzureADTokenExchange"]
}