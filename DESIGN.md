# VM-Series & AI Firewall: Architecture and Scaling Guide

> A synthesis of architecture, scaling, and design principles for VM-Series and AI Firewall deployments across public cloud providers. Reflects accumulated experience and published guidance — official PANW documentation is linked throughout and consolidated at the end.

---

## 1. Design Philosophy: Modularity, Composability, and Simplicity

To achieve true cloud-native scale, architectures must move away from monolithic "all-in-one" designs. Instead, the focus should be on three core pillars that facilitate seamless growth:

* **Modularity:** Treat the firewall as a specialized functional block. By separating the **Connectivity Tier** (handling tunnels/routing) from the **Inspection Tier** (handling policy/DPI), you can scale each component independently based on its specific resource demands (CPU clock speed vs. core count).
* **Composability:** Design with the "Building Block" approach. Use cloud-native services (Load Balancers, Route Servers, Transit Gateways) to stitch together multiple firewall modules. This allows you to swap out or add blocks without re-architecting the entire network fabric.
* **Simplicity:** Complexity is the enemy of scaling. A simple design — using standard BGP, basic bootstrapping, and centralized Panorama/Strata Cloud Manager (SCM) management — reduces the risk of "state leaks" and asymmetric routing errors. The more predictable the packet walk, the easier it is to automate and scale.

## 2. Siting and Segmentation Strategy

A scalable architecture requires careful "siting" — the deliberate placement and anchoring of management and security functions within the network topology — to ensure long-term flexibility and cross-region compatibility.

### Management Plane Isolation (Panorama/SCM)

* **The "Out-of-Band" Principle:** Never place Panorama in the same VPC/VNet as the firewalls it manages.
* **Future-Proofing:** Placing Panorama in a dedicated "Shared Services" or "Management" VPC/VNet ensures that future network changes, CIDR migrations, or region expansions do not impact management access.
* **Global Reach:** This centralized siting allows for a harmonized management plane that can easily reach firewalls across multiple regions or different cloud accounts/subscriptions.

### Zero Circular Dependency (Management Traffic)

A critical architectural requirement is that management traffic (Panorama-to-Firewall and Firewall-to-Update-Server) must remain independent of the firewall's own dataplane.

* **The Rule:** Management traffic from the mgmt interface must **never** depend on a flow through the dataplane interfaces (eth1, eth2, etc.) of the same firewall or any firewall within that same logical cluster.
* **Operational Impact:** Circular dependencies break Infrastructure-as-Code (IaC) deployments (e.g., Terraform/Ansible) because the firewall cannot be fully provisioned or updated until its policy is active, but its policy cannot be pushed until it is manageable.
* **Day 2 Resilience:** In the event of a dataplane misconfiguration or routing loop, an independent management path ensures you retain access to the device to remediate the issue without requiring serial console access or instance redeployment.

### Functional Segmentation

Keep security functions modularly separate at both the VPC/VNet and VM levels. Avoid the "One Firewall to Rule Them All" trap.

* **Connectivity/Edge Hub:** Dedicated firewalls for NVA-terminated SD-WAN and IPsec overlays. This tier scales **vertically**. For cloud-native connectivity — Direct Connect, ExpressRoute, VNG S2S VPN, TGW S2S VPN — prefer terminating at the cloud-native gateway and routing cleartext through the E/W horizontally scaled inspection tier rather than through NVA-terminated overlays.
* **Internet Ingress/Egress (N-S Inbound and S-N Outbound):** Separate firewalls for public-facing traffic. While often grouped, this tier handles two distinct patterns:
  * **North-South Inbound (N-S / Inbound):** Internet-to-VPC traffic. Focused on DNAT, public service exposure, and protecting inbound applications.
  * **South-North Outbound (S-N / Outbound):** VPC-to-Internet traffic. Focused on secure web gateway functions, SNAT, and controlling egress "phone-home" traffic.
  * **Modularity Benefit:** Separating these allows for specific public IP management and scale-out patterns (like GWLB) without mixing internal traffic or causing resource contention between inbound surges and outbound updates.
* **East-West (Internal) Inspection:** Dedicated firewalls for un-natted, private-to-private flows (intra-cloud, inter-cloud, and hybrid cloud-to-on-premises). This tier is often the most elastic and benefits the most from **horizontal scaling**.

## 3. Scaling Strategies

### Vertical Scaling (Scale-Up)

Adding more CPU cores or memory to an existing instance by changing the instance type (e.g., moving to a higher-tier "Compute Optimized" family).

* **Encryption Efficiency:** Later generations and more modern instance types featuring faster cores can more efficiently process encryption and decryption tasks on a per-core basis. This is crucial for maintaining throughput as cipher suites become more complex.
* **Mandatory for Connectivity:** Because a single IPsec tunnel is processed serially by a **single Dataplane (DP) core**, adding more instances (horizontal scaling) does not help a single high-bandwidth tunnel. You must scale vertically to a faster/larger core.
* **Driven by Policy Size:** Large security rulebases and extensive object lists consume significant Management Plane (MP) memory. If commit times are slow or the MP is swapping, you must scale vertically to an instance with more RAM.

### Horizontal Scaling (Scale-Out)

Adding more VM instances as backends behind cloud-native load balancers, which perform health checks and hash flows across the cluster. The specific topology — particularly the return path — varies by cloud provider and traffic pattern. Not all post-inspection traffic returns through a load balancer (e.g., Azure Internal Standard LB with HA Ports for E/W traffic routes return traffic directly).

* **Ideal for Inspection:** Best for scaling deep packet inspection across many flows.
* **Symmetry Dependency:** Entirely dependent on **symmetric load balancer hashing** if Source NAT (SNAT) is not applied.

### Autoscaling (Automated Horizontal Scale-Out)

Autoscaling via cloud-native mechanisms (AWS Auto Scaling Groups, Azure VM Scale Sets, GCP Managed Instance Groups) is the operational extension of horizontal scaling. Key principles:

* **Bootstrapping:** With Panorama or SCM, do not embed interface management profiles or health check configuration in a local `bootstrap.xml` — this creates a split-config state where the instance appears healthy before policy is applied. Place all network, interface, and health check configuration in Panorama/SCM so that policy and health check readiness are atomic at commit-all. Post PAN-OS 10.2, Panorama and SCM can push threat and content packages to bootstrapping instances before commit-all, eliminating the window where a new instance inspects traffic with stale signatures.
* **State Drain:** Session drops during scale-in are expected and handled gracefully by cloud-native applications. Legacy lift-and-shift workloads with long-lived flows and no reconnect logic are the exception. Where available, use LB-level connection draining and lifecycle hooks; draining capabilities vary by cloud and LB type.
* **License Deactivation:** With FW Flex licensing, each instance must deactivate its license before termination to avoid leaking license credits. This introduces a dependency into the scale-in lifecycle that must be coordinated with ASG/VMSS termination hooks — requires careful testing and planning before enabling autoscaling in production.

> Cloud-specific autoscaling implementation will be covered in per-cloud guides. Note: autoscaling is not currently practical in OCI due to the requirement for static IP addressing on non-primary (dataplane) NICs.

### Session State in Horizontally Scaled Clusters

Horizontally scaled firewall clusters behind cloud load balancers have historically operated with **no shared session state**. Each firewall instance maintains its own independent session table. The load balancer uses symmetric hashing to keep both directions of a flow pinned to the same instance — and as long as hashing is stable, this works well. The model is simple, operationally lightweight, and scales linearly with the cluster.

The consequence is that any event that breaks hashing — a scale-in event removing an instance, an instance health check failure, or a load balancer flow rebalance — results in the replacement instance seeing mid-flow packets with no corresponding session entry. The instance drops the packet. For short-lived flows and cloud-native applications with reconnect logic, this is handled gracefully. For long-lived TCP connections or legacy applications without reconnect logic, the dropped flow is a visible disruption.

**Session Resiliency** (released November 2023) addresses this for specific topologies by introducing an external Redis cache as a shared session store. When enabled, each firewall instance writes session state to Redis as flows are created. If the load balancer rehashes an existing flow to a different instance — due to a failure or rebalance — the receiving instance queries Redis, reconstructs the session context, and continues processing the flow without dropping it.

This is a meaningful operational improvement for environments with long-lived flows, but the feature comes with significant constraints:

* **Cloud and LB scope:** Session Resiliency is supported only on **AWS with Gateway Load Balancer** (with "Rebalance Existing Flows" enabled) and **GCP with Internal Passthrough Network Load Balancer**. It is not available on Azure, OCI, or with any other load balancer type.
* **Traffic scope — L4 only:** Inspection of rehashed flows is **Layer 4 only**. App-ID, Advanced Threat Prevention, URL Filtering, and other L7 security profiles are not applied to flows recovered from Redis. Full L7 inspection applies only to sessions processed from the initial SYN on the instance that owns the flow.
* **NAT exclusion:** Session Resiliency only works for **un-natted flows**. NAT modifies the session key (src/dst IP and port), so the session entry written by the originating instance cannot be matched by a receiving instance seeing the post-NAT or pre-NAT packet. Any flow that passes through SNAT or DNAT is excluded.
* **External Redis dependency:** Each deployment requires a managed Redis cluster — **AWS ElastiCache for Redis** or **GCP Memorystore for Redis** (Standard tier, same region and zone, AUTH and in-transit encryption required). This introduces an additional managed service with its own HA, patching, sizing, and cost considerations.

**Rehashing latency matters.** Session Resiliency can only recover a flow after the load balancer has detected the failure and rehashed the flow to a new instance. The practical recovery time is therefore bounded not just by Redis lookup latency, but by how quickly the LB itself acts. GCP's Internal Passthrough NLB rehashes existing flows quickly once an instance is marked unhealthy, making the recovery window short. AWS GWLB rehashes significantly more slowly — the disruption window before a recovering instance even sees the rehashed packets is meaningfully longer. This difference affects how much real-world benefit Session Resiliency delivers in each cloud, independent of the Redis configuration.

The practical trade-off: Session Resiliency eliminates flow drops during instance failure and rebalancing events, but only for the subset of traffic that is L4 and un-natted. The external Redis dependency and LB rehashing latency add operational complexity and limit the feature's effectiveness in ways that are not always obvious from the documentation. For most horizontally scaled inspection tiers handling private-to-private E/W traffic — which is already un-natted by design — the feature is applicable and worth evaluating. For N-S traffic with SNAT or DNAT in the path, it does not apply.

## 4. Connectivity Best Practices: Cloud-Native VPN vs. NVA Overlay

In modern hybrid-cloud architectures, the method of tunnel termination significantly impacts the scalability of the inspection tier. Where possible, offloading tunnel termination to cloud-native gateways eliminates the connectivity scaling constraints introduced in Section 3 and unlocks the E/W horizontal inspection tier introduced in Section 2.

* **Cloud-Native VPN Preference:** For remote sites within the same administrative domain (e.g., branch offices or secondary data centers), prefer using cloud-native S2S VPN services (AWS Site-to-Site VPN, Azure VPN Gateway, GCP Cloud VPN) for tunnel termination.
* **Decoupling for Scale:** Terminating tunnels at the cloud gateway level removes the Siting constraint and vertical scaling requirement from the firewall — a single IPsec tunnel no longer pins a flow to a single DP core on a specific instance.
* **Inspection Architecture:** Once the cloud gateway decapsulates the traffic, the resulting cleartext flows can be routed through an East-West horizontally scaled inspection tier, distributing internal traffic across multiple firewall instances using symmetric load balancing and effectively bypassing the single-core IPsec performance ceiling.

## 5. Connectivity Tier: Stateful VPN/SD-WAN Overlay Symmetry and BGP

Because connectivity relies on stateful, encrypted overlays, it is subject to the **Siting Constraint**, which dictates how these resources must be architected for resilience.

### Connectivity Siting

**Siting** is the deterministic "anchoring" of a flow to a specific firewall instance.

* **Virtual Router Scope:** PAN-OS supports multiple tunnels with ECMP and symmetric return when tunnel interfaces share the same security zone — but all of this is bounded by the virtual router, which must reside on a single instance. You can distribute load across many tunnels on one firewall; you cannot distribute a single routing domain across multiple firewall instances. There is no mechanism to decapsulate on Firewall A and return traffic via Firewall B.
* **Impact:** For un-natted connectivity traffic, you must maintain a **Singular Logical Path**. This architectural "pinning" is why connectivity tiers do not scale horizontally for a single routing domain.

### Achieving Symmetry via BGP

Dynamic routing (BGP) is the preferred method for managing encrypted overlays and failover in the cloud. It provides a standardized way to handle prefix availability without manual intervention.

* **Standardized Path Selection:** In complex cloud environments, achieving symmetry in a connectivity hub requires intentional BGP route manipulation to ensure that one instance is the primary anchor for both directions of traffic:
  * **Inbound Path (Remote Site to Cloud):** One NVA must make its routes less preferred when advertising to the remote firewall (e.g., via AS-Path Prepending), ensuring the other NVA is the primary anchor for inbound traffic.
  * **Outbound Path (Cloud to Remote Site):** One NVA must make routes received from the remote site less preferred before re-advertising them into the cloud fabric, ensuring the same instance anchors both directions.
* **Avoid DIY Cloud API Routing:** Using custom scripts or Cloud APIs to update route tables (e.g., swapping a static route target during failure) is a complex "Do-It-Yourself" effort that should be avoided. It introduces substantial operational risk, delays during failover, and high maintenance overhead compared to native BGP convergence.
* **Result:** Standardized BGP creates an Active/Passive logical path that preserves stateful inspection and tunnel integrity while remaining compatible with cloud-native route servers.

## 6. Advanced Symmetric Hashing & Cloud Routing

Maintaining session symmetry for un-natted traffic in a horizontally scaled cluster is one of the most complex challenges in cloud architecture. Each cloud handles this coordination differently.

### Cloud-Specific Hashing Notes

* **GCP — Internal Passthrough NLB:** Uses instance-based flow tracking rather than VIP-based hashing. Sessions are anchored to the specific firewall instance, not the load balancer VIP — which is what enables GCP to support multi-interface un-natted flows across a horizontal cluster, the exception to the one-arm requirement described below.
* **OCI — Flexible NLB Symmetric Hashing:** Disabled by default; must be explicitly enabled alongside source/destination header preservation. Flows should remain within the same Availability Domain to avoid asymmetric routing across AD boundaries.
* **Azure — ISLB with HA Ports (E/W):** Flow symmetry guaranteed when the NVA cluster sits behind a single ISLB with a single backend pool and frontend IP. Both directions of a flow traverse the same LB, sharing the same hash decision.
* **Azure — ELB + ISLB (N-S Inbound DNAT):** Two-LB design where ELB handles public inbound and ISLB distributes to the firewall cluster. Symmetry is not guaranteed — each LB makes independent hash decisions. PAN-OS reference architectures solve this by configuring SNAT on the firewall egress interface for DNAT flows, anchoring return traffic through the same instance regardless of LB hashing.
* **Azure — GWLB (N-S Inbound):** Bump-in-the-wire before the ELB; solves symmetry for internet ingress. Firewall performs full inbound inspection but must hold the public certificate — rotation and renewal managed outside Azure's native certificate management.
* **Azure — GWLB + ELB (S-N Outbound):** ELB outbound NAT rules SNAT workload source IPs — the firewall sees the NAT address, not the original workload IP. Individual workload identity is lost, making per-workload policy enforcement impractical. Only viable for narrow use cases such as ADCs or DNS appliances with dedicated PIPs and management NICs.
* **AWS — TGW/CNE Appliance Mode:** When building E/W inspection via AWS Transit Gateway (TGW) or Cloud Network Engine (CNE), Appliance Mode must be enabled on the VPC attachment. By default, AWS favors local AZ routing — a packet may enter the TGW in AZ-A while the destination workload is in AZ-B, causing the return path to hit a different firewall instance. Appliance Mode enforces session state at the TGW, forcing return traffic back to the same ENI and AZ where the session originated regardless of where the destination workload resides.

For horizontally scaled E/W inspection of private-to-private un-natted flows, the correct pattern across all clouds is a single-interface / one-arm design — traffic enters and exits the firewall through the same interface, traversing the same load balancer. This ensures both directions of a flow share the same hash decision and are pinned to the same firewall instance, preserving session state without SNAT.

The following cloud LB mechanisms support this pattern for active-active horizontal scaling:

* **AWS** — Gateway Load Balancer (GWLB): GENEVE encapsulation with built-in flow stickiness
* **Azure** — Internal Standard Load Balancer (ISLB) with HA Ports: all ports/protocols, single interface
* **GCP** — Internal Passthrough Network Load Balancer: instance-based flow tracking
* **OCI** — Flexible Network Load Balancer with symmetric hashing explicitly enabled

**Anti-Pattern — Multi-Interface Without SNAT:** Routing traffic in via a load balancer on one interface and out via a separate interface or load balancer will cause asymmetric session handling and dropped flows in all clouds except GCP. GCP's Internal Passthrough NLB is the only mechanism with instance-based flow coordination that can handle multi-interface un-natted flows across a horizontal cluster. In all other clouds, this design requires SNAT to work — which defeats the purpose of transparent inspection.

**Anti-Pattern — Asymmetric GWLBE Traversal (AWS):** In AWS GWLB designs, both directions of a flow — client-to-server and server-to-client — must traverse the exact same GWLB Endpoint (GWLBE). A design where forward traffic enters via GWLBE-A and return traffic exits via GWLBE-B (e.g., Workload A → GWLBE-A → GWLB → VM-Series → GWLB → GWLBE-B → Workload B) breaks session symmetry. The GWLBE is the stickiness anchor — GWLB flow affinity is scoped per-endpoint, so crossing endpoints for the same flow guarantees a different VM-Series instance handles each direction, dropping the session.

A related constraint: VM-Series cannot originate a flow on a GWLB. All GWLB-encapsulated flows must be initiated from a GWLBE — the firewall can only receive and return traffic within an existing GWLBE-anchored session. Any architecture that requires VM-Series to initiate traffic toward a workload via GWLB is not supported.

## 7. Cloud Load Balancer Reference: Firewall Integration

Not all cloud load balancers are suited for transparent firewall inspection. The table below identifies the LB types used with VM-Series by cloud, whether they preserve source IP (transparent/passthrough), and their primary use case.

| Cloud | Load Balancer | Transparent (Source IP Preserved)? | Primary Use Case |
|-------|---------------|-------------------------------------|------------------|
| **AWS** | Gateway Load Balancer (GWLB) | Yes — GENEVE encapsulation | N-S Inbound, E/W inspection |
| **AWS** | Application Load Balancer (ALB) with Ingress Routing (IGW edge association) | Yes — GWLB intercepts upstream of ALB; firewall sees original client IP and performs full inbound inspection. Firewall must hold the public certificate; rotation and renewal managed outside ACM | N-S Inbound inspection via GWLB upstream of ALB |
| **AWS** | Application Load Balancer (ALB) with More Specific Routes (inter-subnet) | Partial — ALB proxies connection; source IP only visible via XFF. SSL offload at ALB delivers cleartext to firewall (XFF readable without firewall decrypt). If ALB re-encrypts to backend, firewall must decrypt that leg — though this is often simpler to configure and maintain on an internal leg | N-S Inbound; L7 inspection with XFF-based source identity |
| **AWS** | Network Load Balancer (NLB) with Ingress Routing (IGW edge association) | Yes — source IP preserved at VM-Series and workload; GWLB intercept is upstream of NLB | N-S Inbound inspection via GWLB + NLB |
| **AWS** | Network Load Balancer (NLB) with More Specific Routes (inter-subnet) | No — source IP preservation incompatible with inter-subnet GWLBE steering | Not recommended for transparent inspection in this topology |
| **AWS** | ALB or NLB as public origin behind external WAF/CDN with More Specific Routes | Partial — client IP already lost at WAF/CDN edge; real source IP recoverable via XFF inserted by WAF/CDN. No conflict with source IP preservation. MSR works cleanly in this topology | N-S Inbound; external WAF/CDN termination with XFF-based source identity at firewall |
| **Azure** | ELB as public origin behind external WAF/CDN | Partial — CDN/WAF public IP reaches firewall as source; original client IP carried in XFF. | N-S Inbound; behaves identically to direct internet ingress via ELB inbound NAT rule. Firewall SNATs to workload; workload reads original client identity from XFF. |
| **Azure** | Internal Standard Load Balancer (ISLB) with HA Ports | Yes — all ports/protocols | E/W inspection; return path is direct, not through a second LB |
| **Azure** | Gateway Load Balancer (GWLB) | Yes — VXLAN encapsulation | N-S Inbound in practice; chained to a public-facing LB or Public IP. S-N Outbound is impractical — ELB outbound NAT rules SNAT workload source IPs, losing per-workload identity. See Section 6 for caveats. |
| **Azure** | External Load Balancer (ELB) — Inbound NAT rule | Yes — client source IP preserved to firewall | N-S Inbound; public-facing ingress with inbound DNAT to a specific backend. Client IP visible at firewall for policy enforcement; not preserved to the backend workload. |
| **Azure** | External Load Balancer (ELB) — Outbound NAT rule | N/A — all egress traffic is NAT'd to a cloud public IP | S-N Outbound; provides SNAT for workload internet egress. Firewall NAT policy must apply DNAT and SNAT. Firewall sees original workload source IP for policy enforcement; workload backend does not see original client source IP. |
| **Azure** | Application Gateway (AppGW) — firewall dataplane IP/port as backend | No — AppGW proxies the connection; original client IP recoverable via XFF inserted by AppGW | N-S Inbound; AppGW provides WAF, SSL offload, and L7 routing. Firewall is the backend target — AppGW opens a new connection to the firewall dataplane IP/port. Firewall sees AppGW as source; client identity requires XFF. |
| **Azure** | Application Gateway (AppGW) — workload backend pool, firewall inspection via UDR | No — AppGW proxies upstream; firewall inspects the AppGW-to-workload leg. Original client IP in XFF only. | N-S Inbound; AppGW handles WAF and SSL offload, workloads are the backend pool. UDRs steer AppGW-to-workload traffic through the firewall cluster. Symmetric routing achieved via ISLB with HA Ports — both forward and return traffic on the AppGW-to-workload leg hash to the same firewall instance. |
| **GCP** | Network Security Integration (NSI) — In-band / Packet Intercept | Yes — GENEVE encapsulation (UDP 6081) preserves original src/dst IPs. Transparent at workload NIC. NAT applied after intercept (egress) or before (ingress), so firewall always sees private IPs. No route table changes required; traffic steered via firewall policy rules with `apply_security_profile_group` action | N-S Inbound and E/W inspection; producer-consumer model with VM-Series behind Internal Passthrough NLB in producer VPC. Note: non-SYN TCP packets dropped if session not tracked |
| **GCP** | Internal Passthrough Network Load Balancer — standalone | Yes — L3/L4 passthrough; instance-based flow tracking ensures symmetry across firewall cluster without SNAT | E/W inspection; traffic steered via policy-based routing or custom static routes |
| **GCP** | Internal Passthrough Network Load Balancer — NSI producer backend | Yes — GENEVE encapsulation applied by NSI; instance-based flow tracking | Producer-side LB fronting the firewall cluster in the NSI producer VPC. See NSI row for full producer-consumer architecture. |
| **GCP** | External Passthrough Network Load Balancer | Yes — direct server return (DSR); original src/dst IPs preserved | N-S Inbound |
| **GCP** | External Application Load Balancer (Global / Regional) | No — Envoy proxy terminates connection; real client IP recoverable via X-Forwarded-For (XFF) header inserted by the load balancer | Public-facing HTTPS app delivery; XFF required for source identity at firewall |
| **GCP** | Internal Application Load Balancer | No — Envoy proxy terminates connection; XFF inserted for client IP visibility | Internal HTTPS routing; XFF required for source identity at firewall |
| **OCI** | Flexible Network Load Balancer (private, transparent mode) | Yes — L3/L4 passthrough, preserves src/dst IP. Symmetric hashing available (must be explicitly enabled; off by default). When enabled, both forward and return traffic are consistently hashed to the same firewall instance without SNAT. Supports N-S Inbound and SD-WAN egress use cases where NLB may only see return traffic | N-S Inbound, E/W inspection, and SD-WAN egress via VCN route tables |
| **OCI** | Flexible Load Balancer | No — L4/L7 proxy, terminates connection | Application delivery (HTTP/HTTPS); not suited for transparent inspection |

> "Transparent" here means the firewall sees the original client source IP without NAT or proxy modification. This is a prerequisite for policy enforcement based on source identity and for stateful return-path symmetry in un-natted designs.

## 8. Instance Selection Principles

* **Compute Optimized Priority:** Always prioritize "Compute Optimized" families for any compute-heavy operations. This includes single-tunnel IPsec performance, high-volume encryption/decryption tasks (SSL forward proxy), and the application of intensive Security Profiles (Advanced Threat Prevention, DLP, etc.).
* **Networking Offloads:** Published VM-Series performance numbers are achieved with DPDK and SR-IOV enabled. Always select instances that support accelerated networking drivers (AWS ENA, Azure Accelerated Networking, GCP gVNIC) and verify they are enabled at the cloud provider level — these enable the kernel-bypass and hardware NIC virtualization that DPDK and SR-IOV depend on. Accelerated networking is enabled by default in PAN-OS but should be verified. An instance without these active will not reach published throughput figures regardless of core count or instance size.
* **Memory-to-Core Ratio:** If the environment handles a **massive policy rulebase**, select "Memory Optimized" or "Standard" families to gain additional RAM without necessarily increasing the software license core count.

## 9. Technical Constraints & Performance Envelopes

### PAN-OS ECMP Limits

* **4-Path FIB Limit:** PAN-OS supports a maximum of **4 equal-cost paths** per destination in the FIB.
* **NIC Density:** While more NICs don't increase aggregate throughput, they help scale tunnel capacity (GRE/VPN) as long as the design stays within the 4-path ECMP limit.

### Cloud Network Acceleration (DPDK & SR-IOV)

DPDK and SR-IOV are not optional optimizations — they are the foundation of line-rate NVA performance in cloud. DPDK enables kernel-bypass packet processing by having dataplane cores poll the NIC directly, eliminating hypervisor and OS network stack overhead. SR-IOV provides hardware-level NIC virtualization, allowing the VM to interact with the physical NIC with minimal hypervisor involvement.

* **Verify Enablement:** Accelerated networking must be enabled at the cloud provider level (instance type and NIC configuration). Accelerated networking is enabled by default in PAN-OS but should be verified. An instance running without SR-IOV/DPDK active will exhibit significantly degraded throughput regardless of core count or instance size.
* **Monitoring Implication:** PAN-OS splits cores between the Management Plane and Dataplane. DPDK polling pegs DP cores continuously while MP cores run at normal utilization. The hypervisor aggregates across all cores and reports a blended number — for example a flat ~75% — that accurately reflects neither DP load nor MP load. Hypervisor CPU is not a reliable indicator of firewall load and should not be used for scaling decisions. Use PAN-OS dataplane utilization metrics instead — see Section 10.

## 10. Capacity Management and Cloud-Native Metrics

Aggregate VM CPU metrics from the hypervisor are insufficient for capacity management of VM-Series in cloud. DPDK polling keeps dataplane cores continuously active, making hypervisor-reported CPU meaningless as a load signal. Autoscaling policies, alerting thresholds, and capacity decisions must be based on metrics emitted from inside the firewall itself.

The VM-Series plugin, configured within Panorama or SCM, enables the firewall to emit PAN-OS performance metrics directly as cloud-native metrics — into CloudWatch (AWS), Azure Application Insights (Azure), Cloud Monitoring / Stackdriver (GCP), or OCI Monitoring (OCI). This gives cloud-native autoscaling groups, dashboards, and alerting the meaningful signals they need.

> **OCI Note:** While OCI Monitoring provides full visibility into the key capacity metrics below, autoscaling is not practically viable in OCI today. Non-primary NIC interfaces require static IP addressing — DHCP is not supported on dataplane interfaces — making dynamic instance provisioning into a cluster impractical. OCI metrics are therefore a capacity management and monitoring play, used to inform manual scaling decisions rather than drive automated lifecycle events.

The key metrics to expose and act on:

* **Data Plane Utilization:** Actual packet processing load on the dataplane cores — the true indicator of inspection capacity consumption and the primary trigger for horizontal scale-out decisions.
* **SSL Proxy Utilization:** Key indicator of decryption bottlenecks. SSL forward proxy is CPU-intensive and often saturates before general dataplane capacity — frequently the trigger for vertical scaling.
* **Management Plane Memory:** Tracks the memory impact of policy rulebase size. A leading indicator that the instance needs vertical scaling to a higher-memory type before commit times degrade or the MP begins swapping.

## 11. Decoupled Scaling (FW Flex)

The **Software NGFW Flex** (FW Flex) licensing model is the operational "glue" that enables a modular and composable architecture. By decoupling software core counts from the underlying cloud instance size, organizations can build highly specialized security blocks.

* **Architectural Modularity:** FW Flex allows you to use a different mix of cores and Cloud Delivered Security Services for each deployment. You can deploy a high-memory/low-core instance for a Management/Panorama block and a high-core/high-PPS instance for an Inspection block, all under the same flexible licensing framework.
* **Breaking Resource Envelopes:** Cloud providers link network performance (PPS/Bandwidth) and RAM to instance size. Decoupled scaling allows you to provision a large 16-core instance to gain the necessary "network envelope" or RAM for a complex policy, while only licensing 4 or 8 cores for the PAN-OS Dataplane.
* **Composability:** This decoupling ensures that as your requirements change (e.g., needing more RAM for a larger rulebase), you can swap instance types without triggering a complete re-licensing of the software, facilitating the "building block" approach.

## 12. Key Principles Summary

Successful VM-Series deployment in public cloud requires treating the firewall as a specialized functional block rather than a monolithic appliance. Separate the connectivity tier from the inspection tier, manage each independently, and resist the temptation to collapse functions onto a single device or cluster.

Management plane isolation and zero circular dependencies are non-negotiable foundations. Panorama or SCM must live out-of-band in a dedicated VPC/VNet, and management traffic must never depend on the firewall's own dataplane — both for IaC reliability and Day 2 operational resilience.

Scaling strategy follows function. Connectivity tiers — IPsec and SD-WAN overlays — are constrained to a single DP core per tunnel and must scale vertically. Where possible, offload tunnel termination to cloud-native VPN gateways entirely, which decouples the connectivity constraint and allows the resulting cleartext traffic to flow through a horizontally scaled E/W inspection tier. Inspection tiers scale horizontally behind cloud-native load balancers, but session symmetry for un-natted flows requires disciplined design: one-arm / single-interface topologies in AWS, Azure, and OCI; GCP's Internal Passthrough NLB is the only exception with native multi-interface flow coordination.

Published performance numbers assume DPDK and SR-IOV are active. Accelerated networking must be enabled at both the cloud provider and PAN-OS levels — without it, throughput will fall well short of sizing expectations regardless of instance size. Capacity management must rely on PAN-OS metrics emitted via the VM-Series plugin, not hypervisor CPU. PAN-OS splits cores between the Management Plane and Dataplane — DPDK polling pegs DP cores continuously while MP cores run at normal utilization. The hypervisor aggregates across all cores and reports a blended number, for example a flat ~75%, that accurately reflects neither DP load nor MP load and is therefore useless as a scaling signal.

FW Flex licensing is the architectural glue that makes modularity practical. Decoupling software core counts from instance size allows each functional block — connectivity, inspection, management — to be right-sized independently without re-licensing, and is the enabler of the building-block approach this guide is built around.

## Technical Documentation & Public References

* [VM-Series Performance and Capacity on Public Clouds](https://docs.paloaltonetworks.com/vm-series/11-1/vm-series-performance-capacity/vm-series-performance-capacity)
* [Performance Monitoring: Management vs Dataplane (KB)](https://knowledgebase.paloaltonetworks.com/KCSArticleDetail?id=kA10g000000ClS0CAK)
* [VM-Series Licensing Models](https://docs.paloaltonetworks.com/vm-series/virtualization-features/vm-series-licensing)
* [GCP Network Security Integration: In-band Integration Overview](https://docs.cloud.google.com/network-security-integration/docs/in-band/in-band-integration-overview)
* [OCI: Enabling Flexible Security Architectures with Symmetric Hashing on the OCI Network Load Balancer](https://blogs.oracle.com/cloud-infrastructure/flexible-security-symmetric-hashing-oci-nlb)
