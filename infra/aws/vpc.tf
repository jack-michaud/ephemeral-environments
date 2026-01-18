# Ephemeral Environments - VPC Configuration
# Using public subnets with strict security groups (no NAT = $0 idle cost)
# EC2 instances get public IPs for outbound to Cloudflare, but SG blocks all inbound

resource "aws_vpc" "main" {
  cidr_block           = var.vpc_cidr
  enable_dns_hostnames = true
  enable_dns_support   = true

  tags = {
    Name = "${local.name_prefix}-vpc"
  }
}

# Internet Gateway for outbound connectivity
resource "aws_internet_gateway" "main" {
  vpc_id = aws_vpc.main.id

  tags = {
    Name = "${local.name_prefix}-igw"
  }
}

# Get available AZs
data "aws_availability_zones" "available" {
  state = "available"
}

# Public subnets (2 AZs for redundancy)
resource "aws_subnet" "public" {
  count                   = 2
  vpc_id                  = aws_vpc.main.id
  cidr_block              = cidrsubnet(var.vpc_cidr, 8, count.index)
  availability_zone       = data.aws_availability_zones.available.names[count.index]
  map_public_ip_on_launch = true  # EC2 gets public IP for outbound

  tags = {
    Name = "${local.name_prefix}-public-${count.index + 1}"
  }
}

# Route table for public subnets
resource "aws_route_table" "public" {
  vpc_id = aws_vpc.main.id

  route {
    cidr_block = "0.0.0.0/0"
    gateway_id = aws_internet_gateway.main.id
  }

  tags = {
    Name = "${local.name_prefix}-public-rt"
  }
}

resource "aws_route_table_association" "public" {
  count          = 2
  subnet_id      = aws_subnet.public[count.index].id
  route_table_id = aws_route_table.public.id
}

# Security group for environment EC2 instances
# Blocks ALL inbound from internet - traffic only via Cloudflare Tunnel
resource "aws_security_group" "environment" {
  name        = "${local.name_prefix}-environment-sg"
  description = "Security group for ephemeral environment instances"
  vpc_id      = aws_vpc.main.id

  # No inbound rules from internet!
  # Cloudflared uses outbound connections, responses come back on established connections

  # Allow all outbound (needed for cloudflared, docker pulls, etc)
  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = {
    Name = "${local.name_prefix}-environment-sg"
  }
}

# Security group for Lambda (in VPC if needed)
resource "aws_security_group" "lambda" {
  name        = "${local.name_prefix}-lambda-sg"
  description = "Security group for Lambda functions"
  vpc_id      = aws_vpc.main.id

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = {
    Name = "${local.name_prefix}-lambda-sg"
  }
}

# Outputs
output "vpc_id" {
  value = aws_vpc.main.id
}

output "subnet_ids" {
  value = aws_subnet.public[*].id
}

output "environment_security_group_id" {
  value = aws_security_group.environment.id
}
