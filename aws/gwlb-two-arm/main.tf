# --------------------------------------------------------------------------
# 1. PROVIDERS & DATA SOURCES
# --------------------------------------------------------------------------
terraform {
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
  }
}

provider "aws" {
  region = var.aws_region
}

data "aws_availability_zones" "available" {
  state = "available"
}

data "aws_ami" "vmseries" {
  most_recent = true
  owners      = ["aws-marketplace"]
  filter {
    name   = "name"
    values = ["PA-VM-AWS-${var.panos_version}*"]
  }
  filter {
    name   = "product-code"
    values = ["6njl1pau431dv1qxipg63mvah"] # VM-Series BYOL
  }
}

data "aws_ami" "ubuntu" {
  most_recent = true
  owners      = ["099720109477"] # Canonical
  filter {
    name   = "name"
    values = ["ubuntu/images/hvm-ssd/ubuntu-jammy-22.04-amd64-server-*"]
  }
  filter {
    name   = "architecture"
    values = ["x86_64"]
  }
}

locals {
  azs = slice(data.aws_availability_zones.available.names, 0, var.az_count)

  # Subnet offsets within each AZ block (cidrsubnet offset * 16 per AZ from /16 VPC → /24 subnets)
  subnet_offsets = {
    attachment = 0
    gwlb       = 1
    gwlbe      = 2
    data       = 3
    mgmt       = 4
    egress     = 5 # arm2 egress subnet — replaces one-arm's public/NAT-GW subnet
  }

  # Flat list of all inspection subnets for for_each creation
  all_inspection_subnets = flatten([
    for i, az in local.azs : [
      for name, offset in local.subnet_offsets : {
        key    = "${az}-${name}"
        az     = az
        az_idx = i
        name   = name
        cidr   = cidrsubnet(var.inspection_vpc_cidr, 8, i * 16 + offset)
      }
    ]
  ])

  # Workload VPC CIDRs carved from aggregate
  workload_newbits = var.workload_vpc_prefix_length - tonumber(split("/", var.workload_aggregate_cidr)[1])
}

# --------------------------------------------------------------------------
# 2. TRANSIT GATEWAY
# --------------------------------------------------------------------------
resource "aws_ec2_transit_gateway" "tgw" {
  description                     = "${var.prefix} transit gateway"
  default_route_table_association = "disable"
  default_route_table_propagation = "disable"
  tags                            = { Name = "${var.prefix}-tgw" }
}

# Inspection RT — associated with inspection VPC attachment.
# Workload routes propagated here so inspection VPC can return traffic to workloads.
resource "aws_ec2_transit_gateway_route_table" "inspection" {
  transit_gateway_id = aws_ec2_transit_gateway.tgw.id
  tags               = { Name = "${var.prefix}-inspection-rt" }
}

# Isolation RT — associated with workload VPC attachments.
# Default route sends all workload-initiated traffic to inspection VPC.
resource "aws_ec2_transit_gateway_route_table" "isolation" {
  transit_gateway_id = aws_ec2_transit_gateway.tgw.id
  tags               = { Name = "${var.prefix}-isolation-rt" }
}

resource "aws_ec2_transit_gateway_route" "isolation_default" {
  transit_gateway_route_table_id = aws_ec2_transit_gateway_route_table.isolation.id
  destination_cidr_block         = "0.0.0.0/0"
  transit_gateway_attachment_id  = aws_ec2_transit_gateway_vpc_attachment.inspection.id
}

# --------------------------------------------------------------------------
# 3. INSPECTION VPC & SUBNETS
# --------------------------------------------------------------------------
resource "aws_vpc" "inspection" {
  cidr_block           = var.inspection_vpc_cidr
  enable_dns_hostnames = true
  tags                 = { Name = "${var.prefix}-inspection-vpc" }
}

resource "aws_internet_gateway" "inspection" {
  vpc_id = aws_vpc.inspection.id
  tags   = { Name = "${var.prefix}-inspection-igw" }
}

resource "aws_subnet" "inspection" {
  for_each          = { for s in local.all_inspection_subnets : s.key => s }
  vpc_id            = aws_vpc.inspection.id
  availability_zone = each.value.az
  cidr_block        = each.value.cidr
  tags              = { Name = "${var.prefix}-${each.value.name}-${each.value.az}" }
}

# --------------------------------------------------------------------------
# 4. WORKLOAD VPCs & SUBNETS
# --------------------------------------------------------------------------
resource "aws_vpc" "workload" {
  count                = var.workload_vpc_count
  cidr_block           = cidrsubnet(var.workload_aggregate_cidr, local.workload_newbits, count.index)
  enable_dns_hostnames = true
  tags                 = { Name = "${var.prefix}-workload-${count.index}-vpc" }
}

# Single subnet per workload VPC — used for both TGW attachment and EC2 workload
resource "aws_subnet" "workload" {
  count             = var.workload_vpc_count
  vpc_id            = aws_vpc.workload[count.index].id
  availability_zone = local.azs[count.index % var.az_count]
  cidr_block        = cidrsubnet(aws_vpc.workload[count.index].cidr_block, 1, 0)
  tags              = { Name = "${var.prefix}-workload-${count.index}" }
}

# --------------------------------------------------------------------------
# 5. TGW ATTACHMENTS & ROUTE TABLE ASSOCIATIONS
# --------------------------------------------------------------------------
resource "aws_ec2_transit_gateway_vpc_attachment" "inspection" {
  transit_gateway_id                              = aws_ec2_transit_gateway.tgw.id
  vpc_id                                          = aws_vpc.inspection.id
  subnet_ids                                      = [for az in local.azs : aws_subnet.inspection["${az}-attachment"].id]
  transit_gateway_default_route_table_association = false
  transit_gateway_default_route_table_propagation = false
  tags                                            = { Name = "${var.prefix}-inspection-attachment" }
}

resource "aws_ec2_transit_gateway_vpc_attachment" "workload" {
  count                                           = var.workload_vpc_count
  transit_gateway_id                              = aws_ec2_transit_gateway.tgw.id
  vpc_id                                          = aws_vpc.workload[count.index].id
  subnet_ids                                      = [aws_subnet.workload[count.index].id]
  transit_gateway_default_route_table_association = false
  transit_gateway_default_route_table_propagation = false
  tags                                            = { Name = "${var.prefix}-workload-${count.index}-attachment" }
}

# Inspection VPC attachment → inspection RT
resource "aws_ec2_transit_gateway_route_table_association" "inspection" {
  transit_gateway_attachment_id  = aws_ec2_transit_gateway_vpc_attachment.inspection.id
  transit_gateway_route_table_id = aws_ec2_transit_gateway_route_table.inspection.id
}

# Workload attachments → isolation RT
resource "aws_ec2_transit_gateway_route_table_association" "workload" {
  count                          = var.workload_vpc_count
  transit_gateway_attachment_id  = aws_ec2_transit_gateway_vpc_attachment.workload[count.index].id
  transit_gateway_route_table_id = aws_ec2_transit_gateway_route_table.isolation.id
}

# Propagate workload VPC routes into inspection RT so return traffic can reach workloads
resource "aws_ec2_transit_gateway_route_table_propagation" "workload_to_inspection" {
  count                          = var.workload_vpc_count
  transit_gateway_attachment_id  = aws_ec2_transit_gateway_vpc_attachment.workload[count.index].id
  transit_gateway_route_table_id = aws_ec2_transit_gateway_route_table.inspection.id
}

# --------------------------------------------------------------------------
# 6. ROUTE TABLES
# --------------------------------------------------------------------------

# One route table per inspection subnet per AZ
resource "aws_route_table" "inspection" {
  for_each = { for s in local.all_inspection_subnets : s.key => s }
  vpc_id   = aws_vpc.inspection.id
  tags     = { Name = "${var.prefix}-${each.value.name}-${each.value.az}-rt" }
}

resource "aws_route_table_association" "inspection" {
  for_each       = { for s in local.all_inspection_subnets : s.key => s }
  subnet_id      = aws_subnet.inspection[each.key].id
  route_table_id = aws_route_table.inspection[each.key].id
}

# Attachment subnet: all traffic → GWLBE (bump-in-wire into inspection path)
resource "aws_route" "attachment_default" {
  for_each               = { for i, az in local.azs : az => i }
  route_table_id         = aws_route_table.inspection["${each.key}-attachment"].id
  destination_cidr_block = "0.0.0.0/0"
  vpc_endpoint_id        = aws_vpc_endpoint.gwlbe[each.key].id
}

# GWLBE subnet: workload-aggregate → TGW (E-W return traffic back to workloads after inspection)
# No default route here — internet egress exits via FW arm2, not through GWLBE.
resource "aws_route" "gwlbe_workload" {
  for_each               = { for i, az in local.azs : az => i }
  route_table_id         = aws_route_table.inspection["${each.key}-gwlbe"].id
  destination_cidr_block = var.workload_aggregate_cidr
  transit_gateway_id     = aws_ec2_transit_gateway.tgw.id
  depends_on             = [aws_ec2_transit_gateway_vpc_attachment.inspection]
}

# Mgmt subnet: default → IGW (FW mgmt ENI has a direct EIP; no NAT-GW needed)
resource "aws_route" "mgmt_default" {
  for_each               = { for i, az in local.azs : az => i }
  route_table_id         = aws_route_table.inspection["${each.key}-mgmt"].id
  destination_cidr_block = "0.0.0.0/0"
  gateway_id             = aws_internet_gateway.inspection.id
}

# Egress subnet: default → IGW (FW arm2 SNATs workload internet traffic out here)
resource "aws_route" "egress_default" {
  for_each               = { for i, az in local.azs : az => i }
  route_table_id         = aws_route_table.inspection["${each.key}-egress"].id
  destination_cidr_block = "0.0.0.0/0"
  gateway_id             = aws_internet_gateway.inspection.id
}

# Egress subnet: workload return traffic → TGW (internet→workload return after FW de-SNATs)
resource "aws_route" "egress_workload_return" {
  for_each               = { for i, az in local.azs : az => i }
  route_table_id         = aws_route_table.inspection["${each.key}-egress"].id
  destination_cidr_block = var.workload_aggregate_cidr
  transit_gateway_id     = aws_ec2_transit_gateway.tgw.id
  depends_on             = [aws_ec2_transit_gateway_vpc_attachment.inspection]
}

# Workload subnet: all traffic → TGW (forces all workload traffic through inspection)
resource "aws_route_table" "workload" {
  count  = var.workload_vpc_count
  vpc_id = aws_vpc.workload[count.index].id
  tags   = { Name = "${var.prefix}-workload-${count.index}-rt" }
}

resource "aws_route_table_association" "workload" {
  count          = var.workload_vpc_count
  subnet_id      = aws_subnet.workload[count.index].id
  route_table_id = aws_route_table.workload[count.index].id
}

resource "aws_route" "workload_default" {
  count                  = var.workload_vpc_count
  route_table_id         = aws_route_table.workload[count.index].id
  destination_cidr_block = "0.0.0.0/0"
  transit_gateway_id     = aws_ec2_transit_gateway.tgw.id
  depends_on             = [aws_ec2_transit_gateway_vpc_attachment.workload]
}

# --------------------------------------------------------------------------
# 7. SECURITY GROUPS
# --------------------------------------------------------------------------
resource "aws_security_group" "fw_mgmt" {
  name        = "${var.prefix}-fw-mgmt-sg"
  description = "Firewall management (ENI1 after mgmt-interface-swap)"
  vpc_id      = aws_vpc.inspection.id

  ingress {
    description = "SSH from allowed management CIDRs"
    from_port   = 22
    to_port     = 22
    protocol    = "tcp"
    cidr_blocks = var.allowed_mgmt_cidrs
  }

  ingress {
    description = "HTTPS from allowed management CIDRs"
    from_port   = 443
    to_port     = 443
    protocol    = "tcp"
    cidr_blocks = var.allowed_mgmt_cidrs
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = { Name = "${var.prefix}-fw-mgmt-sg" }
}

resource "aws_security_group" "fw_data" {
  name        = "${var.prefix}-fw-data-sg"
  description = "Firewall data interface (ENI0/arm1, GWLB target)"
  vpc_id      = aws_vpc.inspection.id

  ingress {
    description = "GENEVE from GWLB"
    from_port   = 6081
    to_port     = 6081
    protocol    = "udp"
    cidr_blocks = [var.inspection_vpc_cidr]
  }

  ingress {
    description = "GWLB health check"
    from_port   = 80
    to_port     = 80
    protocol    = "tcp"
    cidr_blocks = [var.inspection_vpc_cidr]
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = { Name = "${var.prefix}-fw-data-sg" }
}

# Egress SG — wide open. arm2 performs SNAT for internet-bound workload traffic;
# internet→workload return arrives here after FW de-SNATs and re-routes to TGW.
resource "aws_security_group" "fw_egress" {
  name        = "${var.prefix}-fw-egress-sg"
  description = "Firewall egress interface (ENI2/arm2, internet-facing SNAT)"
  vpc_id      = aws_vpc.inspection.id

  ingress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = { Name = "${var.prefix}-fw-egress-sg" }
}

resource "aws_security_group" "workload" {
  count       = var.workload_vpc_count
  name        = "${var.prefix}-workload-${count.index}-sg"
  description = "Workload test VM"
  vpc_id      = aws_vpc.workload[count.index].id

  ingress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = [aws_vpc.workload[count.index].cidr_block]
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = { Name = "${var.prefix}-workload-${count.index}-sg" }
}

# --------------------------------------------------------------------------
# 8. GATEWAY LOAD BALANCER
# --------------------------------------------------------------------------
resource "aws_lb" "gwlb" {
  name                             = "${var.prefix}-gwlb"
  load_balancer_type               = "gateway"
  enable_cross_zone_load_balancing = true

  dynamic "subnet_mapping" {
    for_each = { for i, az in local.azs : az => i }
    content {
      subnet_id = aws_subnet.inspection["${subnet_mapping.key}-gwlb"].id
    }
  }

  tags = { Name = "${var.prefix}-gwlb" }
}

resource "aws_lb_target_group" "gwlb" {
  name        = "${var.prefix}-gwlb-tg"
  port        = 6081
  protocol    = "GENEVE"
  target_type = "ip"
  vpc_id      = aws_vpc.inspection.id

  health_check {
    enabled  = true
    port     = 80
    protocol = "TCP"
  }

  stickiness {
    type    = "source_ip_dest_ip_proto"
    enabled = true
  }

  tags = { Name = "${var.prefix}-gwlb-tg" }
}

resource "aws_lb_listener" "gwlb" {
  load_balancer_arn = aws_lb.gwlb.arn

  default_action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.gwlb.arn
  }
}

# GWLB endpoint service — exposes the GWLB for per-AZ GWLBE endpoints
resource "aws_vpc_endpoint_service" "gwlb" {
  acceptance_required        = false
  gateway_load_balancer_arns = [aws_lb.gwlb.arn]
  tags                       = { Name = "${var.prefix}-gwlb-endpoint-service" }
}

# One GWLB endpoint per AZ in the gwlbe subnet
resource "aws_vpc_endpoint" "gwlbe" {
  for_each          = { for i, az in local.azs : az => i }
  vpc_id            = aws_vpc.inspection.id
  service_name      = aws_vpc_endpoint_service.gwlb.service_name
  vpc_endpoint_type = "GatewayLoadBalancer"
  subnet_ids        = [aws_subnet.inspection["${each.key}-gwlbe"].id]
  tags              = { Name = "${var.prefix}-gwlbe-${each.key}" }
}

# Register each FW data ENI IP as a GWLB target
resource "aws_lb_target_group_attachment" "fw_data" {
  for_each         = { for i, az in local.azs : az => i }
  target_group_arn = aws_lb_target_group.gwlb.arn
  target_id        = aws_network_interface.fw_data[each.key].private_ip
}

# --------------------------------------------------------------------------
# 9. FIREWALLS (VM-SERIES)
# --------------------------------------------------------------------------

# ENI0 — data subnet (becomes ethernet1/1 after mgmt-interface-swap) — arm1/GWLB target
resource "aws_network_interface" "fw_data" {
  for_each          = { for i, az in local.azs : az => i }
  subnet_id         = aws_subnet.inspection["${each.key}-data"].id
  source_dest_check = false
  security_groups   = [aws_security_group.fw_data.id]
  tags              = { Name = "${var.prefix}-fw-${each.key}-data-eni" }
}

# ENI1 — mgmt subnet (becomes management after mgmt-interface-swap)
resource "aws_network_interface" "fw_mgmt" {
  for_each        = { for i, az in local.azs : az => i }
  subnet_id       = aws_subnet.inspection["${each.key}-mgmt"].id
  security_groups = [aws_security_group.fw_mgmt.id]
  tags            = { Name = "${var.prefix}-fw-${each.key}-mgmt-eni" }
}

resource "aws_eip" "fw_mgmt" {
  for_each          = { for i, az in local.azs : az => i }
  domain            = "vpc"
  network_interface = aws_network_interface.fw_mgmt[each.key].id
  tags              = { Name = "${var.prefix}-fw-${each.key}-mgmt-eip" }
}

# ENI2 — egress subnet (becomes ethernet1/2 after mgmt-interface-swap) — arm2 internet egress
resource "aws_network_interface" "fw_egress" {
  for_each          = { for i, az in local.azs : az => i }
  subnet_id         = aws_subnet.inspection["${each.key}-egress"].id
  source_dest_check = false
  security_groups   = [aws_security_group.fw_egress.id]
  tags              = { Name = "${var.prefix}-fw-${each.key}-egress-eni" }
}

# EIP on arm2 — SNAT source IP visible to the internet for workload-initiated traffic
resource "aws_eip" "fw_egress" {
  for_each          = { for i, az in local.azs : az => i }
  domain            = "vpc"
  network_interface = aws_network_interface.fw_egress[each.key].id
  tags              = { Name = "${var.prefix}-fw-${each.key}-egress-eip" }
}

resource "aws_instance" "vmseries" {
  for_each      = { for i, az in local.azs : az => i }
  ami           = data.aws_ami.vmseries.id
  instance_type = var.vmseries_instance_type
  key_name      = var.key_name

  # ENI0 = data/arm1 (device_index 0) — VM-Series maps this to ethernet1/1 after swap
  network_interface {
    device_index         = 0
    network_interface_id = aws_network_interface.fw_data[each.key].id
  }

  # ENI1 = management (device_index 1) — VM-Series maps this to management after swap
  network_interface {
    device_index         = 1
    network_interface_id = aws_network_interface.fw_mgmt[each.key].id
  }

  # ENI2 = egress/arm2 (device_index 2) — VM-Series maps this to ethernet1/2 after swap
  network_interface {
    device_index         = 2
    network_interface_id = aws_network_interface.fw_egress[each.key].id
  }

  # init-cfg: DHCP on arm1, mgmt-interface-swap, GWLB overlay routing for arm2 internet egress
  user_data = base64encode(join("\n", compact([
    "type=dhcp-client",
    "op-command-modes=mgmt-interface-swap",
    "plugin-op-commands=aws-gwlb-inspect:enable,aws-gwlb-overlay-routing:enable",
    var.shared_user_data,
  ])))

  tags = { Name = "${var.prefix}-fw-${each.key}" }
}

# --------------------------------------------------------------------------
# 10. WORKLOAD VMs
# --------------------------------------------------------------------------

# IAM role for SSM access — workload VMs have no public IP; use SSM Session Manager
resource "aws_iam_role" "workload_ssm" {
  name = "${var.prefix}-workload-ssm-role"
  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Action    = "sts:AssumeRole"
      Effect    = "Allow"
      Principal = { Service = "ec2.amazonaws.com" }
    }]
  })
}

resource "aws_iam_role_policy_attachment" "workload_ssm" {
  role       = aws_iam_role.workload_ssm.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore"
}

resource "aws_iam_instance_profile" "workload_ssm" {
  name = "${var.prefix}-workload-ssm-profile"
  role = aws_iam_role.workload_ssm.name
}

resource "aws_instance" "workload" {
  count                = var.workload_vpc_count
  ami                  = data.aws_ami.ubuntu.id
  instance_type        = var.workload_instance_type
  key_name             = var.key_name
  subnet_id            = aws_subnet.workload[count.index].id
  iam_instance_profile = aws_iam_instance_profile.workload_ssm.name
  vpc_security_group_ids = [aws_security_group.workload[count.index].id]

  user_data = base64encode(<<-EOF
    #!/bin/bash
    apt-get update
    apt-get install -y nginx
    systemctl start nginx
    systemctl enable nginx
    echo "<h1>Workload VM ${count.index} (Nginx)</h1>" > /var/www/html/index.html
    EOF
  )

  tags = { Name = "${var.prefix}-workload-${count.index}" }
}

# --------------------------------------------------------------------------
# 11. VARIABLES
# --------------------------------------------------------------------------
variable "aws_region" {
  type = string
}

variable "prefix" {
  type    = string
  default = "panw"
}

variable "key_name" {
  description = "EC2 key pair name for SSH access to firewalls and workload VMs."
  type        = string
}

variable "allowed_mgmt_cidrs" {
  description = "CIDRs allowed to reach firewall management (SSH/HTTPS) via ENI1 public IP."
  type        = list(string)
}

variable "az_count" {
  description = "Number of AZs to deploy the inspection VPC across (1–3)."
  type        = number
  default     = 2
  validation {
    condition     = var.az_count >= 1 && var.az_count <= 3
    error_message = "az_count must be 1, 2, or 3."
  }
}

variable "inspection_vpc_cidr" {
  description = "CIDR for the inspection VPC. Must be at least /16 to accommodate per-AZ /24 subnets."
  type        = string
  default     = "10.0.0.0/16"
}

variable "workload_aggregate_cidr" {
  description = "Aggregate CIDR from which workload VPC CIDRs are carved."
  type        = string
  default     = "10.1.0.0/16"
}

variable "workload_vpc_prefix_length" {
  description = "Prefix length for each individual workload VPC (e.g., 24 for /24)."
  type        = number
  default     = 24
}

variable "workload_vpc_count" {
  description = "Number of workload VPCs to deploy."
  type        = number
  default     = 1
}

variable "panos_version" {
  description = "PAN-OS version to deploy, used to select the Marketplace BYOL AMI (e.g., \"11.2.8\")."
  type        = string
  default     = "11.2.8"
}

variable "vmseries_instance_type" {
  description = "EC2 instance type for VM-Series. Must support at least 3 ENIs."
  type        = string
  default     = "m5.xlarge"
}

variable "shared_user_data" {
  description = "Additional init-cfg parameters appended to all firewalls (e.g., panorama-server=x.x.x.x\\nvm-auth-key=xxx)."
  type        = string
  default     = ""
}

variable "workload_instance_type" {
  type    = string
  default = "t3.micro"
}

# --------------------------------------------------------------------------
# 12. OUTPUTS
# --------------------------------------------------------------------------
output "tgw_id" {
  value = aws_ec2_transit_gateway.tgw.id
}

output "firewall_mgmt_ips" {
  description = "Public EIPs for firewall management (ENI1) per AZ."
  value       = { for az, eip in aws_eip.fw_mgmt : az => eip.public_ip }
}

output "gwlb_arn" {
  value = aws_lb.gwlb.arn
}

output "fw_egress_eips" {
  description = "Firewall arm2 (egress) public EIPs per AZ — SNAT source IPs for internet-bound workload traffic."
  value       = { for az, eip in aws_eip.fw_egress : az => eip.public_ip }
}

output "workload_private_ips" {
  description = "Private IPs of workload test VMs. Access via SSM Session Manager."
  value       = { for i, vm in aws_instance.workload : "workload_${i}" => vm.private_ip }
}

output "inspection_vpc_id" {
  value = aws_vpc.inspection.id
}
