# vmseries-architectures — AWS

> **FOR LAB AND DEMONSTRATION USE ONLY.**
> This code is provided without warranty of any kind, express or implied. It is not validated for production use. No support is provided. Use at your own risk.

Terraform deployment for Palo Alto Networks VM-Series firewalls in AWS, using a centralized inspection VPC with Transit Gateway and Gateway Load Balancer.

## Architectures

| Mode | NICs | Notes |
|------|------|-------|
| TGW Inspection VPC + GWLB | 2 (one-arm) | Centralized inspection via GWLB. One FW per AZ. ENI0=data, ENI1=management (mgmt-interface-swap). DHCP learn default on data interface. NAT GW per AZ for outbound SNAT. Symmetric inspection — return traffic (internet→workload) also passes through GWLB. |

## Architecture

```
Internet
    │
    ▼
NAT Gateway (per AZ, public subnet)
    │
    ├── Outbound: GWLBE subnet → NAT GW → IGW → internet
    └── Return:   IGW → NAT GW → public subnet RT → GWLBE (symmetric inspection)
                                                         │
GWLB Endpoint (per AZ, gwlbe subnet) ◄──────────────────┘
    │ GENEVE (UDP 6081)
    ▼
GWLB (cross-zone LB, gwlb subnet)
    │
    ▼
VM-Series FW (data ENI, data subnet) — one per AZ

Transit Gateway
    ├── Inspection RT (associated with inspection VPC attachment)
    │       Routes propagated from workload attachments
    └── Isolation RT (associated with workload attachments)
            Default route → inspection VPC

Workload VPCs (carved from aggregate)
    └── Single subnet: TGW attachment + EC2 test VM
            Route: 0.0.0.0/0 → TGW
```

### Traffic Flow

**Outbound (workload → internet):**
1. Workload VM → TGW (isolation RT default → inspection VPC)
2. Inspection VPC attachment subnet → GWLBE
3. GWLBE → GWLB → FW (GENEVE inspect) → GWLB → GWLBE
4. GWLBE subnet → NAT GW → IGW → internet

**Return (internet → workload):**
1. Internet → NAT GW EIP (DNAT back to workload IP)
2. Public subnet RT: `workload_aggregate → GWLBE` (symmetric inspection)
3. GWLBE → GWLB → FW (GENEVE inspect) → GWLB → GWLBE
4. GWLBE subnet RT: `workload_aggregate → TGW`
5. TGW (inspection RT) → workload VPC

**East-West (workload A → workload B):**
1. Workload A → TGW (isolation RT → inspection VPC)
2. Attachment subnet → GWLBE → FW → GWLBE
3. GWLBE subnet RT: `workload_aggregate → TGW`
4. TGW (inspection RT, propagated routes) → workload B VPC

### Subnet Layout (per AZ in inspection VPC)

Subnets are carved from `inspection_vpc_cidr` (/16) as /24s, offset by AZ index.

| Subnet | Purpose | Route Table |
|--------|---------|-------------|
| `attachment` | TGW attachment ENIs land here | `0.0.0.0/0 → GWLBE` |
| `gwlb` | Gateway Load Balancer | local only |
| `gwlbe` | GWLB Endpoint | `0.0.0.0/0 → NAT GW`, `workload_aggregate → TGW` |
| `data` | FW ENI0 (dataplane, GWLB target) | local only |
| `mgmt` | FW ENI1 (management after swap) | `0.0.0.0/0 → NAT GW` |
| `public` | NAT Gateway + EIP | `0.0.0.0/0 → IGW`, `workload_aggregate → GWLBE` |

### Management Interface Swap

VM-Series in AWS defaults to ENI0=management, ENI1=data. The `mgmt-interface-swap` bootstrap parameter reverses this:

| ENI | Physical | PAN-OS function | Subnet |
|-----|----------|-----------------|--------|
| ENI0 (device_index=0) | eth0 | `ethernet1/1` (data) | data |
| ENI1 (device_index=1) | eth1 | `management` | mgmt |

This is set automatically via `op-command-modes=mgmt-interface-swap` in the instance user-data. The data ENI also learns its default gateway via DHCP (`type=dhcp-client`).

### GWLB Target Registration

Each FW's data ENI (ENI0) primary private IP is registered as a GWLB target. Cross-zone load balancing is enabled — GWLB distributes flows across all AZs. 5-tuple stickiness (`source_ip_dest_ip_proto`) ensures return traffic for an established flow hits the same FW.

## Usage

```bash
cd aws/

cp example.tfvars my.tfvars
# Edit my.tfvars — set vmseries_ami, key_name, allowed_mgmt_cidrs

terraform init
terraform apply -var-file="my.tfvars"
```

## Workload VM Access

Workload VMs have no public IP — all traffic routes through TGW and the inspection VPC. Use **AWS Systems Manager Session Manager** to access them:

```bash
aws ssm start-session --target <instance-id> --region <region>
```

The workload IAM role (`AmazonSSMManagedInstanceCore`) is attached automatically. SSM traffic itself flows through the inspection path (workload → TGW → inspection → NAT GW → SSM endpoints).

## Outputs

| Output | Description |
|--------|-------------|
| `tgw_id` | Transit Gateway ID |
| `firewall_mgmt_ips` | Public EIPs per AZ for firewall management (SSH/HTTPS) |
| `nat_gw_eips` | NAT Gateway public IPs per AZ (workload outbound SNAT address) |
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
| `vmseries_ami` | — | VM-Series BYOL AMI ID (region-specific) |
| `vmseries_instance_type` | `m5.xlarge` | EC2 instance type (must support ≥2 ENIs) |
| `shared_user_data` | `""` | Additional init-cfg params for all firewalls |

## Discover Available VM-Series AMIs

```bash
aws ec2 describe-images \
  --owners 679593333241 \
  --filters "Name=name,Values=PA-VM-AWS-11.2*" \
  --region us-east-1 \
  --query 'sort_by(Images, &CreationDate)[].[CreationDate,Name,ImageId]' \
  --output table
```
