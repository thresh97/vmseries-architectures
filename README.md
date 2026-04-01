# vmseries-architectures

> **FOR LAB AND DEMONSTRATION USE ONLY.**
> This code is provided without warranty of any kind, express or implied. It is not validated for production use. No support is provided. Use at your own risk.

A hands-on study of Palo Alto Networks VM-Series firewall deployment patterns across public cloud providers. Each cloud subdirectory contains Terraform that deploys real, working infrastructure — useful for learning PAN-OS HA mechanics, cloud routing primitives, and load balancer integration patterns.

## Firewall Management: SCM vs Panorama

VM-Series firewalls are managed through one of two control planes:

- **Strata Cloud Manager (SCM)** — Palo Alto's SaaS-delivered management platform. No infrastructure to deploy or maintain. Well-suited for customers starting fresh or consolidating management across NGFWs, Prisma Access, and other PANW products under a single pane of glass.
- **Panorama** — the traditional on-premises (or cloud-hosted) management server. Deeply mature, with a broad feature set accumulated over many years.

The right choice is rarely straightforward. A few factors that typically drive the decision:

**Existing investment** — Customers already running Panorama with established device groups, template stacks, and automation workflows face real migration cost. SCM is often a more natural starting point for net-new deployments.

**Feature parity** — SCM and Panorama do not have complete feature parity. Some capabilities exist in one and not the other, and the gap shifts with each release. Before committing to either platform, it's worth auditing the specific features your deployment requires against each platform's current support matrix.

**Operational model** — SCM offloads infrastructure management but requires internet connectivity from the firewall management plane. Panorama gives you full control over data residency and access patterns, which matters in air-gapped or strict compliance environments.

**Licensing** — For VM-Series Flex deployments, both Panorama and SCM Pro are available as a checkbox on the deployment profile — no separate management license required. A standalone Panorama license is typically only purchased when the majority of managed devices are hardware NGFWs rather than software firewalls.

The Terraform in this repo uses Panorama as the management plane. The companion [panorama-create](https://github.com/thresh97/panorama-create) repo handles Panorama deployment. For SCM-managed deployments, the bootstrap `user_data` fields would reference SCM instead of a Panorama server IP, but the underlying networking and HA architectures remain identical.

## What This Repo Covers

- **PAN-OS Active/Passive HA** — native heartbeat/failover with dedicated HA links
- **Cloud-native Load Balancer HA** — stateless failover via external and internal LBs
- **Standalone + Dynamic Routing** — ECMP across independent firewalls using cloud route servers/BGP
- **Hub-and-spoke topology** — firewall VNETs peered to workload spokes and a shared Panorama management plane
- **Bootstrap integration** — linking to [panorama-create](https://github.com/thresh97/panorama-create) for Panorama-managed deployments

## Cloud Providers

| Provider | Directory | Architectures |
|----------|-----------|---------------|
| Azure | [`azure/`](azure/) | PAN-OS A/P, LB HA, Standalone+ARS |
| AWS | [`aws/`](aws/) | GWLB one-arm (TGW inspection VPC), A/P HA single-AZ |
| GCP | `gcp/` | Coming soon |
| OCI | `oci/` | Coming soon |

## Usage

See the README in the relevant cloud provider subdirectory for variables, outputs, and deployment steps.

## Related

- [panorama-create](https://github.com/thresh97/panorama-create) — deploy a Panorama management VM
