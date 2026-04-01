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
vnet_pairs = [
  {
    # Pair 0 — Native PAN-OS Active/Passive HA with Azure API VIP failover
    # Floating trust IP (.6) moves to the active FW via Azure API — ARS sees a single BGP peer.
    # Both FWs share the same ASN since they present a single BGP identity via the floating IP.
    fw_vnet_cidr       = "10.0.0.0/24"
    workload_vnet_cidr = "10.1.0.0/24"
    enable_ars         = true
    enable_panos_ha    = true
    ha1_use_mgmt       = false # Dedicated HA1 NIC for heartbeat
    enable_vip         = true  # Floating IPs on trust/untrust/untrust2; ARS peers with floating trust IP
    enable_lb_ha       = false
    enable_islb        = false # Must be false when enable_vip=true (floating VIP and ISLB both claim .6)
    enable_untrust2    = true
    enable_nat_gateway = false
    enable_one_arm     = false
    vm_size            = "Standard_D16s_v5" # Required for 6 NICs
    firewalls = {
      fw1 = {
        hostname  = "prod-fw-active"
        user_data = "hostname=prod-fw-active\nvm-auth-key=0123456"
        bgp_asn   = 65000
      }
      fw2 = {
        hostname  = "prod-fw-passive"
        user_data = "hostname=prod-fw-passive\nvm-auth-key=0123456"
        bgp_asn   = 65000
      }
    }
  },
  {
    # Pair 1 — Cloud-Native Load Balancer HA (LB sandwich)
    # ELB on untrust (shared floating PIP) + ISLB on trust. ELB outbound rule handles SNAT.
    # Each FW peers independently to ARS.
    fw_vnet_cidr       = "10.2.0.0/24"
    workload_vnet_cidr = "10.3.0.0/24"
    enable_ars         = true
    enable_panos_ha    = false
    ha1_use_mgmt       = false
    enable_vip         = false
    enable_lb_ha       = true
    enable_islb        = true  # Completes the LB sandwich
    enable_untrust2    = true
    enable_nat_gateway = false
    enable_one_arm     = false
    vm_size            = "Standard_D8s_v5"
    firewalls = {
      fw1 = {
        hostname  = "dev-fw-a"
        user_data = "hostname=dev-fw-a\nvm-auth-key=0123456"
        bgp_asn   = 65001
      }
      fw2 = {
        hostname  = "dev-fw-b"
        user_data = "hostname=dev-fw-b\nvm-auth-key=0123456"
        bgp_asn   = 65002
      }
    }
  },
  {
    # Pair 2 — Standalone + Azure Route Server (ECMP via BGP)
    # Each FW peers independently to ARS with a unique ASN.
    # Also models SD-WAN independent hub deployment.
    fw_vnet_cidr       = "10.4.0.0/24"
    workload_vnet_cidr = "10.5.0.0/24"
    enable_ars         = true
    enable_panos_ha    = false
    ha1_use_mgmt       = false
    enable_vip         = false
    enable_lb_ha       = false
    enable_islb        = true
    enable_untrust2    = true
    enable_nat_gateway = false
    enable_one_arm     = false
    vm_size            = "Standard_D8s_v5"
    firewalls = {
      fw1 = {
        hostname  = "test-fw-1"
        user_data = "hostname=test-fw-1\nvm-auth-key=0123456"
        bgp_asn   = 65003
      }
      fw2 = {
        hostname  = "test-fw-2"
        user_data = "hostname=test-fw-2\nvm-auth-key=0123456"
        bgp_asn   = 65004
      }
    }
  },
  {
    # Pair 3 — OBEW (Outbound + East-West), dedicated model reference architecture
    # Independent FWs, no PAN-OS HA, no floating IPs, no untrust2.
    # Each FW has its own public IP on untrust for outbound.
    # ISLB on trust handles east-west and outbound; workload UDR points to ISLB frontend (.6).
    fw_vnet_cidr       = "10.6.0.0/24"
    workload_vnet_cidr = "10.7.0.0/24"
    enable_ars         = false
    enable_panos_ha    = false
    ha1_use_mgmt       = false
    enable_vip         = false
    enable_lb_ha       = false
    enable_islb        = true  # Workload UDR next-hop is ISLB frontend (.6 on trust subnet)
    enable_untrust2    = false # OBEW uses only mgmt, untrust, trust
    enable_nat_gateway = false
    enable_one_arm     = false
    vm_size            = "Standard_D8s_v5"
    firewalls = {
      fw1 = {
        hostname  = "obew-fw-1"
        user_data = "hostname=obew-fw-1\nvm-auth-key=0123456"
        bgp_asn   = 65005
      }
      fw2 = {
        hostname  = "obew-fw-2"
        user_data = "hostname=obew-fw-2\nvm-auth-key=0123456"
        bgp_asn   = 65006
      }
    }
  },
  {
    # Pair 4 — NAT Gateway + ELB inbound + ISLB
    # No public IPs on individual FW untrust NICs.
    # NAT-GW on untrust subnet handles outbound SNAT — ELB outbound rule is suppressed.
    # ELB provides a shared inbound floating PIP; health probes resolve to the active FW.
    # Works for independent FWs or PAN-OS HA (passive FW dead dataplane fails health probes
    # naturally, no Azure API required for failover).
    fw_vnet_cidr       = "10.8.0.0/24"
    workload_vnet_cidr = "10.9.0.0/24"
    enable_ars         = false
    enable_panos_ha    = true  # HA1/HA2 for config sync; dead dataplane on passive drives ELB failover
    ha1_use_mgmt       = false # Dedicated HA1 NIC; set true to run HA1 over management interface
    enable_vip         = false # No floating VIPs — ELB + ISLB handle data plane
    enable_lb_ha       = true  # ELB provides shared inbound PIP; both FW untrust NICs in backend pool
    enable_islb        = true  # ISLB on trust for east-west and outbound next-hop
    enable_untrust2    = false
    enable_nat_gateway = true  # NAT-GW on untrust subnet for outbound SNAT; suppresses ELB outbound rule
    enable_one_arm     = false
    vm_size            = "Standard_D8s_v5" # 4 NICs: mgmt, ha1, ha2, untrust, trust
    firewalls = {
      fw1 = {
        hostname  = "natgw-fw-active"
        user_data = "hostname=natgw-fw-active\nvm-auth-key=0123456"
        bgp_asn   = 65007
      }
      fw2 = {
        hostname  = "natgw-fw-passive"
        user_data = "hostname=natgw-fw-passive\nvm-auth-key=0123456"
        bgp_asn   = 65007
      }
    }
  },
  {
    # Pair 5 — One-Arm Dataplane
    # Single dataplane NIC (trust only). No untrust NIC, no HA NICs.
    # ISLB on trust subnet as inbound/east-west next-hop.
    # NAT-GW on trust subnet for outbound SNAT.
    # Workload UDR next-hop is ISLB frontend (.6 on trust subnet).
    fw_vnet_cidr       = "10.10.0.0/24"
    workload_vnet_cidr = "10.11.0.0/24"
    enable_ars         = false
    enable_panos_ha    = false
    ha1_use_mgmt       = false
    enable_vip         = false
    enable_lb_ha       = false
    enable_islb        = true  # Required; ISLB frontend (.6) is next-hop for all workload traffic
    enable_untrust2    = false
    enable_nat_gateway = true  # Required; NAT-GW attaches to trust subnet (not untrust) in one-arm mode
    enable_one_arm     = true  # 2 NICs only: mgmt + trust
    vm_size            = "Standard_D4s_v5"
    firewalls = {
      fw1 = {
        hostname  = "onearm-fw-1"
        user_data = "hostname=onearm-fw-1\nvm-auth-key=0123456"
        bgp_asn   = 65008
      }
      fw2 = {
        hostname  = "onearm-fw-2"
        user_data = "hostname=onearm-fw-2\nvm-auth-key=0123456"
        bgp_asn   = 65009
      }
    }
  }
]
