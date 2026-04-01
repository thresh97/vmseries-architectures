aws_region = "us-east-1"
prefix     = "panw"
key_name   = "my-keypair"

allowed_mgmt_cidrs = ["203.0.113.0/24", "198.51.100.50/32"]

# --------------------------------------------------------------------------
# Inspection VPC
# --------------------------------------------------------------------------
az_count            = 2
inspection_vpc_cidr = "10.0.0.0/16"

# --------------------------------------------------------------------------
# Workload VPCs (carved from aggregate)
# --------------------------------------------------------------------------
# 2 workload VPCs: 10.1.0.0/24 and 10.1.1.0/24
workload_aggregate_cidr    = "10.1.0.0/16"
workload_vpc_prefix_length = 24
workload_vpc_count         = 2

# --------------------------------------------------------------------------
# VM-Series Firewall
# --------------------------------------------------------------------------
panos_version          = "11.2.8"
vmseries_instance_type = "m5.xlarge"

# init-cfg parameters appended to all firewalls (newline-separated key=value)
# type=dhcp-client and op-command-modes=mgmt-interface-swap are always set automatically.
shared_user_data = "panorama-server=10.255.0.4\nvm-auth-key=0123456789"

# --------------------------------------------------------------------------
# Workload VMs
# --------------------------------------------------------------------------
workload_instance_type = "t3.micro"
