# vmseries-architectures — AWS

> **FOR LAB AND DEMONSTRATION USE ONLY.**
> This code is provided without warranty of any kind, express or implied. It is not validated for production use. No support is provided. Use at your own risk.

Terraform deployments for Palo Alto Networks VM-Series firewalls on AWS. Each subdirectory is a self-contained architecture — independent state, variables, and README.

## Architectures

### Inspection (GWLB-based, horizontally scalable)

The firewall is a stateless inspection target registered with a Gateway Load Balancer. The FW does not participate in routing — GENEVE encapsulation delivers packets to it and returns them to the GWLB for forwarding. Scales horizontally by adding FWs to the target group.

| Directory | Description |
|-----------|-------------|
| [`gwlb-one-arm/`](gwlb-one-arm/) | TGW inspection VPC + GWLB. One-arm FW per AZ (mgmt-interface-swap). NAT GW per AZ for outbound. Workload VPCs via TGW. |
| `gwlb-two-arm/` | *(planned)* Two-arm GWLB: FW performs routing lookup on inner GENEVE packet destination IP, forwards out secondary dataplane NIC with SNAT. |

### Routing (FW as routing hop)

The firewall participates in the data plane as a routed hop. HA is achieved through IP/route migration rather than load balancing.

| Directory | Description |
|-----------|-------------|
| [`ha-1az/`](ha-1az/) | Active/Passive HA pair in a single AZ. Secondary IP migration (.100 VIP) on failover. Spread placement group. |
| `ha-xaz/` | *(planned)* Active/Passive HA across two AZs. |
| `independent/` | *(planned)* Independent FWs with ECMP via TGW Connect (GRE/BGP) or VPC Route Server. |

## Related

- [panorama-create](https://github.com/thresh97/panorama-create) — deploy a Panorama management VM
