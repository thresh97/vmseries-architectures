# --------------------------------------------------------------------------
# 1. PROVIDERS & DATA SOURCES
# --------------------------------------------------------------------------
terraform {
  required_providers {
    azurerm = {
      source  = "hashicorp/azurerm"
      version = "~> 4.0"
    }
    random = {
      source  = "hashicorp/random"
      version = "~> 3.0"
    }
  }
}

provider "azurerm" {
  subscription_id = var.subscription_id
  features {
    resource_group {
      prevent_deletion_if_contains_resources = false
    }
  }
}

provider "random" {}

data "azurerm_client_config" "current" {}

resource "random_string" "deploy_id" {
  length  = 3
  special = false
  upper   = false
  numeric = false
}

locals {
  deploy_prefix = var.deployment_code != null && var.deployment_code != "" ? var.deployment_code : random_string.deploy_id.result
  full_prefix   = "${local.deploy_prefix}-${var.prefix}"

  # Flatten the combinations of VNET pairs and Firewalls for dynamic iteration
  fw_instances = flatten([
    for idx, pair in var.vnet_pairs : [
      for fw_key, fw_val in pair.firewalls : {
        vnet_idx  = idx
        fw_key    = fw_key
        hostname  = fw_val.hostname
        user_data = fw_val.user_data
        pair_key  = "vnet${idx}-${fw_key}"
      }
    ]
  ])

  # Math for full-mesh Hub-to-Hub peering
  fw_vnet_indices = range(length(var.vnet_pairs))
  hub_peerings = flatten([
    for i in local.fw_vnet_indices : [
      for j in local.fw_vnet_indices : {
        source      = i
        destination = j
        peering_key = "hub${i}-to-hub${j}"
      } if i != j
    ]
  ])

  # Subnet offsets for plan-time CIDR math
  nic_subnet_offset = {
    mgmt     = 0
    ha1      = 1
    ha2      = 2
    untrust  = 3
    trust    = 4
    untrust2 = 5
  }

  ars_enabled_vnets = {
    for idx, pair in var.vnet_pairs : tostring(idx) => pair if pair.enable_ars
  }

  lb_enabled_vnets = {
    for idx, pair in var.vnet_pairs : tostring(idx) => pair if pair.enable_lb_ha
  }

  islb_enabled_vnets = {
    for idx, pair in var.vnet_pairs : tostring(idx) => pair if pair.enable_islb
  }

  floating_pip_keys = flatten([
    for idx, pair in var.vnet_pairs : [
      for nic_type in ((pair.enable_panos_ha && pair.enable_vip) ? ["untrust", "untrust2"] : (pair.enable_lb_ha ? ["untrust"] : [])) : {
        key      = "${idx}-${nic_type}"
        vnet_idx = tostring(idx)
        nic_type = nic_type
      }
    ] if (pair.enable_panos_ha && pair.enable_vip) || pair.enable_lb_ha
  ])

  ars_bgp_peers = flatten([
    for idx, pair in var.vnet_pairs : (
      pair.enable_ars ? (
        pair.enable_vip ? [
          {
            peer_key = "vnet${idx}-floating"
            vnet_idx = tostring(idx)
            peer_ip  = cidrhost(cidrsubnet(pair.fw_vnet_cidr, 4, local.nic_subnet_offset["trust"]), 6)
            bgp_asn  = values(pair.firewalls)[0].bgp_asn
          }
        ] : [
          for fw_key, fw_val in pair.firewalls : {
            peer_key = "vnet${idx}-${fw_key}"
            vnet_idx = tostring(idx)
            peer_ip  = cidrhost(cidrsubnet(pair.fw_vnet_cidr, 4, local.nic_subnet_offset["trust"]), fw_key == keys(pair.firewalls)[0] ? 4 : 5)
            bgp_asn  = fw_val.bgp_asn
          }
        ]
      ) : []
    )
  ])

  lb_nic_associations = flatten([
    for idx, pair in var.vnet_pairs : [
      for fw_key, fw_val in pair.firewalls : concat(
        pair.enable_islb ? [
          {
            key      = "trust-${idx}-${fw_key}"
            vnet_idx = tostring(idx)
            fw_key   = fw_key
            nic_type = "trust"
            pool_id  = azurerm_lb_backend_address_pool.trust_ilb_backend[tostring(idx)].id
          }
        ] : [],
        pair.enable_lb_ha ? [
          {
            key      = "untrust-${idx}-${fw_key}"
            vnet_idx = tostring(idx)
            fw_key   = fw_key
            nic_type = "untrust"
            pool_id  = azurerm_lb_backend_address_pool.untrust_elb_backend[tostring(idx)].id
          }
        ] : []
      )
    ]
  ])

  # Panorama peering — set private_panorama_vnet_id to peer firewalls to an existing Panorama VNET
  peer_to_panorama      = var.private_panorama_vnet_id != null
  panorama_vnet_id      = var.private_panorama_vnet_id
  panorama_vnet_name    = var.private_panorama_vnet_id != null ? split("/", var.private_panorama_vnet_id)[8] : ""
  panorama_vnet_rg_name = var.private_panorama_vnet_id != null ? split("/", var.private_panorama_vnet_id)[4] : ""
}

resource "azurerm_resource_group" "pair" {
  count    = length(var.vnet_pairs)
  name     = "${local.full_prefix}-pair${count.index}-rg"
  location = var.location
}

# --------------------------------------------------------------------------
# 2. MARKETPLACE AGREEMENT
# --------------------------------------------------------------------------
resource "azurerm_marketplace_agreement" "paloalto_vmseries" {
  count     = var.create_marketplace_agreement && length(var.vnet_pairs) > 0 ? 1 : 0
  publisher = "paloaltonetworks"
  offer     = "vmseries-flex"
  plan      = "byol"
}

# --------------------------------------------------------------------------
# 3. FW & WORKLOAD VNETs + SUBNETS
# --------------------------------------------------------------------------
resource "azurerm_virtual_network" "fw_hub" {
  count               = length(var.vnet_pairs)
  name                = "${local.full_prefix}-fwhub-${count.index}-vnet"
  address_space       = [var.vnet_pairs[count.index].fw_vnet_cidr]
  location            = azurerm_resource_group.pair[count.index].location
  resource_group_name = azurerm_resource_group.pair[count.index].name
}

resource "azurerm_virtual_network" "workload_spoke" {
  count               = length(var.vnet_pairs)
  name                = "${local.full_prefix}-workload-${count.index}-vnet"
  address_space       = [var.vnet_pairs[count.index].workload_vnet_cidr]
  location            = azurerm_resource_group.pair[count.index].location
  resource_group_name = azurerm_resource_group.pair[count.index].name
}

resource "azurerm_subnet" "mgmt" {
  count                = length(var.vnet_pairs)
  name                 = "mgmt"
  resource_group_name  = azurerm_resource_group.pair[count.index].name
  virtual_network_name = azurerm_virtual_network.fw_hub[count.index].name
  address_prefixes     = [cidrsubnet(var.vnet_pairs[count.index].fw_vnet_cidr, 4, 0)]
}

resource "azurerm_subnet" "ha1" {
  count                = length(var.vnet_pairs)
  name                 = "ha1"
  resource_group_name  = azurerm_resource_group.pair[count.index].name
  virtual_network_name = azurerm_virtual_network.fw_hub[count.index].name
  address_prefixes     = [cidrsubnet(var.vnet_pairs[count.index].fw_vnet_cidr, 4, 1)]
}

resource "azurerm_subnet" "ha2" {
  count                = length(var.vnet_pairs)
  name                 = "ha2"
  resource_group_name  = azurerm_resource_group.pair[count.index].name
  virtual_network_name = azurerm_virtual_network.fw_hub[count.index].name
  address_prefixes     = [cidrsubnet(var.vnet_pairs[count.index].fw_vnet_cidr, 4, 2)]
}

resource "azurerm_subnet" "untrust" {
  count                = length(var.vnet_pairs)
  name                 = "untrust"
  resource_group_name  = azurerm_resource_group.pair[count.index].name
  virtual_network_name = azurerm_virtual_network.fw_hub[count.index].name
  address_prefixes     = [cidrsubnet(var.vnet_pairs[count.index].fw_vnet_cidr, 4, 3)]
}

resource "azurerm_subnet" "trust" {
  count                = length(var.vnet_pairs)
  name                 = "trust"
  resource_group_name  = azurerm_resource_group.pair[count.index].name
  virtual_network_name = azurerm_virtual_network.fw_hub[count.index].name
  address_prefixes     = [cidrsubnet(var.vnet_pairs[count.index].fw_vnet_cidr, 4, 4)]
}

resource "azurerm_subnet" "untrust2" {
  count                = length(var.vnet_pairs)
  name                 = "untrust2"
  resource_group_name  = azurerm_resource_group.pair[count.index].name
  virtual_network_name = azurerm_virtual_network.fw_hub[count.index].name
  address_prefixes     = [cidrsubnet(var.vnet_pairs[count.index].fw_vnet_cidr, 4, 5)]
}

# Route Server Subnet (Must be exactly named, min /27)
resource "azurerm_subnet" "routeserver" {
  for_each             = local.ars_enabled_vnets
  name                 = "RouteServerSubnet"
  resource_group_name  = azurerm_resource_group.pair[tonumber(each.key)].name
  virtual_network_name = azurerm_virtual_network.fw_hub[tonumber(each.key)].name
  address_prefixes     = [cidrsubnet(each.value.fw_vnet_cidr, 3, 7)]
}

resource "azurerm_subnet" "workload" {
  count                = length(var.vnet_pairs)
  name                 = "workload"
  resource_group_name  = azurerm_resource_group.pair[count.index].name
  virtual_network_name = azurerm_virtual_network.workload_spoke[count.index].name
  address_prefixes     = [cidrsubnet(var.vnet_pairs[count.index].workload_vnet_cidr, 1, 0)]
}

# --------------------------------------------------------------------------
# 4. PEERINGS & ROUTING
# --------------------------------------------------------------------------
resource "azurerm_virtual_network_peering" "spoke_to_hub" {
  count                        = length(var.vnet_pairs)
  name                         = "peer-spoke${count.index}-to-hub${count.index}"
  resource_group_name          = azurerm_resource_group.pair[count.index].name
  virtual_network_name         = azurerm_virtual_network.workload_spoke[count.index].name
  remote_virtual_network_id    = azurerm_virtual_network.fw_hub[count.index].id
  allow_virtual_network_access = true
  allow_forwarded_traffic      = true
  use_remote_gateways          = var.vnet_pairs[count.index].enable_ars
  depends_on                   = [azurerm_route_server.ars]
}

resource "azurerm_virtual_network_peering" "hub_to_spoke" {
  count                        = length(var.vnet_pairs)
  name                         = "peer-hub${count.index}-to-spoke${count.index}"
  resource_group_name          = azurerm_resource_group.pair[count.index].name
  virtual_network_name         = azurerm_virtual_network.fw_hub[count.index].name
  remote_virtual_network_id    = azurerm_virtual_network.workload_spoke[count.index].id
  allow_virtual_network_access = true
  allow_forwarded_traffic      = true
  allow_gateway_transit        = var.vnet_pairs[count.index].enable_ars
}

resource "azurerm_virtual_network_peering" "hub_to_hub" {
  for_each                     = { for p in local.hub_peerings : p.peering_key => p }
  name                         = "peer-${each.value.peering_key}"
  resource_group_name          = azurerm_resource_group.pair[each.value.source].name
  virtual_network_name         = azurerm_virtual_network.fw_hub[each.value.source].name
  remote_virtual_network_id    = azurerm_virtual_network.fw_hub[each.value.destination].id
  allow_virtual_network_access = true
  allow_forwarded_traffic      = true
}

# Hub -> Panorama Peering
resource "azurerm_virtual_network_peering" "hub_to_panorama" {
  count                        = local.peer_to_panorama ? length(var.vnet_pairs) : 0
  name                         = "peer-hub${count.index}-to-panorama"
  resource_group_name          = azurerm_resource_group.pair[count.index].name
  virtual_network_name         = azurerm_virtual_network.fw_hub[count.index].name
  remote_virtual_network_id    = local.panorama_vnet_id
  allow_virtual_network_access = true
  allow_forwarded_traffic      = true
}

# Panorama -> Hub Peering
resource "azurerm_virtual_network_peering" "panorama_to_hub" {
  count                        = local.peer_to_panorama ? length(var.vnet_pairs) : 0
  name                         = "peer-panorama-to-hub${count.index}"
  resource_group_name          = local.panorama_vnet_rg_name
  virtual_network_name         = local.panorama_vnet_name
  remote_virtual_network_id    = azurerm_virtual_network.fw_hub[count.index].id
  allow_virtual_network_access = true
  allow_forwarded_traffic      = true
}

resource "azurerm_route_table" "workload" {
  count               = length(var.vnet_pairs)
  name                = "${local.full_prefix}-workload-${count.index}-rt"
  location            = azurerm_resource_group.pair[count.index].location
  resource_group_name = azurerm_resource_group.pair[count.index].name

  dynamic "route" {
    for_each = var.vnet_pairs[count.index].enable_islb ? [1] : []
    content {
      name                   = "DefaultToFW"
      address_prefix         = "0.0.0.0/0"
      next_hop_type          = "VirtualAppliance"
      next_hop_in_ip_address = cidrhost(cidrsubnet(var.vnet_pairs[count.index].fw_vnet_cidr, 4, local.nic_subnet_offset["trust"]), 6)
    }
  }
}

resource "azurerm_subnet_route_table_association" "workload" {
  count          = length(var.vnet_pairs)
  subnet_id      = azurerm_subnet.workload[count.index].id
  route_table_id = azurerm_route_table.workload[count.index].id
}

# --------------------------------------------------------------------------
# 5. ROUTE SERVERS (ARS)
# --------------------------------------------------------------------------
resource "azurerm_public_ip" "ars_pip" {
  for_each            = local.ars_enabled_vnets
  name                = "${local.full_prefix}-ars-${each.key}-pip"
  location            = azurerm_resource_group.pair[tonumber(each.key)].location
  resource_group_name = azurerm_resource_group.pair[tonumber(each.key)].name
  allocation_method   = "Static"
  sku                 = "Standard"
}

resource "azurerm_route_server" "ars" {
  for_each                         = local.ars_enabled_vnets
  name                             = "${local.full_prefix}-ars-${each.key}"
  resource_group_name              = azurerm_resource_group.pair[tonumber(each.key)].name
  location                         = azurerm_resource_group.pair[tonumber(each.key)].location
  sku                              = "Standard"
  public_ip_address_id             = azurerm_public_ip.ars_pip[each.key].id
  subnet_id                        = azurerm_subnet.routeserver[each.key].id
  branch_to_branch_traffic_enabled = true
}

resource "azurerm_route_server_bgp_connection" "fw_trust_peer" {
  for_each        = { for p in local.ars_bgp_peers : p.peer_key => p }
  name            = "${each.value.peer_key}-bgp"
  route_server_id = azurerm_route_server.ars[each.value.vnet_idx].id
  peer_asn        = each.value.bgp_asn
  peer_ip         = each.value.peer_ip
}

# --------------------------------------------------------------------------
# 6. SECURITY GROUPS
# --------------------------------------------------------------------------
resource "azurerm_network_security_group" "mgmt" {
  count               = length(var.vnet_pairs)
  name                = "${local.full_prefix}-mgmt-${count.index}-nsg"
  location            = azurerm_resource_group.pair[count.index].location
  resource_group_name = azurerm_resource_group.pair[count.index].name

  security_rule {
    name                       = "AllowMgmtInbound"
    priority                   = 100
    direction                  = "Inbound"
    access                     = "Allow"
    protocol                   = "*"
    source_port_range          = "*"
    destination_port_ranges    = ["22", "443"]
    source_address_prefixes    = var.allowed_mgmt_cidrs
    destination_address_prefix = "*"
  }
}

resource "azurerm_subnet_network_security_group_association" "mgmt" {
  count                     = length(var.vnet_pairs)
  subnet_id                 = azurerm_subnet.mgmt[count.index].id
  network_security_group_id = azurerm_network_security_group.mgmt[count.index].id
}

resource "azurerm_network_security_group" "untrust" {
  count               = length(var.vnet_pairs)
  name                = "${local.full_prefix}-untrust-${count.index}-nsg"
  location            = azurerm_resource_group.pair[count.index].location
  resource_group_name = azurerm_resource_group.pair[count.index].name

  security_rule {
    name                       = "AllowOutboundInternet"
    priority                   = 100
    direction                  = "Outbound"
    access                     = "Allow"
    protocol                   = "*"
    source_port_range          = "*"
    destination_port_range     = "*"
    source_address_prefix      = "*"
    destination_address_prefix = "Internet"
  }
}

resource "azurerm_subnet_network_security_group_association" "untrust" {
  count                     = length(var.vnet_pairs)
  subnet_id                 = azurerm_subnet.untrust[count.index].id
  network_security_group_id = azurerm_network_security_group.untrust[count.index].id
}

resource "azurerm_subnet_network_security_group_association" "untrust2" {
  for_each                  = { for idx, pair in var.vnet_pairs : tostring(idx) => pair if pair.enable_untrust2 }
  subnet_id                 = azurerm_subnet.untrust2[tonumber(each.key)].id
  network_security_group_id = azurerm_network_security_group.untrust[tonumber(each.key)].id
}

# --------------------------------------------------------------------------
# 7. VIRTUAL MACHINES - VM-SERIES
# --------------------------------------------------------------------------
resource "azurerm_public_ip" "floating_pip" {
  for_each            = { for p in local.floating_pip_keys : p.key => p }
  name                = "${local.full_prefix}-vnet${each.value.vnet_idx}-${each.value.nic_type}-floating-pip"
  location            = azurerm_resource_group.pair[tonumber(each.value.vnet_idx)].location
  resource_group_name = azurerm_resource_group.pair[tonumber(each.value.vnet_idx)].name
  allocation_method   = "Static"
  sku                 = "Standard"
}

resource "azurerm_public_ip" "fw_pip" {
  for_each = {
    for pair in setproduct(local.fw_instances, ["mgmt", "untrust", "untrust2"]) :
    "${pair[0].pair_key}-${pair[1]}" => {
      inst     = pair[0]
      nic_type = pair[1]
    } if pair[1] == "mgmt" || (contains(["untrust", "untrust2"], pair[1]) && !var.vnet_pairs[pair[0].vnet_idx].enable_lb_ha && (pair[1] != "untrust2" || var.vnet_pairs[pair[0].vnet_idx].enable_untrust2))
  }
  name                = "${local.full_prefix}-${each.value.inst.pair_key}-${each.value.nic_type}-pip"
  location            = azurerm_resource_group.pair[tonumber(each.value.inst.vnet_idx)].location
  resource_group_name = azurerm_resource_group.pair[tonumber(each.value.inst.vnet_idx)].name
  allocation_method   = "Static"
  sku                 = "Standard"
}

resource "azurerm_network_interface" "nics" {
  for_each = {
    for pair in setproduct(local.fw_instances, ["mgmt", "ha1", "ha2", "untrust", "trust", "untrust2"]) :
    "${pair[0].pair_key}-${pair[1]}" => {
      inst     = pair[0]
      nic_type = pair[1]
    } if (var.vnet_pairs[pair[0].vnet_idx].enable_panos_ha || !contains(["ha1", "ha2"], pair[1])) && (var.vnet_pairs[pair[0].vnet_idx].enable_untrust2 || pair[1] != "untrust2")
  }

  name                           = "${local.full_prefix}-${each.value.inst.pair_key}-${each.value.nic_type}-nic"
  location                       = azurerm_resource_group.pair[tonumber(each.value.inst.vnet_idx)].location
  resource_group_name            = azurerm_resource_group.pair[tonumber(each.value.inst.vnet_idx)].name
  accelerated_networking_enabled = each.value.nic_type == "mgmt" ? false : true
  ip_forwarding_enabled          = each.value.nic_type == "trust" ? true : false

  ip_configuration {
    name = "ipconfig1"
    subnet_id = (
      each.value.nic_type == "mgmt" ? azurerm_subnet.mgmt[each.value.inst.vnet_idx].id :
      each.value.nic_type == "ha1" ? azurerm_subnet.ha1[each.value.inst.vnet_idx].id :
      each.value.nic_type == "ha2" ? azurerm_subnet.ha2[each.value.inst.vnet_idx].id :
      each.value.nic_type == "untrust" ? azurerm_subnet.untrust[each.value.inst.vnet_idx].id :
      each.value.nic_type == "trust" ? azurerm_subnet.trust[each.value.inst.vnet_idx].id :
      azurerm_subnet.untrust2[each.value.inst.vnet_idx].id
    )

    # Plan-time static IP (.4 for fw1, .5 for fw2)
    private_ip_address_allocation = "Static"
    private_ip_address = cidrhost(
      cidrsubnet(var.vnet_pairs[each.value.inst.vnet_idx].fw_vnet_cidr, 4, local.nic_subnet_offset[each.value.nic_type]),
      each.value.inst.fw_key == keys(var.vnet_pairs[each.value.inst.vnet_idx].firewalls)[0] ? 4 : 5
    )

    public_ip_address_id = (
      each.value.nic_type == "mgmt" || (contains(["untrust", "untrust2"], each.value.nic_type) && !var.vnet_pairs[each.value.inst.vnet_idx].enable_lb_ha)
    ) ? azurerm_public_ip.fw_pip[each.key].id : null
    primary = true
  }

  dynamic "ip_configuration" {
    for_each = var.vnet_pairs[each.value.inst.vnet_idx].enable_panos_ha && var.vnet_pairs[each.value.inst.vnet_idx].enable_vip && each.value.inst.fw_key == keys(var.vnet_pairs[each.value.inst.vnet_idx].firewalls)[0] && contains(["trust", "untrust", "untrust2"], each.value.nic_type) ? [1] : []
    content {
      name = "floating-vip"
      subnet_id = (
        each.value.nic_type == "untrust" ? azurerm_subnet.untrust[each.value.inst.vnet_idx].id :
        each.value.nic_type == "trust" ? azurerm_subnet.trust[each.value.inst.vnet_idx].id :
        azurerm_subnet.untrust2[each.value.inst.vnet_idx].id
      )
      private_ip_address_allocation = "Static"
      private_ip_address = cidrhost(
        cidrsubnet(var.vnet_pairs[each.value.inst.vnet_idx].fw_vnet_cidr, 4, local.nic_subnet_offset[each.value.nic_type]),
        6
      )
      public_ip_address_id = contains(["untrust", "untrust2"], each.value.nic_type) ? azurerm_public_ip.floating_pip["${each.value.inst.vnet_idx}-${each.value.nic_type}"].id : null
    }
  }
}

resource "azurerm_linux_virtual_machine" "vmseries" {
  for_each = { for inst in local.fw_instances : inst.pair_key => inst }

  name                = "${local.full_prefix}-${each.key}"
  resource_group_name = azurerm_resource_group.pair[tonumber(each.value.vnet_idx)].name
  location            = azurerm_resource_group.pair[tonumber(each.value.vnet_idx)].location
  size                = var.vnet_pairs[each.value.vnet_idx].vm_size
  zone                = tostring(index(keys(var.vnet_pairs[each.value.vnet_idx].firewalls), each.value.fw_key) + 1)
  admin_username      = "panadmin"

  network_interface_ids = compact([
    azurerm_network_interface.nics["${each.key}-mgmt"].id,
    var.vnet_pairs[each.value.vnet_idx].enable_panos_ha ? azurerm_network_interface.nics["${each.key}-ha1"].id : "",
    var.vnet_pairs[each.value.vnet_idx].enable_panos_ha ? azurerm_network_interface.nics["${each.key}-ha2"].id : "",
    azurerm_network_interface.nics["${each.key}-untrust"].id,
    azurerm_network_interface.nics["${each.key}-trust"].id,
    var.vnet_pairs[each.value.vnet_idx].enable_untrust2 ? azurerm_network_interface.nics["${each.key}-untrust2"].id : ""
  ])

  admin_ssh_key {
    username   = "panadmin"
    public_key = var.ssh_key
  }

  os_disk {
    caching              = "ReadWrite"
    storage_account_type = "Standard_LRS"
  }

  source_image_reference {
    publisher = "paloaltonetworks"
    offer     = "vmseries-flex"
    sku       = "byol"
    version   = "11.2.8"
  }

  plan {
    name      = "byol"
    publisher = "paloaltonetworks"
    product   = "vmseries-flex"
  }

  custom_data = base64encode(replace("${var.shared_user_data}\n${each.value.user_data}", "\n", ";"))

  tags = {
    LegacyVMNVA = "true"
  }

  depends_on = [azurerm_marketplace_agreement.paloalto_vmseries]
}

# --------------------------------------------------------------------------
# 8. LOAD BALANCERS (HA)
# --------------------------------------------------------------------------
resource "azurerm_lb" "trust_ilb" {
  for_each            = local.islb_enabled_vnets
  name                = "${local.full_prefix}-trust-ilb-${each.key}"
  location            = azurerm_resource_group.pair[tonumber(each.key)].location
  resource_group_name = azurerm_resource_group.pair[tonumber(each.key)].name
  sku                 = "Standard"

  frontend_ip_configuration {
    name                          = "ha-ports-frontend"
    subnet_id                     = azurerm_subnet.trust[tonumber(each.key)].id
    private_ip_address_allocation = "Static"
    private_ip_address            = cidrhost(cidrsubnet(var.vnet_pairs[tonumber(each.key)].fw_vnet_cidr, 4, local.nic_subnet_offset["trust"]), 6)
  }
}

resource "azurerm_lb_backend_address_pool" "trust_ilb_backend" {
  for_each        = local.islb_enabled_vnets
  name            = "trust-backend"
  loadbalancer_id = azurerm_lb.trust_ilb[each.key].id
}

resource "azurerm_lb_probe" "trust_ilb_probe" {
  for_each        = local.islb_enabled_vnets
  name            = "http-probe"
  loadbalancer_id = azurerm_lb.trust_ilb[each.key].id
  port            = 80
  protocol        = "Tcp"
}

resource "azurerm_lb_rule" "trust_ilb_ha_ports" {
  for_each                       = local.islb_enabled_vnets
  name                           = "ha-ports-rule"
  loadbalancer_id                = azurerm_lb.trust_ilb[each.key].id
  frontend_ip_configuration_name = "ha-ports-frontend"
  backend_address_pool_ids       = [azurerm_lb_backend_address_pool.trust_ilb_backend[each.key].id]
  probe_id                       = azurerm_lb_probe.trust_ilb_probe[each.key].id
  protocol                       = "All"
  frontend_port                  = 0
  backend_port                   = 0
  floating_ip_enabled            = true
}

resource "azurerm_lb" "untrust_elb" {
  for_each            = local.lb_enabled_vnets
  name                = "${local.full_prefix}-untrust-elb-${each.key}"
  location            = azurerm_resource_group.pair[tonumber(each.key)].location
  resource_group_name = azurerm_resource_group.pair[tonumber(each.key)].name
  sku                 = "Standard"

  frontend_ip_configuration {
    name                 = "untrust-frontend"
    public_ip_address_id = azurerm_public_ip.floating_pip["${each.key}-untrust"].id
  }
}

resource "azurerm_lb_backend_address_pool" "untrust_elb_backend" {
  for_each        = local.lb_enabled_vnets
  name            = "untrust-backend"
  loadbalancer_id = azurerm_lb.untrust_elb[each.key].id
}

resource "azurerm_lb_probe" "untrust_elb_probe" {
  for_each        = local.lb_enabled_vnets
  name            = "http-probe"
  loadbalancer_id = azurerm_lb.untrust_elb[each.key].id
  port            = 80
  protocol        = "Tcp"
}

resource "azurerm_lb_rule" "untrust_elb_inbound_udp_500" {
  for_each                       = local.lb_enabled_vnets
  name                           = "inbound-udp-500"
  loadbalancer_id                = azurerm_lb.untrust_elb[each.key].id
  frontend_ip_configuration_name = "untrust-frontend"
  backend_address_pool_ids       = [azurerm_lb_backend_address_pool.untrust_elb_backend[each.key].id]
  probe_id                       = azurerm_lb_probe.untrust_elb_probe[each.key].id
  protocol                       = "Udp"
  frontend_port                  = 500
  backend_port                   = 500
  floating_ip_enabled            = true
  disable_outbound_snat          = true
}

resource "azurerm_lb_rule" "untrust_elb_inbound_udp_4500" {
  for_each                       = local.lb_enabled_vnets
  name                           = "inbound-udp-4500"
  loadbalancer_id                = azurerm_lb.untrust_elb[each.key].id
  frontend_ip_configuration_name = "untrust-frontend"
  backend_address_pool_ids       = [azurerm_lb_backend_address_pool.untrust_elb_backend[each.key].id]
  probe_id                       = azurerm_lb_probe.untrust_elb_probe[each.key].id
  protocol                       = "Udp"
  frontend_port                  = 4500
  backend_port                   = 4500
  floating_ip_enabled            = true
  disable_outbound_snat          = true
}

resource "azurerm_lb_outbound_rule" "untrust_elb_outbound" {
  for_each                 = local.lb_enabled_vnets
  name                     = "outbound-rule"
  loadbalancer_id          = azurerm_lb.untrust_elb[each.key].id
  protocol                 = "All"
  backend_address_pool_id  = azurerm_lb_backend_address_pool.untrust_elb_backend[each.key].id
  allocated_outbound_ports = 1024

  frontend_ip_configuration {
    name = "untrust-frontend"
  }
}

resource "azurerm_network_interface_backend_address_pool_association" "lb_associations" {
  for_each                = { for a in local.lb_nic_associations : a.key => a }
  network_interface_id    = azurerm_network_interface.nics["vnet${each.value.vnet_idx}-${each.value.fw_key}-${each.value.nic_type}"].id
  ip_configuration_name   = "ipconfig1"
  backend_address_pool_id = each.value.pool_id
}

# --------------------------------------------------------------------------
# 9. WORKLOAD VMS
# --------------------------------------------------------------------------
resource "azurerm_public_ip" "workload_pip" {
  count               = length(var.vnet_pairs)
  name                = "${local.full_prefix}-workload-${count.index}-pip"
  location            = azurerm_resource_group.pair[count.index].location
  resource_group_name = azurerm_resource_group.pair[count.index].name
  allocation_method   = "Static"
  sku                 = "Standard"
}

resource "azurerm_network_interface" "workload_nic" {
  count               = length(var.vnet_pairs)
  name                = "${local.full_prefix}-workload-${count.index}-nic"
  location            = azurerm_resource_group.pair[count.index].location
  resource_group_name = azurerm_resource_group.pair[count.index].name

  ip_configuration {
    name                          = "ipconfig1"
    subnet_id                     = azurerm_subnet.workload[count.index].id
    private_ip_address_allocation = "Dynamic"
    public_ip_address_id          = azurerm_public_ip.workload_pip[count.index].id
  }
}

resource "azurerm_linux_virtual_machine" "workload" {
  count               = length(var.vnet_pairs)
  name                = "${local.full_prefix}-workload-${count.index}"
  resource_group_name = azurerm_resource_group.pair[count.index].name
  location            = azurerm_resource_group.pair[count.index].location
  size                = var.workload_vm_size
  admin_username      = "azureuser"
  network_interface_ids = [
    azurerm_network_interface.workload_nic[count.index].id,
  ]

  admin_ssh_key {
    username   = "azureuser"
    public_key = var.ssh_key
  }

  os_disk {
    caching              = "ReadWrite"
    storage_account_type = "Standard_LRS"
  }

  source_image_reference {
    publisher = "Canonical"
    offer     = "0001-com-ubuntu-server-jammy"
    sku       = "22_04-lts"
    version   = "latest"
  }

  custom_data = base64encode(<<-EOF
              #!/bin/bash
              apt-get update
              apt-get install -y nginx
              systemctl start nginx
              systemctl enable nginx
              echo "<h1>Workload VM ${count.index} (Nginx) - Managed by Palo Alto</h1>" > /var/www/html/index.html
              EOF
  )
}

# --------------------------------------------------------------------------
# 10. VARIABLES
# --------------------------------------------------------------------------
variable "subscription_id" {
  type = string
}

variable "deployment_code" {
  type    = string
  default = null
}

variable "create_marketplace_agreement" {
  type    = bool
  default = false
}

variable "prefix" {
  type    = string
  default = "vmseries-ha"
}

variable "location" {
  type = string
}

variable "ssh_key" {
  type = string
}

variable "allowed_mgmt_cidrs" {
  type = list(string)
}

variable "shared_user_data" {
  description = "Shared bootstrap parameters applied to all firewalls."
  type        = string
  default     = ""
}

variable "workload_vm_size" {
  type    = string
  default = "Standard_B2s"
}

variable "private_panorama_vnet_id" {
  description = "Resource ID of an existing Panorama VNET (from panorama-create output). Leave null to skip Panorama peering."
  type        = string
  default     = null
}

variable "vnet_pairs" {
  description = "List of FW Hub & Workload Spoke CIDR block pairs. Deploys N isolated Hub/Spoke environments."
  type = list(object({
    fw_vnet_cidr       = string
    workload_vnet_cidr = string
    enable_ars         = bool
    enable_panos_ha    = bool
    enable_vip         = bool
    enable_lb_ha       = bool
    enable_islb        = bool
    enable_untrust2    = bool
    vm_size            = string
    firewalls = map(object({
      hostname  = string
      user_data = string
      bgp_asn   = number
    }))
  }))
  default = []
  validation {
    condition = alltrue([
      for p in var.vnet_pairs : p.enable_vip ? p.enable_panos_ha : true
    ])
    error_message = "enable_vip requires enable_panos_ha. A floating VIP has no owner without PAN-OS HA."
  }
  validation {
    condition = alltrue([
      for p in var.vnet_pairs : !(p.enable_panos_ha && p.enable_lb_ha)
    ])
    error_message = "enable_panos_ha and enable_lb_ha are mutually exclusive. They cannot both be true for the same VNET pair."
  }
  validation {
    condition = alltrue([
      for p in var.vnet_pairs : !(p.enable_panos_ha && p.enable_islb)
    ])
    error_message = "enable_panos_ha and enable_islb are mutually exclusive."
  }
  validation {
    condition = alltrue([
      for p in var.vnet_pairs : (!p.enable_lb_ha && !p.enable_panos_ha) ? (p.enable_islb || p.enable_ars) : true
    ])
    error_message = "For Standalone deployments (lb_ha and panos_ha are false), you cannot set both enable_islb and enable_ars to false. At least one must be true."
  }
  validation {
    condition = alltrue([
      for p in var.vnet_pairs : (p.enable_lb_ha && !p.enable_ars) ? p.enable_islb : true
    ])
    error_message = "enable_islb must be true if lb_ha is true and enable_ars is false."
  }
}

# --------------------------------------------------------------------------
# 11. OUTPUTS
# --------------------------------------------------------------------------
output "environment_info" {
  value = {
    tenant_id            = data.azurerm_client_config.current.tenant_id
    subscription_id      = var.subscription_id
    pair_resource_groups = [for rg in azurerm_resource_group.pair : rg.name]
    firewall_username    = "panadmin"
    workload_username    = "azureuser"
  }
}

output "workload_access_ips" {
  value = { for i, p in azurerm_public_ip.workload_pip : "workload_${i}" => p.ip_address }
}

output "ars_peering_config" {
  value = {
    for vnet_idx, pair in var.vnet_pairs : "vnet_${vnet_idx}" => {
      ars_public_ip = pair.enable_ars ? azurerm_public_ip.ars_pip[tostring(vnet_idx)].ip_address : null
      ars_bgp_ips   = pair.enable_ars ? azurerm_route_server.ars[tostring(vnet_idx)].virtual_router_ips : []
      peers = pair.enable_ars ? [
        for p in local.ars_bgp_peers : {
          peer_ip  = p.peer_ip
          peer_asn = p.bgp_asn
        } if p.vnet_idx == tostring(vnet_idx)
      ] : []
    } if pair.enable_ars
  }
}

output "firewall_mgmt_ips" {
  description = "Public IP addresses for firewall management interfaces."
  value = {
    for idx, pair in var.vnet_pairs : "vnet_${idx}" => {
      for fw_key, fw_val in pair.firewalls : fw_key => azurerm_public_ip.fw_pip["vnet${idx}-${fw_key}-mgmt"].ip_address
    }
  }
}
