subscription_id              = "00000000-0000-0000-0000-000000000000"
location                     = "eastus"
prefix                       = "panw-ha"
ssh_key                      = "ssh-rsa AAAAB3NzaC1yc2EAAAADAQABAAABAQC... user@domain.com"
allowed_mgmt_cidrs           = ["203.0.113.0/24", "198.51.100.50/32"]
create_marketplace_agreement = false # Set to true on first deployment in the sub

# --------------------------------------------------------------------------
# Panorama Peering (from panorama-create output)
# --------------------------------------------------------------------------
# Set this to the panorama_vnet_id output from the panorama-create deployment.
# Leave null to deploy firewalls without Panorama peering.
private_panorama_vnet_id = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/abc-panorama-mgmt-rg/providers/Microsoft.Network/virtualNetworks/abc-panorama-panorama-vnet"

# --------------------------------------------------------------------------
# Firewall Bootstrap Configuration
# --------------------------------------------------------------------------
shared_user_data = "plugin-op-commands=panorama-licensing-mode-on"

# --------------------------------------------------------------------------
# Hub & Spoke VNET Pairs
# --------------------------------------------------------------------------
# Three isolated Hub-Spoke environments demonstrating all three HA modes.
# Hubs are automatically peered with each other in a full mesh.
vnet_pairs = [
  {
    # Pair 0 — Native PAN-OS Active/Passive HA
    fw_vnet_cidr       = "10.0.0.0/24"
    workload_vnet_cidr = "10.1.0.0/24"
    enable_ars         = true
    enable_panos_ha    = true
    enable_lb_ha       = false
    enable_islb        = false    # Must be false when panos_ha is true
    firewall_bgp_asn   = 65000
    vm_size            = "Standard_D16s_v5" # Required for 6 NICs
    firewalls = {
      fw1 = {
        hostname  = "prod-fw-active"
        user_data = "hostname=prod-fw-active\nvm-auth-key=0123456"
      }
      fw2 = {
        hostname  = "prod-fw-passive"
        user_data = "hostname=prod-fw-passive\nvm-auth-key=0123456"
      }
    }
  },
  {
    # Pair 1 — Cloud-Native Load Balancer HA
    fw_vnet_cidr       = "10.2.0.0/24"
    workload_vnet_cidr = "10.3.0.0/24"
    enable_ars         = true
    enable_panos_ha    = false
    enable_lb_ha       = true
    enable_islb        = true     # Completes the LB Sandwich
    firewall_bgp_asn   = 65001
    vm_size            = "Standard_D8s_v5" # Sufficient for 4 NICs
    firewalls = {
      fw1 = {
        hostname  = "dev-fw-a"
        user_data = "hostname=dev-fw-a\nvm-auth-key=0123456"
      }
      fw2 = {
        hostname  = "dev-fw-b"
        user_data = "hostname=dev-fw-b\nvm-auth-key=0123456"
      }
    }
  },
  {
    # Pair 2 — Standalone + Azure Route Server (ECMP via BGP)
    fw_vnet_cidr       = "10.4.0.0/24"
    workload_vnet_cidr = "10.5.0.0/24"
    enable_ars         = true
    enable_panos_ha    = false
    enable_lb_ha       = false
    enable_islb        = true     # Standalone needs at least ISLB or ARS (both enabled here)
    firewall_bgp_asn   = 65002
    vm_size            = "Standard_D8s_v5" # Sufficient for 4 NICs
    firewalls = {
      fw1 = {
        hostname  = "test-fw-1"
        user_data = "hostname=test-fw-1\nvm-auth-key=0123456"
      }
      fw2 = {
        hostname  = "test-fw-2"
        user_data = "hostname=test-fw-2\nvm-auth-key=0123456"
      }
    }
  }
]
