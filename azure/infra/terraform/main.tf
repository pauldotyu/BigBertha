terraform {
  required_providers {
    azurerm = {
      source  = "hashicorp/azurerm"
      version = "=3.110.0"
    }

    azuread = {
      source  = "hashicorp/azuread"
      version = "~> 2.53.1"
    }

    random = {
      source  = "hashicorp/random"
      version = "=3.6.2"
    }
  }
}

provider "azurerm" {
  features {
    resource_group {
      prevent_deletion_if_contains_resources = false
    }
  }
}

locals {
  random_name = "bigbertha${random_integer.example.result}"
}

resource "random_integer" "example" {
  min = 10
  max = 99
}

resource "random_password" "password" {
  length  = 16
  special = true
}

data "azurerm_client_config" "current" {}

data "azuread_user" "current" {
  object_id = data.azurerm_client_config.current.object_id
}

resource "azurerm_resource_group" "example" {
  location = var.location
  name     = "rg-${local.random_name}"
}