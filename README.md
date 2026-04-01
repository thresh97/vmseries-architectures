# vmseries-architectures

A hands-on study of Palo Alto Networks VM-Series firewall deployment patterns across public cloud providers. Each cloud subdirectory contains Terraform that deploys real, working infrastructure — useful for learning PAN-OS HA mechanics, cloud routing primitives, and load balancer integration patterns.

## What This Repo Covers

- **PAN-OS Active/Passive HA** — native heartbeat/failover with dedicated HA links
- **Cloud-native Load Balancer HA** — stateless failover via external and internal LBs
- **Standalone + Dynamic Routing** — ECMP across independent firewalls using cloud route servers/BGP
- **Hub-and-spoke topology** — firewall VNETs peered to workload spokes and a shared Panorama management plane
- **Bootstrap integration** — linking to [panorama-create](https://github.com/thresh97/panorama-create) for managed deployments

## Cloud Providers

| Provider | Directory | HA Modes |
|----------|-----------|----------|
| Azure | [`azure/`](azure/) | PAN-OS A/P, LB HA, Standalone+ARS |
| AWS | `aws/` | Coming soon |
| GCP | `gcp/` | Coming soon |
| OCI | `oci/` | Coming soon |

## Usage

See the README in the relevant cloud provider subdirectory for variables, outputs, and deployment steps.

## Related

- [panorama-create](https://github.com/thresh97/panorama-create) — deploy a Panorama management VM (Phase 1)
