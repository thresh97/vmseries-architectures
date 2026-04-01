# vmseries-architectures — AWS

> **FOR LAB AND DEMONSTRATION USE ONLY.**
> This code is provided without warranty of any kind, express or implied. It is not validated for production use. No support is provided. Use at your own risk.

Terraform deployment for Palo Alto Networks VM-Series firewalls in AWS, using a centralized inspection VPC with Transit Gateway and Gateway Load Balancer — **two-arm (overlay routing) variant**.

## Architecture

```
Internet
    │
    ▼
FW arm2 EIP (per AZ) ─── egress subnet ─── IGW
    │                         │
    │              workload_aggregate → TGW (return path)
    │
VM-Series FW (arm1/data ENI — GWLB target, arm2/egress ENI — SNAT)
    │
GWLB (cross-zone LB, gwlb subnet)
    │ GENEVE (UDP 6081)
    ▼
GWLB Endpoint (per AZ, gwlbe subnet)
    │
    ├── workload_aggregate → TGW (E-W return)
    └── [no default — internet egress exits via FW arm2, not GWLBE]

Transit Gateway
    ├── Inspection RT (associated with inspection VPC attachment)
    │       Routes propagated from workload attachments
    └── Isolation RT (associated with workload attachments)
            Default route → inspection VPC

Workload VPCs (carved from aggregate)
    └── Single subnet: TGW attachment + EC2 test VM
            Route: 0.0.0.0/0 → TGW
```

### Two-Arm vs One-Arm

| | one-arm | two-arm |
|---|---|---|
| FW NICs | 2 (arm1/data, mgmt) | 3 (arm1/data, mgmt, arm2/egress) |
| Internet egress | GWLBE → NAT-GW → IGW | FW arm2 EIP → IGW |
| Return: internet→workload | NAT-GW EIP (DNAT) + `public_workload_return → GWLBE` | FW arm2 de-SNATs, `egress_workload_return → TGW` |
| NAT-GW | 1 per AZ | none |
| Egress public IP | NAT-GW EIP (shared per AZ) | FW arm2 EIP (per AZ, per FW) |

### Traffic Flows

**Outbound (workload → internet):**
1. Workload VM → TGW (isolation RT default → inspection VPC)
2. Inspection VPC attachment subnet → GWLBE
3. GWLBE → GWLB → FW arm1 (GENEVE inspect)
4. FW: inner dest matches arm2 internet route → SNAT, forward out arm2
5. arm2 subnet → IGW → internet

**Return (internet → workload):**
1. Internet → arm2 EIP (FW has SNAT state)
2. FW arm2: de-SNAT → workload IP
3. FW routes workload-destined packet out arm2 → egress subnet RT `workload_aggregate → TGW`
4. TGW inspection RT (propagated workload routes) → workload VPC

**East-West (workload A → workload B):**
1. Workload A → TGW (isolation RT → inspection VPC)
2. Attachment subnet → GWLBE → GWLB → FW arm1 (GENEVE inspect) → GWLB → GWLBE
3. GWLBE subnet RT: `workload_aggregate → TGW`
4. TGW (inspection RT, propagated routes) → workload B VPC

### Subnet Layout (per AZ in inspection VPC)

Subnets are carved from `inspection_vpc_cidr` (/16) as /24s, offset by AZ index.

| Subnet | Purpose | Route Table |
|--------|---------|-------------|
| `attachment` | TGW attachment ENIs land here | `0.0.0.0/0 → GWLBE` |
| `gwlb` | Gateway Load Balancer | local only |
| `gwlbe` | GWLB Endpoint | `workload_aggregate → TGW` only |
| `data` | FW ENI0/arm1 (dataplane, GWLB target) | local only |
| `mgmt` | FW ENI1 (management after swap) | `0.0.0.0/0 → IGW` |
| `egress` | FW ENI2/arm2 (internet SNAT) | `0.0.0.0/0 → IGW`, `workload_aggregate → TGW` |

### Management Interface Swap

VM-Series in AWS defaults to ENI0=management, ENI1=data. The `mgmt-interface-swap` bootstrap parameter reverses this:

| ENI | Physical | PAN-OS function | Subnet |
|-----|----------|-----------------|--------|
| ENI0 (device_index=0) | eth0 | `ethernet1/1` (arm1/data) | data |
| ENI1 (device_index=1) | eth1 | `management` | mgmt |
| ENI2 (device_index=2) | eth2 | `ethernet1/2` (arm2/egress) | egress |

### GWLB Overlay Routing

Two init-cfg `plugin-op-commands` are set automatically on each firewall:

- `aws-gwlb-inspect:enable` — enables GENEVE termination on arm1 (ethernet1/1)
- `aws-gwlb-overlay-routing:enable` — activates the arm2 forwarding path: when the inner packet's destination matches a route on ethernet1/2, the FW forwards directly out arm2 with SNAT instead of returning via the GWLB tunnel

The ethernet1/2 interface, zone, and routing configuration (internet default + workload aggregate return) must be applied via Panorama or manual FW config — this Terraform only provisions the AWS infrastructure.

## Usage

```bash
cd aws/gwlb-two-arm/

cp example.tfvars my.tfvars
# Edit my.tfvars — set panos_version, key_name, allowed_mgmt_cidrs

terraform init
terraform apply -var-file="my.tfvars"
```

## Workload VM Access

Workload VMs have no public IP — all traffic routes through TGW and the inspection VPC. Use **AWS Systems Manager Session Manager** to access them:

```bash
aws ssm start-session --target <instance-id> --region <region>
```

The workload IAM role (`AmazonSSMManagedInstanceCore`) is attached automatically.

## Outputs

| Output | Description |
|--------|-------------|
| `tgw_id` | Transit Gateway ID |
| `firewall_mgmt_ips` | Public EIPs per AZ for firewall management (SSH/HTTPS) |
| `fw_egress_eips` | Firewall arm2 public EIPs per AZ — SNAT source IPs for internet traffic |
| `gwlb_arn` | Gateway Load Balancer ARN |
| `workload_private_ips` | Private IPs of workload test VMs |
| `inspection_vpc_id` | Inspection VPC ID |

## Key Variables

| Variable | Default | Description |
|----------|---------|-------------|
| `aws_region` | — | AWS region |
| `prefix` | `panw` | Resource name prefix |
| `key_name` | — | EC2 key pair name |
| `allowed_mgmt_cidrs` | — | CIDRs allowed to reach firewall management on 22/443 |
| `az_count` | `2` | Number of AZs (1–3) |
| `inspection_vpc_cidr` | `10.0.0.0/16` | Inspection VPC CIDR (must be /16) |
| `workload_aggregate_cidr` | `10.1.0.0/16` | Aggregate from which workload VPC CIDRs are carved |
| `workload_vpc_prefix_length` | `24` | Prefix length of each workload VPC |
| `workload_vpc_count` | `1` | Number of workload VPCs |
| `panos_version` | `11.2.8` | PAN-OS version — selects BYOL AMI from Marketplace |
| `vmseries_instance_type` | `m5.xlarge` | EC2 instance type (must support ≥3 ENIs) |
| `shared_user_data` | `""` | Additional init-cfg params for all firewalls |

## Discover Available PAN-OS Versions

```bash
aws ec2 describe-images \
  --owners aws-marketplace \
  --filters "Name=product-code,Values=6njl1pau431dv1qxipg63mvah" \
  --region us-east-1 \
  --query 'sort_by(Images, &CreationDate)[].[CreationDate,Name]' \
  --output table
```
