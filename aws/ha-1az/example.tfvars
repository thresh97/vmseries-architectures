aws_region = "us-east-1"
prefix     = "panw"
key_name   = "my-keypair"

allowed_mgmt_cidrs = ["203.0.113.0/24", "198.51.100.50/32"]

# --------------------------------------------------------------------------
# VPC
# --------------------------------------------------------------------------
vpc_cidr = "10.0.0.0/16"

# --------------------------------------------------------------------------
# VM-Series Firewalls
# --------------------------------------------------------------------------
panos_version          = "11.2.8"
vmseries_instance_type = "m5.xlarge"

# Bootstrap init-cfg for each firewall (full key=value pairs, newline-separated).
# type=dhcp-client is NOT set here — mgmt uses static IP via ENI; omit unless needed.
# To connect to Panorama, set panorama-server and vm-auth-key.
fw1_user_data = "panorama-server=10.255.0.4\nvm-auth-key=0123456789\nhostname=fw1"
fw2_user_data = "panorama-server=10.255.0.4\nvm-auth-key=0123456789\nhostname=fw2"

# --------------------------------------------------------------------------
# Workload VM
# --------------------------------------------------------------------------
workload_instance_type = "t3.micro"
