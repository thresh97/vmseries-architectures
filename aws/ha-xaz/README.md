# vmseries-architectures — AWS / ha-xaz

> **FOR LAB AND DEMONSTRATION USE ONLY.**
> This code is provided without warranty of any kind, express or implied. It is not validated for production use. No support is provided. Use at your own risk.

Terraform deployment for Palo Alto Networks VM-Series firewalls in AWS in an Active/Passive HA pair spanning two Availability Zones.

## Architecture

```
Internet
    │
    ▼
Internet Gateway
    │
    ├── AZ0                              AZ1
    │   ├── mgmt-a   (FW1: .4) ──────── mgmt-b   (FW2: .4)
    │   └── untrust-a (FW1: .4) ──────── untrust-b (FW2: .4)
    │           │
    │       trust-a (FW1: .4)            trust-b (FW2: .4)
    │           │
    └── workload subnet (AZ0) — route: 0.0.0.0/0 → active FW trust ENI
                │
         Workload VM (Nginx)
```

### HA Mechanism: EIP Re-association

Secondary IP migration used in `ha-1az` does not work across AZs — private IPs are scoped to their subnet and cannot move between AZs. Instead, `ha-xaz` uses **EIP re-association**:

- The untrust VIP EIP is associated with FW1 untrust primary IP at boot
- On failover, PAN-OS plugin (v2.0.3+) calls the EC2 API to:
  1. Disassociate the untrust VIP EIP from FW1 untrust
  2. Associate the untrust VIP EIP to FW2 untrust primary IP
  3. Replace the workload subnet route `0.0.0.0/0 → fw2_trust` ENI

IAM permissions (`AssociateAddress`, `DisassociateAddress`, `DescribeAddresses`, `ReplaceRoute`) are attached to both FW instance profiles.

No placement group is used — the firewalls are in separate AZs and AZ isolation already provides the fault-domain separation that a spread group provides within a single AZ.

### Subnet Layout

Subnets are carved from `vpc_cidr` (/16) as /24s. Per-AZ offset: `az_idx * 16`.

| Subnet | Offset | AZ | Purpose | Route Table |
|--------|--------|----|---------|-------------|
| `mgmt-a` | .1.0/24 | AZ0 | FW1 management | 0.0.0.0/0 → IGW |
| `untrust-a` | .2.0/24 | AZ0 | FW1 untrust dataplane | 0.0.0.0/0 → IGW |
| `trust-a` | .3.0/24 | AZ0 | FW1 trust dataplane | local only |
| `ha-a` | .4.0/24 | AZ0 | FW1 dedicated HA link | local only |
| `mgmt-b` | .17.0/24 | AZ1 | FW2 management | 0.0.0.0/0 → IGW |
| `untrust-b` | .18.0/24 | AZ1 | FW2 untrust dataplane | 0.0.0.0/0 → IGW |
| `trust-b` | .19.0/24 | AZ1 | FW2 trust dataplane | local only |
| `ha-b` | .20.0/24 | AZ1 | FW2 dedicated HA link | local only |
| `workload` | .33.0/24 | AZ0 | Test workload VM | 0.0.0.0/0 → active FW trust ENI |

### NIC Layout (per firewall)

| device_index | ENI | PAN-OS interface | FW1 subnet | FW2 subnet |
|---|---|---|---|---|
| 0 | `fw{1,2}_mgmt` | Management | mgmt-a | mgmt-b |
| 1 | `fw{1,2}_ha` | HA | ha-a | ha-b |
| 2 | `fw{1,2}_trust` | `ethernet1/1` | trust-a | trust-b |
| 3 | `fw{1,2}_untrust` | `ethernet1/2` | untrust-a | untrust-b |

Each ENI holds only its primary IP (`.4`). No secondary IPs.

### Comparison with ha-1az

| | ha-1az | ha-xaz |
|---|---|---|
| AZs | 1 (shared subnets) | 2 (per-AZ subnets) |
| Placement group | spread | none |
| Floating secondary IP | `.100` on untrust + trust | none |
| EIP failover target | `.100` secondary on FW2 | FW2 untrust primary |
| IAM: secondary IP | `AssignPrivateIpAddresses`, `UnassignPrivateIpAddresses` | removed |
| IAM: EIP | absent | `AssociateAddress`, `DisassociateAddress`, `DescribeAddresses` |

## Usage

```bash
cd aws/ha-xaz/

cp example.tfvars my.tfvars
# Edit my.tfvars — set key_name, allowed_mgmt_cidrs, fw1_user_data, fw2_user_data

terraform init
terraform apply -var-file="my.tfvars"
```

## Bootstrap (`fw1_user_data` / `fw2_user_data`)

Each variable is a newline-separated `key=value` string passed as EC2 user-data (init-cfg format). Provide per-firewall values — typically differing only in `hostname`:

```
panorama-server=<panorama-ip>
vm-auth-key=<auth-key>
hostname=fw1
```

## Outputs

| Output | Description |
|--------|-------------|
| `fw1_mgmt_ip` | FW1 management public IP (SSH/HTTPS) |
| `fw2_mgmt_ip` | FW2 management public IP (SSH/HTTPS) |
| `untrust_vip_ip` | Untrust VIP EIP — re-associated to active firewall on failover |
| `workload_public_ip` | Workload test VM public IP |
| `vpc_id` | VPC ID |

## Key Variables

| Variable | Default | Description |
|----------|---------|-------------|
| `aws_region` | — | AWS region |
| `prefix` | `panw` | Resource name prefix |
| `key_name` | — | EC2 key pair name |
| `allowed_mgmt_cidrs` | — | CIDRs allowed to reach management on 22/443 |
| `vpc_cidr` | `10.0.0.0/16` | VPC CIDR (must be /16; subnets carved as /24s) |
| `panos_version` | `11.2.8` | PAN-OS version — selects BYOL AMI from Marketplace |
| `vmseries_instance_type` | `m5.xlarge` | Must support ≥4 ENIs |
| `fw1_user_data` | — | Full init-cfg bootstrap string for FW1 |
| `fw2_user_data` | — | Full init-cfg bootstrap string for FW2 |
| `workload_instance_type` | `t3.micro` | Workload test VM size |

## Discover Available PAN-OS Versions

```bash
aws ec2 describe-images \
  --owners aws-marketplace \
  --filters "Name=product-code,Values=6njl1pau431dv1qxipg63mvah" \
  --region us-east-1 \
  --query 'sort_by(Images, &CreationDate)[].[CreationDate,Name]' \
  --output table
```
