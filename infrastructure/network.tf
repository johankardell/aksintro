resource "azurerm_network_security_group" "aks" {
  name                = "${var.prefix}-vnet-aks-nsg-${var.location}"
  location            = azurerm_resource_group.lab.location
  resource_group_name = azurerm_resource_group.lab.name

  security_rule {
    name                       = "Allow-Demo-HTTP"
    priority                   = 100
    direction                  = "Inbound"
    access                     = "Allow"
    protocol                   = "Tcp"
    source_port_range          = "*"
    destination_port_range     = "80"
    source_address_prefix      = "Internet"
    destination_address_prefix = "*"
    description                = "Allow the Lab 2 demo's public LoadBalancer Service."
  }
}

resource "azurerm_network_security_group" "agc" {
  name                = "${var.prefix}-vnet-agc-nsg-${var.location}"
  location            = azurerm_resource_group.lab.location
  resource_group_name = azurerm_resource_group.lab.name

  security_rule {
    name                       = "Allow-AGC-Web"
    priority                   = 100
    direction                  = "Inbound"
    access                     = "Allow"
    protocol                   = "Tcp"
    source_port_range          = "*"
    destination_port_ranges    = ["80", "443"]
    source_address_prefix      = "Internet"
    destination_address_prefix = "*"
    description                = "Allow public HTTP and HTTPS traffic to AGC frontends."
  }
}

resource "azurerm_subnet_network_security_group_association" "aks" {
  subnet_id                 = azurerm_subnet.aks.id
  network_security_group_id = azurerm_network_security_group.aks.id
}

resource "azurerm_subnet_network_security_group_association" "agc" {
  subnet_id                 = azurerm_subnet.agc.id
  network_security_group_id = azurerm_network_security_group.agc.id
}
