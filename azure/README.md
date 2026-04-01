# vmseries-architectures — Azure

> **FOR LAB AND DEMONSTRATION USE ONLY.**
> This code is provided without warranty of any kind, express or implied. It is not validated for production use. No support is provided. Use at your own risk.

Terraform deployment for Palo Alto Networks VM-Series firewalls in Azure, supporting three high-availability architectures in a hub-and-spoke topology.

This is **Phase 2** of a two-phase deployment workflow. Deploy [panorama-create](https://github.com/mharms/panorama-create) first, then set `private_panorama_vnet_id` here to peer the firewall VNETs to Panorama.

## Architectures

| Mode | Key Flags | NICs | Notes |
|------|-----------|------|-------|
| Native PAN-OS A/P HA | `enable_panos_ha=true` `enable_vip=true` | 5 or 6 | Floating VIPs on trust/untrust/untrust2 moved via Azure API. ARS peers with single floating trust IP. HA2 always required. `ha1_use_mgmt=false` (default) adds a dedicated HA1 NIC (6 total, requires ≥6 NIC VM e.g. `Standard_D16s_v5`); `ha1_use_mgmt=true` runs HA1 over management (5 total). |
| Load Balancer HA | `enable_lb_ha=true` `enable_islb=true` | 4 | ELB on untrust (shared floating PIP) + ISLB on trust. ELB outbound rule handles SNAT. |
| Standalone + ARS | `enable_ars=true` | 4 | Independent FWs, per-FW BGP peers to ARS. ECMP routing. Unique ASN per FW. Models SD-WAN independent hub deployment. |
| OBEW (dedicated model) | `enable_islb=true` `enable_untrust2=false` | 3 | Outbound + east-west from dedicated model reference architecture. Independent FWs, individual public IP per FW on untrust, ISLB on trust. Workload UDR next-hop is ISLB frontend. |
| NAT-GW + ELB inbound | `enable_lb_ha=true` `enable_islb=true` `enable_nat_gateway=true` `enable_untrust2=false` | 3 or 5 | No public IPs on FW untrust NICs. NAT-GW handles outbound SNAT (ELB outbound rule suppressed). ELB provides shared inbound PIP. Works with independent FWs or PAN-OS HA — passive FW dead dataplane naturally fails ELB health probes, no Azure API required for failover. |
| One-Arm Dataplane | `enable_one_arm=true` `enable_islb=true` `enable_nat_gateway=true` | 2 | Single dataplane NIC (trust only). ISLB on trust subnet handles all inbound and east-west. NAT-GW on trust subnet handles outbound SNAT. No untrust NIC — simplest possible dataplane footprint. |

## Architecture

Each entry in `vnet_pairs` creates:
- One **Hub VNET** with firewall subnets (mgmt, ha1, ha2, untrust, trust, untrust2, RouteServerSubnet)
- One **Spoke VNET** with a workload subnet and Nginx test VM
- Full-mesh Hub-to-Hub peering
- Hub-to-Panorama peering (when `private_panorama_vnet_id` is set)

### NIC Layout (per firewall)

NIC presence is driven by flags. Slot order is fixed — absent NICs are skipped and remaining NICs shift up.

| Slot | Interface | IP | Present when | Notes |
|------|-----------|----|--------------|-------|
| 1 | Management | `.4`=fw1, `.5`=fw2 | always | Public IP always attached |
| 2 | HA1 | `.4`=fw1, `.5`=fw2 | `enable_panos_ha=true` and `ha1_use_mgmt=false` | PAN-OS HA heartbeat. Set `ha1_use_mgmt=true` to run HA1 over the management interface instead — saves a NIC slot. |
| 3 | HA2 | `.4`=fw1, `.5`=fw2 | `enable_panos_ha=true` | PAN-OS HA bulk sync. Always required for A/P HA. |
| 4 | Untrust | `.4`=fw1, `.5`=fw2 | `enable_one_arm=false` | Public IP per FW, or no PIP when `enable_lb_ha=true` (ELB provides shared PIP). When `enable_nat_gateway=true`, NAT-GW on untrust subnet handles outbound SNAT — no per-FW or ELB outbound PIPs needed. Absent entirely when `enable_one_arm=true`. |
| 5 | Trust | `.4`=fw1, `.5`=fw2 | always | IP forwarding enabled. Floating VIP `.6` added when `enable_vip=true`. ISLB frontend at `.6` when `enable_islb=true`. BGP endpoint for ARS. NAT-GW attached when `enable_one_arm=true`. |
| 6 | Untrust2 | `.4`=fw1, `.5`=fw2 | `enable_untrust2=true` | Second untrust for dual-ISP or zoning. Floating VIP `.6` added when `enable_vip=true`. |

## Usage

```bash
cd azure/

# Copy and edit example.tfvars with your values
# Set private_panorama_vnet_id to the output from panorama-create
cp example.tfvars my.tfvars

terraform init
terraform apply -var-file="my.tfvars"
```

## Two-Phase Deployment Workflow

```bash
# Phase 1: Deploy Panorama
cd ../panorama-create/azure
terraform init && terraform apply -var-file="example.tfvars"
# Note the output: panorama_vnet_id = "/subscriptions/.../..."

# Phase 2: Deploy firewalls
cd ../../vmseries-architectures/azure
# Set private_panorama_vnet_id in your tfvars to the value above
terraform init && terraform apply -var-file="my.tfvars"
```

## Outputs

| Output | Description |
|--------|-------------|
| `firewall_mgmt_ips` | Public IPs per firewall per VNET pair |
| `workload_access_ips` | Public IPs for workload/test VMs |
| `ars_peering_config` | ARS BGP IPs and peer config for firewall BGP setup |
| `environment_info` | Tenant/subscription/resource group info |

## Key Variables

| Variable | Default | Description |
|----------|---------|-------------|
| `subscription_id` | — | Azure subscription ID |
| `location` | — | Azure region |
| `prefix` | `vmseries-ha` | Resource name prefix |
| `ssh_key` | — | SSH public key for `panadmin` (firewalls) and `azureuser` (workloads) |
| `allowed_mgmt_cidrs` | — | CIDRs allowed to reach firewall management on ports 22/443 |
| `private_panorama_vnet_id` | `null` | Resource ID from `panorama-create` `panorama_vnet_id` output |
| `shared_user_data` | `""` | Bootstrap params applied to all firewalls (e.g., `authcodes`, `panorama-server`) |
| `vnet_pairs` | `[]` | List of hub/spoke environments to deploy. Each firewall has its own `bgp_asn` — assign matching ASNs for PAN-OS HA pairs (shared floating IP) and distinct ASNs for standalone/LB HA (independent BGP peers). |
| `workload_vm_size` | `Standard_B2s` | VM size for workload test VMs |
| `create_marketplace_agreement` | `false` | Accept marketplace terms (first deployment only) |

## Discover Available VM-Series Versions

```bash
az vm image list --location eastus --publisher paloaltonetworks --offer vmseries-flex --sku byol --all --output table
```
