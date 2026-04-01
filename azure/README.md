# vmseries-architectures — Azure

> **FOR LAB AND DEMONSTRATION USE ONLY.**
> This code is provided without warranty of any kind, express or implied. It is not validated for production use. No support is provided. Use at your own risk.

Terraform deployment for Palo Alto Networks VM-Series firewalls in Azure, supporting three high-availability architectures in a hub-and-spoke topology.

This is **Phase 2** of a two-phase deployment workflow. Deploy [panorama-create](https://github.com/mharms/panorama-create) first, then set `private_panorama_vnet_id` here to peer the firewall VNETs to Panorama.

## HA Architectures

| Mode | Flag | NIC Count | Notes |
|------|------|-----------|-------|
| Native PAN-OS A/P | `enable_panos_ha=true` | 6 | Requires `vm_size` with ≥6 NICs (e.g., `Standard_D16s_v5`). Dedicated HA1/HA2 NICs. |
| Load Balancer HA | `enable_lb_ha=true` + `enable_islb=true` | 4 | ELB (untrust) + ISLB (trust) with HA Ports |
| Standalone + ARS | neither | 4 | ECMP via Azure Route Server; source NAT required |

## Architecture

Each entry in `vnet_pairs` creates:
- One **Hub VNET** with firewall subnets (mgmt, ha1, ha2, untrust, trust, untrust2, RouteServerSubnet)
- One **Spoke VNET** with a workload subnet and Nginx test VM
- Full-mesh Hub-to-Hub peering
- Hub-to-Panorama peering (when `private_panorama_vnet_id` is set)

### NIC Layout (per firewall)
```
NIC 1: Management  (.4=fw1, .5=fw2)
NIC 2: HA1         (PAN-OS HA only)
NIC 3: HA2         (PAN-OS HA only)
NIC 4: Untrust     (.4=fw1, .5=fw2)
NIC 5: Trust       (.4=fw1, .5=fw2) — BGP endpoint
NIC 6: Untrust2    (.4=fw1, .5=fw2)
```

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
