# Configure the AWS Provider
provider "aws" {
  region = "eu-central-1"
  access_key = ""
  secret_key=""
}


# # 1. Create vpc - Virtual Private Cloud 
resource "aws_vpc" "bitcoin" {
  cidr_block = "10.50.0.0/16"   # 10.10.0.0 netmask 255.255.0.0 
}
# # 2. Create Internet Gateway
resource "aws_internet_gateway" "gw" {
  vpc_id = aws_vpc.bitcoin.id
}
# # 3. Create Custom Route Table
resource "aws_route_table" "bitcoin-route-table" {
  vpc_id = aws_vpc.bitcoin.id

  route {
    cidr_block = "0.0.0.0/0" # IPv4
    gateway_id = aws_internet_gateway.gw.id
  }

  route {
    ipv6_cidr_block = "::/0" #IPv6
    gateway_id      = aws_internet_gateway.gw.id
  }

  tags = {
    Name = "bitcoin-route-table"
  }
}

# # 4. Create a Subnet 

resource "aws_subnet" "bitcoin-subnet" {
  vpc_id            = aws_vpc.bitcoin.id
  cidr_block        = "10.50.1.0/24" # Class C: 255.255.255.0 
  availability_zone = "eu-central-1a" # Availability Zone 
  tags = {
    Name = "bitcoin-subnet"
  }
}


resource "aws_subnet" "abeer-subnet" {
  vpc_id            = aws_vpc.bitcoin.id
  cidr_block        = "10.50.10.0/24"  # Class C: 255.255.255.0 
  availability_zone = "eu-central-1b" # Availability Zone 
  tags = {
    Name = "bitcoin-subnet2"
  }
}


# Design to fail 
# # 5. Associate subnet with Route Table

resource "aws_route_table_association" "a" {
  subnet_id      = aws_subnet.bitcoin-subnet.id
  route_table_id = aws_route_table.bitcoin-route-table.id
}
resource "aws_route_table_association" "b" {
  subnet_id      = aws_subnet.abeer-subnet.id
  route_table_id = aws_route_table.bitcoin-route-table.id
}


# # 6. Create Security Group to allow port 22,80,443,5000
resource "aws_security_group" "allow_web" {
  name        = "allow_web_traffic"
  description = "Allow Web inbound traffic"
  vpc_id      = aws_vpc.bitcoin.id

  ingress {
    description = "HTTPS"
    from_port   = 443  # 443
    to_port     = 443
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }
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
    cidr_blocks = ["0.0.0.0/0"]
  }
  ingress {
    description = "Flask"
    from_port   = 5000
    to_port     = 5000
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = {
    Name = "allow_web"
  }
}
# # 7. Create a network interface with an ip in the subnet that was created in step 4
resource "aws_network_interface" "web-server-nic" {
  subnet_id       = aws_subnet.bitcoin-subnet.id
  private_ips     = ["10.50.1.50"]
  security_groups = [aws_security_group.allow_web.id]
}
resource "aws_network_interface" "web-server-nic2" {
  subnet_id       = aws_subnet.abeer-subnet.id
  private_ips     = ["10.50.10.50"]
  security_groups = [aws_security_group.allow_web.id]
}
# # 8. Assign an elastic IP to the network interface created in step 7
resource "aws_eip" "one" {
  vpc                       = true
  network_interface         = aws_network_interface.web-server-nic.id
  associate_with_private_ip = "10.50.1.50"
  depends_on                = [aws_internet_gateway.gw]
}

output "server_public_ip" {
  value = aws_eip.one.public_ip
}

# # 9. Create Ubuntu server and install/enable apache2
resource "aws_instance" "web-server-instance" {
  ami               = "ami-0502e817a62226e03"    
  instance_type     = "t2.micro"
  availability_zone = "eu-central-1a"
  key_name          = "abeer"

  network_interface {
    device_index         = 0
    network_interface_id = aws_network_interface.web-server-nic.id
  }

  user_data = <<-EOF
                #!/bin/bash
                sudo apt update
                sudo apt upgrade -y
                sudo apt update              
                sudo apt install apt-transport-https -y
                sudo apt install ca-certificates -y
                sudo apt install curl -y
                sudo apt install software-properties-common -y
                curl -fsSL https://download.docker.com/linux/ubuntu/gpg | sudo apt-key add -
                sudo add-apt-repository "deb [arch=amd64] https://download.docker.com/linux/ubuntu bionic stable"
                sudo apt update
                sudo apt install docker-ce -y
                sudo docker pull abeerdi/bitcoin-app:first
                sudo docker build -t abeerdi/bitcoin-app:first .
                sudo docker run -p 5000:5000 -t abeerdi/bitcoin-app:first

                EOF
  tags = {
    Name = "web-server"
  }
}

resource "aws_lb" "loadbalancer" {
  name               = "lb"
  internal           = false
  load_balancer_type = "application"
  security_groups    = [aws_security_group.allow_web.id]
  subnets            = [aws_subnet.bitcoin-subnet.id, aws_subnet.abeer-subnet.id]

  enable_deletion_protection = true

  tags = {
    Environment = "production"
  }
}

resource "aws_lb_target_group" "lb_target_group" {
  name     = "lb-tg"
  port     = 5000
  protocol = "HTTP"
  vpc_id   = aws_vpc.bitcoin.id
}

resource "aws_lb_target_group_attachment" "lb_target_group_attachment" {
  target_group_arn = aws_lb_target_group.lb_target_group.arn
  target_id        = aws_instance.web-server-instance.id
  port             = 5000
}
