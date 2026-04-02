# vmseries-architectures — Azure

> **FOR LAB AND DEMONSTRATION USE ONLY.**
> This code is provided without warranty of any kind, express or implied. It is not validated for production use. No support is provided. Use at your own risk.

Terraform deployment for Palo Alto Networks VM-Series firewalls in Azure, supporting three high-availability architectures in a hub-and-spoke topology.

This is **Phase 2** of a two-phase deployment workflow. Deploy [panorama-create](https://github.com/mharms/panorama-create) first, then set `private_panorama_vnet_id` here to peer the firewall VNETs to Panorama.

## Architectures

| Mode | Key Flags | NICs | Notes |
|------|-----------|------|-------|
| Native PAN-OS A/P HA | `enable_panos_ha=true` `enable_vip=true` | 4–6 | Floating VIPs on trust/untrust/untrust2 moved via Azure API. ARS peers with single floating trust IP — BGP session drops during IP migration and reconverges via ARS keepalive timer; untuned failover ~60s end-to-end. HA2 always required. NIC count varies by flags: `ha1_use_mgmt=true` saves one NIC (HA1 over mgmt); `enable_untrust2=false` saves another (drops second untrust). Minimum 4 NICs (mgmt+ha2+untrust+trust); maximum 6 requires ≥6 NIC VM (e.g. `Standard_D16s_v5`). |
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

## Planned: vWAN Hub Attachment

> Not yet implemented. This section captures the design intent.

The current architectures use a hub VNET with Azure Route Server (ARS) for dynamic routing. vWAN introduces a fundamentally different routing plane that requires several architectural changes.

### Key Constraints

**ARS is incompatible with vWAN-connected VNETs.** A VNET connected to a vWAN hub cannot also contain an ARS instance — the two routing control planes conflict. Any pair using `enable_ars=true` cannot be directly connected to a vWAN hub.

**Workload VNETs need a vWAN-connected option for testing.** The current topology peers workload spokes directly to the firewall hub VNET. To validate traffic flow through firewalls attached to a vWAN hub, at least some workload VNETs need to be connected to the vWAN hub as spoke connections rather than peered to the firewall VNET. Both attachment modes should be supportable — vWAN-connected workload VNETs to test the vWAN routing path, and optionally direct-peered workload VNETs for comparison.

### Routing Options

Without ARS, two mechanisms are available to steer workload traffic through the firewalls:

| Mechanism | How it works | Trade-offs |
|-----------|-------------|------------|
| **Static route on vWAN hub** | A static route in the vWAN hub's route table points `0.0.0.0/0` (or specific prefixes) to the ISLB frontend IP in the firewall VNET | Simple; no BGP required on firewall. Requires ISLB (`enable_islb=true`). |
| **BGP peering with vWAN hub** | Firewall trust interface peers via BGP directly with the vWAN hub (NVA BGP peering). Firewall advertises a default or specific routes; vWAN hub programs these into connected spoke VNETs automatically | Dynamic; firewall controls routing. Requires BGP configuration on vWAN hub and firewall. ISLB still recommended as the BGP next-hop so vWAN sees a stable IP. |

### Planned Variables

```hcl
enable_vwan        = bool   # Attach hub VNET and workload VNET to a vWAN hub; disables ARS
vwan_hub_id        = string # Resource ID of the target vWAN hub
vwan_routing_intent = string # "static" or "bgp"
```

### Design Notes

- `enable_ars` must be `false` when `enable_vwan=true` — a validation will enforce this
- Workload spoke-to-hub VNET peering is replaced by separate vWAN spoke connections; the `workload_vnet_cidr` VNET connects directly to the vWAN hub rather than peering to `fw_hub`
- BGP peering mode: the firewall trust IP (or ISLB frontend `.6`) becomes the NVA BGP peer registered on the vWAN hub; firewall advertises spoke prefixes or a default route back toward the hub
- Static route mode: a vWAN hub route table entry points to the ISLB frontend; simpler but requires manual updates when spoke CIDRs change

## Discover Available VM-Series Versions

```bash
az vm image list --location eastus --publisher paloaltonetworks --offer vmseries-flex --sku byol --all --output table
```
