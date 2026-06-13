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

variable "key_name" {
  description = "Name of an existing EC2 key pair in us-west-2 for SSH access"
  type        = string
}

variable "admin_cidr" {
  description = "Source CIDR allowed to SSH to public instances (tighten from 0.0.0.0/0 if you can)"
  type        = string
  default     = "0.0.0.0/0"
}

variable "onprem_cidr" {
  description = "On-premises supernet reachable over the VPN"
  type        = string
  default     = "10.10.0.0/16"
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

# ---------------- Network ----------------

resource "aws_vpc" "main" {
  cidr_block           = "10.20.0.0/16"
  enable_dns_support   = true
  enable_dns_hostnames = true
  tags                 = { Name = "fuego-vpc" }
}

resource "aws_internet_gateway" "igw" {
  vpc_id = aws_vpc.main.id
  tags   = { Name = "fuego-igw" }
}

resource "aws_subnet" "public" {
  vpc_id                  = aws_vpc.main.id
  cidr_block              = "10.20.1.0/24"
  availability_zone       = "us-west-2a"
  map_public_ip_on_launch = true
  tags                    = { Name = "fuego-public" }
}

resource "aws_subnet" "private" {
  vpc_id            = aws_vpc.main.id
  cidr_block        = "10.20.2.0/24"
  availability_zone = "us-west-2a"
  tags              = { Name = "fuego-private" }
}

resource "aws_route_table" "public" {
  vpc_id = aws_vpc.main.id
  route {
    cidr_block = "0.0.0.0/0"
    gateway_id = aws_internet_gateway.igw.id
  }
  tags = { Name = "fuego-public-rt" }
}

resource "aws_route_table_association" "public" {
  subnet_id      = aws_subnet.public.id
  route_table_id = aws_route_table.public.id
}

resource "aws_route_table" "private" {
  vpc_id = aws_vpc.main.id
  tags   = { Name = "fuego-private-rt" }
}

resource "aws_route_table_association" "private" {
  subnet_id      = aws_subnet.private.id
  route_table_id = aws_route_table.private.id
}

# Sends on-prem-bound traffic to the VPN gateway instance (used once the tunnel is up in the VPN phase)
resource "aws_route" "private_to_onprem" {
  route_table_id         = aws_route_table.private.id
  destination_cidr_block = var.onprem_cidr
  network_interface_id   = aws_instance.vpn_gw.primary_network_interface_id
}

# ---------------- Security ----------------

resource "aws_security_group" "web" {
  name        = "fuego-sg-web"
  description = "Web portal: HTTP from anywhere, SSH from admin"
  vpc_id      = aws_vpc.main.id

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
  description = "Database: app port from the web tier and the on-prem office over VPN only"
  vpc_id      = aws_vpc.main.id

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
    description = "ICMP from on-prem office over VPN (tunnel reachability test)"
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
    cidr_blocks = ["10.20.0.0/16"]
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
  description = "VPN gateway: IKE and NAT-T from internet, forwarding for VPC and on-prem"
  vpc_id      = aws_vpc.main.id

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
    cidr_blocks = ["10.20.0.0/16"]
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
  vpc_id     = aws_vpc.main.id
  subnet_ids = [aws_subnet.private.id]

  ingress {
    rule_no    = 100
    action     = "allow"
    protocol   = "-1"
    cidr_block = "10.20.0.0/16"
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
    cidr_block = "10.20.0.0/16"
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
  subnet_id                   = aws_subnet.public.id
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
  subnet_id                   = aws_subnet.public.id
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

output "web_public_ip"     { value = aws_eip.web.public_ip }
output "vpn_gw_public_ip"  { value = aws_eip.vpn_gw.public_ip }
output "web_private_ip"    { value = aws_instance.web.private_ip }
output "db_private_ip"     { value = aws_instance.db.private_ip }
output "vpn_gw_private_ip" { value = aws_instance.vpn_gw.private_ip }
output "vpc_id"            { value = aws_vpc.main.id }
