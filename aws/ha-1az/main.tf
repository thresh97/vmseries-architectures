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

data "aws_ami" "amazon_linux" {
  most_recent = true
  owners      = ["amazon"]
  filter {
    name   = "name"
    values = ["al2023-ami-2023.*-x86_64"]
  }
}

locals {
  az = data.aws_availability_zones.available.names[0]

  # Subnet offsets within the VPC CIDR
  subnet_offsets = {
    mgmt     = 1
    untrust  = 2
    trust    = 3
    workload = 4
    ha       = 5
  }
}

# --------------------------------------------------------------------------
# 2. PLACEMENT GROUP
# --------------------------------------------------------------------------
# Spread strategy ensures each FW is on a distinct physical rack within the AZ,
# preventing both from failing simultaneously due to a single hardware fault.
resource "aws_placement_group" "fw_spread" {
  name     = "${var.prefix}-fw-spread"
  strategy = "spread"
  tags     = { Name = "${var.prefix}-fw-spread" }
}

# --------------------------------------------------------------------------
# 3. VPC & SUBNETS
# --------------------------------------------------------------------------
resource "aws_vpc" "this" {
  cidr_block           = var.vpc_cidr
  enable_dns_support   = true
  enable_dns_hostnames = true
  tags                 = { Name = "${var.prefix}-vpc" }
}

resource "aws_internet_gateway" "igw" {
  vpc_id = aws_vpc.this.id
  tags   = { Name = "${var.prefix}-igw" }
}

resource "aws_subnet" "mgmt" {
  vpc_id            = aws_vpc.this.id
  cidr_block        = cidrsubnet(var.vpc_cidr, 8, local.subnet_offsets.mgmt)
  availability_zone = local.az
  tags              = { Name = "${var.prefix}-mgmt" }
}

resource "aws_subnet" "untrust" {
  vpc_id            = aws_vpc.this.id
  cidr_block        = cidrsubnet(var.vpc_cidr, 8, local.subnet_offsets.untrust)
  availability_zone = local.az
  tags              = { Name = "${var.prefix}-untrust" }
}

resource "aws_subnet" "trust" {
  vpc_id            = aws_vpc.this.id
  cidr_block        = cidrsubnet(var.vpc_cidr, 8, local.subnet_offsets.trust)
  availability_zone = local.az
  tags              = { Name = "${var.prefix}-trust" }
}

resource "aws_subnet" "workload" {
  vpc_id            = aws_vpc.this.id
  cidr_block        = cidrsubnet(var.vpc_cidr, 8, local.subnet_offsets.workload)
  availability_zone = local.az
  tags              = { Name = "${var.prefix}-workload" }
}

resource "aws_subnet" "ha" {
  vpc_id            = aws_vpc.this.id
  cidr_block        = cidrsubnet(var.vpc_cidr, 8, local.subnet_offsets.ha)
  availability_zone = local.az
  tags              = { Name = "${var.prefix}-ha" }
}

# --------------------------------------------------------------------------
# 4. ROUTE TABLES
# --------------------------------------------------------------------------

# Mgmt and untrust subnets are public — default via IGW
resource "aws_route_table" "public" {
  vpc_id = aws_vpc.this.id
  route {
    cidr_block = "0.0.0.0/0"
    gateway_id = aws_internet_gateway.igw.id
  }
  tags = { Name = "${var.prefix}-public-rt" }
}

resource "aws_route_table_association" "mgmt" {
  subnet_id      = aws_subnet.mgmt.id
  route_table_id = aws_route_table.public.id
}

resource "aws_route_table_association" "untrust" {
  subnet_id      = aws_subnet.untrust.id
  route_table_id = aws_route_table.public.id
}

# Workload subnet default route → active FW trust ENI (.4 on FW1 initially).
# On failover, PAN-OS HA plugin updates this route to point to FW2 trust ENI
# and moves the untrust/trust .100 secondary IPs to FW2.
resource "aws_route_table" "workload" {
  vpc_id = aws_vpc.this.id

  route {
    cidr_block           = "0.0.0.0/0"
    network_interface_id = aws_network_interface.fw1_trust.id
  }

  # Direct return path for management CIDRs — avoids hairpinning admin traffic through FW
  dynamic "route" {
    for_each = toset(var.allowed_mgmt_cidrs)
    content {
      cidr_block = route.value
      gateway_id = aws_internet_gateway.igw.id
    }
  }

  tags = { Name = "${var.prefix}-workload-rt" }
}

resource "aws_route_table_association" "workload" {
  subnet_id      = aws_subnet.workload.id
  route_table_id = aws_route_table.workload.id
}

# --------------------------------------------------------------------------
# 5. SECURITY GROUPS
# --------------------------------------------------------------------------
resource "aws_security_group" "mgmt" {
  name        = "${var.prefix}-mgmt-sg"
  description = "Firewall management access"
  vpc_id      = aws_vpc.this.id

  ingress {
    description = "SSH"
    from_port   = 22
    to_port     = 22
    protocol    = "tcp"
    cidr_blocks = var.allowed_mgmt_cidrs
  }
  ingress {
    description = "HTTPS"
    from_port   = 443
    to_port     = 443
    protocol    = "tcp"
    cidr_blocks = var.allowed_mgmt_cidrs
  }
  ingress {
    description = "ICMP from management CIDRs"
    from_port   = 8
    to_port     = 0
    protocol    = "icmp"
    cidr_blocks = var.allowed_mgmt_cidrs
  }
  ingress {
    description = "All VPC-internal traffic"
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = [var.vpc_cidr]
  }
  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }
  tags = { Name = "${var.prefix}-mgmt-sg" }
}

resource "aws_security_group" "untrust" {
  name        = "${var.prefix}-untrust-sg"
  description = "Firewall untrust — open for lab/demo"
  vpc_id      = aws_vpc.this.id

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
  tags = { Name = "${var.prefix}-untrust-sg" }
}

resource "aws_security_group" "trust" {
  name        = "${var.prefix}-trust-sg"
  description = "Firewall trust — VPC-internal only"
  vpc_id      = aws_vpc.this.id

  ingress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = [var.vpc_cidr]
  }
  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }
  tags = { Name = "${var.prefix}-trust-sg" }
}

resource "aws_security_group" "ha" {
  name        = "${var.prefix}-ha-sg"
  description = "Firewall HA — VPC-internal only"
  vpc_id      = aws_vpc.this.id

  ingress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = [var.vpc_cidr]
  }
  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = [var.vpc_cidr]
  }
  tags = { Name = "${var.prefix}-ha-sg" }
}

# --------------------------------------------------------------------------
# 6. IAM ROLE (secondary IP + route table management for HA failover)
# --------------------------------------------------------------------------
resource "aws_iam_role" "fw" {
  name = "${var.prefix}-fw-role"
  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Action    = "sts:AssumeRole"
      Effect    = "Allow"
      Principal = { Service = "ec2.amazonaws.com" }
    }]
  })
}

resource "aws_iam_policy" "fw" {
  name        = "${var.prefix}-fw-policy"
  description = "VM-Series HA failover: secondary IP migration and route table updates"
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid    = "CloudWatch"
        Effect = "Allow"
        Action = [
          "logs:CreateLogGroup",
          "logs:CreateLogStream",
          "logs:PutLogEvents",
          "cloudwatch:PutMetricData"
        ]
        Resource = "*"
      },
      {
        Sid    = "HAFailover"
        Effect = "Allow"
        Action = [
          "ec2:DescribeInstances",
          "ec2:DescribeNetworkInterfaces",
          "ec2:DescribeRouteTables",
          "ec2:ReplaceRoute",
          "ec2:AssignPrivateIpAddresses",
          "ec2:UnassignPrivateIpAddresses"
        ]
        Resource = "*"
      }
    ]
  })
}

resource "aws_iam_role_policy_attachment" "fw" {
  role       = aws_iam_role.fw.name
  policy_arn = aws_iam_policy.fw.arn
}

resource "aws_iam_instance_profile" "fw" {
  name = "${var.prefix}-fw-profile"
  role = aws_iam_role.fw.name
}

# --------------------------------------------------------------------------
# 7. NETWORK INTERFACES
# --------------------------------------------------------------------------
# Addressing convention:
#   .4  = FW1 primary
#   .5  = FW2 primary
#   .100 = Floating VIP (secondary on FW1 at boot; migrated to FW2 on failover)
#
# NIC order matches PAN-OS device_index expectations:
#   0 = mgmt, 1 = HA, 2 = trust, 3 = untrust

# FW1
resource "aws_network_interface" "fw1_mgmt" {
  subnet_id       = aws_subnet.mgmt.id
  security_groups = [aws_security_group.mgmt.id]
  private_ips     = [cidrhost(aws_subnet.mgmt.cidr_block, 4)]
  description     = "${var.prefix}-fw1-mgmt"
  tags            = { Name = "${var.prefix}-fw1-mgmt" }
}

resource "aws_network_interface" "fw1_ha" {
  subnet_id       = aws_subnet.ha.id
  security_groups = [aws_security_group.ha.id]
  private_ips     = [cidrhost(aws_subnet.ha.cidr_block, 4)]
  description     = "${var.prefix}-fw1-ha"
  tags            = { Name = "${var.prefix}-fw1-ha" }
}

resource "aws_network_interface" "fw1_trust" {
  subnet_id               = aws_subnet.trust.id
  security_groups         = [aws_security_group.trust.id]
  source_dest_check       = false
  private_ip_list_enabled = true
  private_ip_list         = [
    cidrhost(aws_subnet.trust.cidr_block, 4),   # primary
    cidrhost(aws_subnet.trust.cidr_block, 100)  # floating VIP
  ]
  description = "${var.prefix}-fw1-trust"
  tags        = { Name = "${var.prefix}-fw1-trust" }
}

resource "aws_network_interface" "fw1_untrust" {
  subnet_id               = aws_subnet.untrust.id
  security_groups         = [aws_security_group.untrust.id]
  source_dest_check       = false
  private_ip_list_enabled = true
  private_ip_list         = [
    cidrhost(aws_subnet.untrust.cidr_block, 4),   # primary
    cidrhost(aws_subnet.untrust.cidr_block, 100)  # floating VIP
  ]
  description = "${var.prefix}-fw1-untrust"
  tags        = { Name = "${var.prefix}-fw1-untrust" }
}

# FW2
resource "aws_network_interface" "fw2_mgmt" {
  subnet_id       = aws_subnet.mgmt.id
  security_groups = [aws_security_group.mgmt.id]
  private_ips     = [cidrhost(aws_subnet.mgmt.cidr_block, 5)]
  description     = "${var.prefix}-fw2-mgmt"
  tags            = { Name = "${var.prefix}-fw2-mgmt" }
}

resource "aws_network_interface" "fw2_ha" {
  subnet_id       = aws_subnet.ha.id
  security_groups = [aws_security_group.ha.id]
  private_ips     = [cidrhost(aws_subnet.ha.cidr_block, 5)]
  description     = "${var.prefix}-fw2-ha"
  tags            = { Name = "${var.prefix}-fw2-ha" }
}

resource "aws_network_interface" "fw2_trust" {
  subnet_id         = aws_subnet.trust.id
  security_groups   = [aws_security_group.trust.id]
  source_dest_check = false
  private_ips       = [cidrhost(aws_subnet.trust.cidr_block, 5)]
  description       = "${var.prefix}-fw2-trust"
  tags              = { Name = "${var.prefix}-fw2-trust" }
}

resource "aws_network_interface" "fw2_untrust" {
  subnet_id         = aws_subnet.untrust.id
  security_groups   = [aws_security_group.untrust.id]
  source_dest_check = false
  private_ips       = [cidrhost(aws_subnet.untrust.cidr_block, 5)]
  description       = "${var.prefix}-fw2-untrust"
  tags              = { Name = "${var.prefix}-fw2-untrust" }
}

# --------------------------------------------------------------------------
# 8. ELASTIC IPs
# --------------------------------------------------------------------------
resource "aws_eip" "fw1_mgmt" {
  domain            = "vpc"
  network_interface = aws_network_interface.fw1_mgmt.id
  tags              = { Name = "${var.prefix}-fw1-mgmt-eip" }
}

resource "aws_eip" "fw2_mgmt" {
  domain            = "vpc"
  network_interface = aws_network_interface.fw2_mgmt.id
  tags              = { Name = "${var.prefix}-fw2-mgmt-eip" }
}

# Untrust VIP EIP — associated with the .100 secondary IP on FW1 at boot.
# On failover, PAN-OS re-associates this EIP to .100 on FW2 untrust via EC2 API.
resource "aws_eip" "untrust_vip" {
  domain                    = "vpc"
  network_interface         = aws_network_interface.fw1_untrust.id
  associate_with_private_ip = cidrhost(aws_subnet.untrust.cidr_block, 100)
  tags                      = { Name = "${var.prefix}-untrust-vip-eip" }
}

resource "aws_eip" "workload" {
  domain   = "vpc"
  instance = aws_instance.workload.id
  tags     = { Name = "${var.prefix}-workload-eip" }
}

# --------------------------------------------------------------------------
# 9. FIREWALLS (VM-SERIES)
# --------------------------------------------------------------------------
resource "aws_instance" "fw1" {
  ami                  = data.aws_ami.vmseries.id
  instance_type        = var.vmseries_instance_type
  key_name             = var.key_name
  iam_instance_profile = aws_iam_instance_profile.fw.name
  placement_group      = aws_placement_group.fw_spread.id
  user_data            = var.fw1_user_data

  root_block_device {
    volume_type           = "gp3"
    delete_on_termination = true
  }

  # NIC order: 0=mgmt, 1=ha, 2=trust, 3=untrust
  network_interface {
    device_index         = 0
    network_interface_id = aws_network_interface.fw1_mgmt.id
  }
  network_interface {
    device_index         = 1
    network_interface_id = aws_network_interface.fw1_ha.id
  }
  network_interface {
    device_index         = 2
    network_interface_id = aws_network_interface.fw1_trust.id
  }
  network_interface {
    device_index         = 3
    network_interface_id = aws_network_interface.fw1_untrust.id
  }

  tags = { Name = "${var.prefix}-fw1" }
}

resource "aws_instance" "fw2" {
  ami                  = data.aws_ami.vmseries.id
  instance_type        = var.vmseries_instance_type
  key_name             = var.key_name
  iam_instance_profile = aws_iam_instance_profile.fw.name
  placement_group      = aws_placement_group.fw_spread.id
  user_data            = var.fw2_user_data

  root_block_device {
    volume_type           = "gp3"
    delete_on_termination = true
  }

  network_interface {
    device_index         = 0
    network_interface_id = aws_network_interface.fw2_mgmt.id
  }
  network_interface {
    device_index         = 1
    network_interface_id = aws_network_interface.fw2_ha.id
  }
  network_interface {
    device_index         = 2
    network_interface_id = aws_network_interface.fw2_trust.id
  }
  network_interface {
    device_index         = 3
    network_interface_id = aws_network_interface.fw2_untrust.id
  }

  tags = { Name = "${var.prefix}-fw2" }
}

# --------------------------------------------------------------------------
# 10. WORKLOAD VM
# --------------------------------------------------------------------------
resource "aws_instance" "workload" {
  ami           = data.aws_ami.amazon_linux.id
  instance_type = var.workload_instance_type
  key_name      = var.key_name
  subnet_id     = aws_subnet.workload.id
  vpc_security_group_ids = [aws_security_group.mgmt.id]

  user_data = <<-EOF
    #!/bin/bash
    yum update -y
    yum install -y nginx
    systemctl start nginx
    systemctl enable nginx
    echo "<h1>${var.prefix} workload (Nginx)</h1>" > /usr/share/nginx/html/index.html
    EOF

  tags = { Name = "${var.prefix}-workload" }
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
  description = "EC2 key pair name."
  type        = string
}

variable "allowed_mgmt_cidrs" {
  description = "CIDRs allowed to reach firewall management (SSH/HTTPS) and workload VM."
  type        = list(string)
}

variable "vpc_cidr" {
  description = "VPC CIDR. /16 recommended — subnets are carved as /24s."
  type        = string
  default     = "10.0.0.0/16"
}

variable "panos_version" {
  description = "PAN-OS version to deploy, used to select the Marketplace BYOL AMI (e.g., \"11.2.8\")."
  type        = string
  default     = "11.2.8"
}

variable "vmseries_instance_type" {
  description = "EC2 instance type for VM-Series. Must support ≥4 ENIs."
  type        = string
  default     = "m5.xlarge"
}

variable "fw1_user_data" {
  description = "Full init-cfg bootstrap string for FW1 (newline-separated key=value pairs)."
  type        = string
}

variable "fw2_user_data" {
  description = "Full init-cfg bootstrap string for FW2 (newline-separated key=value pairs)."
  type        = string
}

variable "workload_instance_type" {
  type    = string
  default = "t3.micro"
}

# --------------------------------------------------------------------------
# 12. OUTPUTS
# --------------------------------------------------------------------------
output "fw1_mgmt_ip" {
  description = "FW1 management public IP (SSH/HTTPS)."
  value       = aws_eip.fw1_mgmt.public_ip
}

output "fw2_mgmt_ip" {
  description = "FW2 management public IP (SSH/HTTPS)."
  value       = aws_eip.fw2_mgmt.public_ip
}

output "untrust_vip_ip" {
  description = "Floating untrust VIP public IP — follows the active firewall on failover."
  value       = aws_eip.untrust_vip.public_ip
}

output "workload_public_ip" {
  description = "Workload test VM public IP."
  value       = aws_eip.workload.public_ip
}

output "vpc_id" {
  value = aws_vpc.this.id
}
