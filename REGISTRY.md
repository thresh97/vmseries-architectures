# Registry

Catalog of all deployment patterns in this repository.

**This repository is personal experience — not an authoritative source.** For official guidance, see the sources linked in each row. Provenance tiers are listed best-first; the highest applicable tier is the most authoritative claim for that pattern.

---

## Provenance Tiers

| Tier | Label | Description |
|------|-------|-------------|
| 1 | `iaac-current` | Current, functional, public IaC in [PaloAltoNetworks GitHub](https://github.com/PaloAltoNetworks) — verify recency before use; CSP APIs move fast |
| 2 | `ref-arch` | [PANW Reference Architectures](https://www.paloaltonetworks.com/resources/reference-architectures) |
| 3 | `deployment-guide` | VM-Series / NGFW Deployment Guide on [docs.paloaltonetworks.com](https://docs.paloaltonetworks.com/vm-series) |
| 4 | `abandonware` | Formerly official PANW IaC, no longer maintained — annotated with year of last meaningful commit; 6 months stale warrants caution, 2+ years is problematic |
| — | `original` | No official source — original work in this repo |
| — | `community` | Non-PANW public source |

## Viability

`working` — deployed and validated end-to-end · `untested` — built but not validated · `deprecated` — worked before, currency unknown · `broken` — known not to work

## Recommendation

`well-worn-path` — widely deployed, battle-tested · `niche` — solid for specific use cases, rarely the default choice · `art-of-possible` — novel or exploratory · `acceptable` — works, not the preferred approach · `anti-pattern` — avoid

---

## Deployments

| Deployment | Cloud | Description | Sources (best first) | Viability | Recommendation |
|------------|-------|-------------|----------------------|-----------|----------------|
| [aws/ha-1az](aws/ha-1az/) | AWS | Active/Passive HA pair, single AZ — secondary IP migration failover | deployment-guide · orig | untested | niche |
| [aws/ha-xaz](aws/ha-xaz/) | AWS | Active/Passive HA pair, two AZs — EIP re-association failover; no NAT state preserved across failover | deployment-guide · orig | untested | niche |
| [aws/gwlb-one-arm](aws/gwlb-one-arm/) | AWS | TGW inspection VPC, GWLB one-arm — centralized inspection, SNAT via NAT GW | [iaac-current](https://github.com/PaloAltoNetworks/terraform-aws-swfw-modules/tree/main/examples/centralized_design) | untested | well-worn-path |
| [aws/gwlb-two-arm](aws/gwlb-two-arm/) | AWS | TGW inspection VPC, GWLB two-arm — overlay routing, SNAT via FW arm2 EIP | [iaac-current](https://github.com/PaloAltoNetworks/terraform-aws-swfw-modules/tree/main/examples/centralized_design) · orig | untested | well-worn-path |
| [azure/](azure/) — PAN-OS A/P HA | Azure | Hub-and-spoke, native PAN-OS Active/Passive HA with dedicated HA1/HA2 links | deployment-guide · orig | untested | well-worn-path |
| [azure/](azure/) — LB HA | Azure | Hub-and-spoke, stateless ELB+ISLB HA (HA Ports) | [iaac-current](https://github.com/PaloAltoNetworks/terraform-azurerm-swfw-modules/tree/main/examples/vmseries_transit_vnet_dedicated) · [abandonware 2021](https://github.com/PaloAltoNetworks/azure-terraform-vmseries-fast-ha-failover) | working | niche |
| [azure/](azure/) — Standalone+ARS | Azure | Hub-and-spoke, standalone firewalls with Azure Route Server ECMP — well-suited as single-region dual-hub SD-WAN head-end with routed failover | orig | untested | well-worn-path |

---

## Notes

- **aws/gwlb-one-arm** and **aws/gwlb-two-arm** implement the same centralized inspection pattern as `centralized_design` but are hand-rolled Terraform rather than module-based. The two-arm overlay routing variant (FW-sourced SNAT via per-AZ EIPs) is a structural departure from the `centralized_design` example and is marked `orig` for that aspect.
- **azure/** is a single Terraform codebase with three HA modes controlled by feature flags (`enable_panos_ha`, `enable_lb_ha`). The three rows above represent distinct architectural patterns within that file; each has different provenance and recommendation.
- **Deployment-guide sources** without a specific URL indicate the pattern is documented in the VM-Series Deployment Guide but a precise section link has not been verified. Contributions welcome.
