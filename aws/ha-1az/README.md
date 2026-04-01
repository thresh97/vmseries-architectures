# vmseries-architectures — AWS / ha-1az

> **FOR LAB AND DEMONSTRATION USE ONLY.**
> This code is provided without warranty of any kind, express or implied. It is not validated for production use. No support is provided. Use at your own risk.

Terraform deployment for Palo Alto Networks VM-Series firewalls in AWS in an Active/Passive HA pair within a single Availability Zone.

## Architecture

```
Internet
    │
    ▼
Internet Gateway
    │
    ├── mgmt subnet     (FW1: .4, FW2: .5) — public, route: 0.0.0.0/0 → IGW
    └── untrust subnet  (FW1: .4/.100, FW2: .5) — public, route: 0.0.0.0/0 → IGW
                                    │
                         trust subnet (FW1: .4/.100, FW2: .5)
                                    │
                         workload subnet — route: 0.0.0.0/0 → active FW trust ENI
                                    │
                              Workload VM (Nginx)
```

### HA Mechanism: Secondary IP Migration

AWS ENA instances do not support live ENI detachment/reattachment. Active/Passive HA uses **secondary IP migration** instead:

- FW1 owns `.100` (floating VIP) as a secondary private IP on both `untrust` and `trust` ENIs at boot
- The untrust VIP EIP is associated with the `.100` secondary on `fw1_untrust`
- On failover, PAN-OS calls the EC2 API to:
  1. Unassign `.100` from FW1 untrust/trust
  2. Assign `.100` to FW2 untrust/trust
  3. Re-associate the untrust VIP EIP to the `.100` address on FW2
  4. Replace the workload subnet route `0.0.0.0/0 → fw2_trust` ENI

IAM permissions (`AssignPrivateIpAddresses`, `UnassignPrivateIpAddresses`, `ReplaceRoute`) are attached to both FW instance profiles.

### Subnet Layout

Subnets are carved from `vpc_cidr` (/16) as /24s:

| Subnet | Offset | Purpose | Route Table |
|--------|--------|---------|-------------|
| `mgmt` | .1.0/24 | FW management | 0.0.0.0/0 → IGW |
| `untrust` | .2.0/24 | FW untrust dataplane | 0.0.0.0/0 → IGW |
| `trust` | .3.0/24 | FW trust dataplane | local only |
| `workload` | .4.0/24 | Test workload VM | 0.0.0.0/0 → active FW trust ENI |
| `ha` | .5.0/24 | Dedicated HA link | local only |

### NIC Layout (per firewall)

| device_index | ENI | PAN-OS interface | Subnet |
|---|---|---|---|
| 0 | `fw{1,2}_mgmt` | Management | mgmt |
| 1 | `fw{1,2}_ha` | HA | ha |
| 2 | `fw{1,2}_trust` | `ethernet1/1` | trust |
| 3 | `fw{1,2}_untrust` | `ethernet1/2` | untrust |

FW1 trust and untrust ENIs carry `.100` as a secondary IP (the floating VIP). FW2 trust and untrust hold only `.5`.

### Placement Group

Both FWs are placed in a `spread` placement group, ensuring they land on distinct physical racks within the AZ. This prevents a single hardware fault from taking down both firewalls simultaneously.

## Usage

```bash
cd aws/ha-1az/

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
| `untrust_vip_ip` | Floating untrust VIP EIP — follows the active firewall |
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
