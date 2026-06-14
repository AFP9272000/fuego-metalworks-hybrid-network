terraform {
  required_version = ">= 1.3"
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
  }
}

provider "aws" {
  region = "us-west-2"
}

# =====================================================================
# EDIT THESE TWO EVERY SESSION. The lab pre-creates VPC-Onprem and its
# public subnets and hands you fresh IDs each session (new account each
# time). Get them from the lab step or with:
#   aws ec2 describe-vpcs --filters Name=tag:Name,Values=VPC-Onprem \
#     --query "Vpcs[0].VpcId" --output text
#   aws ec2 describe-subnets --filters Name=vpc-id,Values=<vpc> \
#     --query "Subnets[].{Id:SubnetId,CIDR:CidrBlock,AZ:AvailabilityZone}" --output table
# =====================================================================
locals {
  vpc_id           = "vpc-0cc3017dd6f11b6d0"     # this session's VPC-Onprem
  public_subnet_id = "subnet-05ad00bb88cd57e40"  # this session's Public Subnet 1
}

variable "key_name" {
  description = "Name of the lab EC2 key pair in us-west-2"
  type        = string
}

variable "admin_cidr" {
  description = "Source CIDR allowed to SSH to public instances"
  type        = string
  default     = "0.0.0.0/0"
}

variable "onprem_cidr" {
  description = "On-premises supernet reachable over the VPN"
  type        = string
  default     = "10.10.0.0/16"
}

# ---- Read the lab VPC + public subnet; do NOT create or modify them ----
data "aws_vpc" "lab" {
  id = local.vpc_id
}

data "aws_subnet" "public" {
  id = local.public_subnet_id
}

data "aws_ami" "al2023" {
  most_recent = true
  owners      = ["amazon"]
  filter {
    name   = "name"
    values = ["al2023-ami-2023.*-x86_64"]
  }
  filter {
    name   = "virtualization-type"
    values = ["hvm"]
  }
}

# ---------------- Network (only the private subnet is ours) ----------------

resource "aws_subnet" "private" {
  vpc_id            = local.vpc_id
  cidr_block        = cidrsubnet(data.aws_vpc.lab.cidr_block, 8, 30) # 10.X.30.0/24 in a /16 VPC; change 30 if it collides
  availability_zone = data.aws_subnet.public.availability_zone
  tags              = { Name = "fuego-private" }
  # No map_public_ip_on_launch: setting it would call ModifySubnetAttribute,
  # which the lab IAM denies. A private subnet does not need it.
}

resource "aws_route_table" "private" {
  vpc_id = local.vpc_id
  tags   = { Name = "fuego-private-rt" }
}

resource "aws_route_table_association" "private" {
  subnet_id      = aws_subnet.private.id
  route_table_id = aws_route_table.private.id
}

# Return path: on-prem-bound traffic from the DB goes to the VPN gateway ENI
resource "aws_route" "private_to_onprem" {
  route_table_id         = aws_route_table.private.id
  destination_cidr_block = var.onprem_cidr
  network_interface_id   = aws_instance.vpn_gw.primary_network_interface_id
}

# ---------------- Security ----------------

resource "aws_security_group" "web" {
  name        = "fuego-sg-web"
  description = "Web portal: HTTP from anywhere, SSH from admin"
  vpc_id      = local.vpc_id

  ingress {
    description = "HTTP"
    from_port   = 80
    to_port     = 80
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }
  ingress {
    description = "SSH"
    from_port   = 22
    to_port     = 22
    protocol    = "tcp"
    cidr_blocks = [var.admin_cidr]
  }
  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }
  tags = { Name = "fuego-sg-web" }
}

resource "aws_security_group" "db" {
  name        = "fuego-sg-db"
  description = "Database: app port from web tier and on-prem office over VPN"
  vpc_id      = local.vpc_id

  ingress {
    description     = "DB port from web tier"
    from_port       = 3306
    to_port         = 3306
    protocol        = "tcp"
    security_groups = [aws_security_group.web.id]
  }
  ingress {
    description = "DB port from on-prem office over VPN"
    from_port   = 3306
    to_port     = 3306
    protocol    = "tcp"
    cidr_blocks = ["10.10.10.0/24"]
  }
  ingress {
    description = "ICMP from on-prem office over VPN (tunnel reachability)"
    from_port   = -1
    to_port     = -1
    protocol    = "icmp"
    cidr_blocks = ["10.10.10.0/24"]
  }
  ingress {
    description = "SSH from within the VPC"
    from_port   = 22
    to_port     = 22
    protocol    = "tcp"
    cidr_blocks = [data.aws_vpc.lab.cidr_block]
  }
  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }
  tags = { Name = "fuego-sg-db" }
}

resource "aws_security_group" "vpn_gw" {
  name        = "fuego-sg-vpngw"
  description = "VPN gateway: IKE/NAT-T from internet, forwarding for VPC and on-prem"
  vpc_id      = local.vpc_id

  ingress {
    description = "IKE"
    from_port   = 500
    to_port     = 500
    protocol    = "udp"
    cidr_blocks = ["0.0.0.0/0"]
  }
  ingress {
    description = "IPsec NAT-T"
    from_port   = 4500
    to_port     = 4500
    protocol    = "udp"
    cidr_blocks = ["0.0.0.0/0"]
  }
  ingress {
    description = "SSH"
    from_port   = 22
    to_port     = 22
    protocol    = "tcp"
    cidr_blocks = [var.admin_cidr]
  }
  ingress {
    description = "Forwarded traffic from the VPC"
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = [data.aws_vpc.lab.cidr_block]
  }
  ingress {
    description = "Decapsulated traffic from on-prem"
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = [var.onprem_cidr]
  }
  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }
  tags = { Name = "fuego-sg-vpngw" }
}

resource "aws_network_acl" "private" {
  vpc_id     = local.vpc_id
  subnet_ids = [aws_subnet.private.id]

  ingress {
    rule_no    = 100
    action     = "allow"
    protocol   = "-1"
    cidr_block = data.aws_vpc.lab.cidr_block
    from_port  = 0
    to_port    = 0
  }
  ingress {
    rule_no    = 110
    action     = "allow"
    protocol   = "-1"
    cidr_block = var.onprem_cidr
    from_port  = 0
    to_port    = 0
  }
  egress {
    rule_no    = 100
    action     = "allow"
    protocol   = "-1"
    cidr_block = data.aws_vpc.lab.cidr_block
    from_port  = 0
    to_port    = 0
  }
  egress {
    rule_no    = 110
    action     = "allow"
    protocol   = "-1"
    cidr_block = var.onprem_cidr
    from_port  = 0
    to_port    = 0
  }
  tags = { Name = "fuego-nacl-private" }
}

# ---------------- Compute ----------------

resource "aws_instance" "web" {
  ami                         = data.aws_ami.al2023.id
  instance_type               = "t2.micro"
  subnet_id                   = local.public_subnet_id
  vpc_security_group_ids      = [aws_security_group.web.id]
  key_name                    = var.key_name
  associate_public_ip_address = true
  user_data                   = file("${path.module}/web_userdata.sh")
  tags                        = { Name = "fuego-web" }
}

resource "aws_instance" "db" {
  ami                    = data.aws_ami.al2023.id
  instance_type          = "t2.micro"
  subnet_id              = aws_subnet.private.id
  vpc_security_group_ids = [aws_security_group.db.id]
  key_name               = var.key_name
  user_data              = file("${path.module}/db_userdata.sh")
  tags                   = { Name = "fuego-db" }
}

resource "aws_instance" "vpn_gw" {
  ami                         = data.aws_ami.al2023.id
  instance_type               = "t2.micro"
  subnet_id                   = local.public_subnet_id
  vpc_security_group_ids      = [aws_security_group.vpn_gw.id]
  key_name                    = var.key_name
  associate_public_ip_address = true
  source_dest_check           = false
  tags                        = { Name = "fuego-vpn-gw" }
}

resource "aws_eip" "web" {
  domain   = "vpc"
  instance = aws_instance.web.id
  tags     = { Name = "fuego-web-eip" }
}

resource "aws_eip" "vpn_gw" {
  domain   = "vpc"
  instance = aws_instance.vpn_gw.id
  tags     = { Name = "fuego-vpn-gw-eip" }
}

# ---------------- Outputs ----------------

output "web_public_ip"      { value = aws_eip.web.public_ip }
output "vpn_gw_public_ip"   { value = aws_eip.vpn_gw.public_ip }
output "web_private_ip"     { value = aws_instance.web.private_ip }
output "db_private_ip"      { value = aws_instance.db.private_ip }
output "vpn_gw_private_ip"  { value = aws_instance.vpn_gw.private_ip }
output "private_subnet_cidr" { value = aws_subnet.private.cidr_block }
output "vpc_id"             { value = local.vpc_id }
