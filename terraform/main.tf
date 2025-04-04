provider "aws" {
  region = "us-east-1"  # Change to your preferred region
}

#########################
# Security Groups
#########################

resource "aws_security_group" "flask_app_sg" {
  name        = "flask-app-sg"
  description = "Allow inbound traffic for Flask app on port 5000 and SSH on port 22"

  ingress {
    from_port   = 5000
    to_port     = 5000
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  ingress {
    from_port   = 22
    to_port     = 22
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }
}

resource "aws_security_group" "efs_sg" {
  name        = "efs-sg"
  description = "Allow NFS traffic for EFS"

  ingress {
    from_port       = 2049
    to_port         = 2049
    protocol        = "tcp"
    security_groups = [aws_security_group.flask_app_sg.id]
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }
}

#########################
# EFS File System
#########################

resource "aws_efs_file_system" "efs" {
  creation_token   = "flask-app-efs"
  performance_mode = "generalPurpose"
}

data "aws_vpc" "default" {
  default = true
}

data "aws_subnets" "default" {
  filter {
    name   = "vpc-id"
    values = [data.aws_vpc.default.id]
  }
}

resource "aws_efs_mount_target" "efs_mt" {
  file_system_id  = aws_efs_file_system.efs.id
  subnet_id       = data.aws_subnets.default.ids[0]
  security_groups = [aws_security_group.efs_sg.id]
}

#########################
# EC2 Instance for Flask App
#########################

resource "aws_instance" "flask_app_instance" {
  ami                    = "ami-0c2b8ca1dad447f8a"  # Amazon Linux 2 AMI
  instance_type          = "t2.micro"
  key_name               = "terraform"             # Your EC2 key pair name
  vpc_security_group_ids = [aws_security_group.flask_app_sg.id]

  tags = {
    Name = "FlaskAppInstance"
  }
}

resource "aws_eip" "flask_app_eip" {
  instance = aws_instance.flask_app_instance.id
}

#########################
# Initial Setup with remote-exec (replaces user_data)
#########################

resource "null_resource" "initial_setup" {
  depends_on = [aws_instance.flask_app_instance, aws_efs_mount_target.efs_mt]

  connection {
    type        = "ssh"
    user        = "ec2-user"
    host        = aws_instance.flask_app_instance.public_ip
    private_key = file("../secrets/terraform.pem")
  }

  # Initial setup that would have been in user_data
  provisioner "remote-exec" {
    inline = [
      "echo 'Starting initial setup...'",
      "sudo yum update -y",
      "sudo yum install -y python3 python3-pip python3-devel gcc nfs-utils",
      "sudo pip3 install --upgrade pip",
      "sudo pip3 install flask geopandas",
      
      # Mount EFS
      "sudo mkdir -p /mnt/efs",
      "echo '${aws_efs_file_system.efs.dns_name}:/ /mnt/efs nfs4 defaults,_netdev 0 0' | sudo tee -a /etc/fstab",
      "sudo mount -a",
      
      # Create directory for shapefiles on EFS
      "sudo mkdir -p /mnt/efs/data",
      "sudo chmod 777 /mnt/efs/data",
      
      # Create application directories
      "mkdir -p /home/ec2-user/flaskapp",
      "mkdir -p /home/ec2-user/flaskapp/templates",
      
      # Create a directory for temporary file uploads
      "mkdir -p /home/ec2-user/temp_data",
      
      # Create symbolic link so the app's "data" path points to EFS
      "ln -s /mnt/efs/data /home/ec2-user/flaskapp/data",
      
      "echo 'Initial setup complete!'"
    ]
  }
}

#########################
# Deploy Files with Null Resource (detects local changes)
#########################

resource "null_resource" "deploy_files" {
  depends_on = [null_resource.initial_setup]

  triggers = {
    app_py_hash     = filesha256("../app.py")
    index_html_hash = filesha256("../templates/index.html")
  }

  connection {
    type        = "ssh"
    user        = "ec2-user"
    host        = aws_instance.flask_app_instance.public_ip
    private_key = file("../secrets/terraform.pem")
  }

  provisioner "file" {
    source      = "../app.py"
    destination = "/home/ec2-user/flaskapp/app.py"
  }

  provisioner "file" {
    source      = "../templates/index.html"
    destination = "/home/ec2-user/flaskapp/templates/index.html"
  }

  provisioner "file" {
    source      = "../data"
    destination = "/home/ec2-user"
  }

  provisioner "remote-exec" {
    inline = [
      "echo 'Deploying application files...'",
      "cp -r /home/ec2-user/data/* /mnt/efs/data/",
      "rm -rf /home/ec2-user/data",
      "cd /home/ec2-user/flaskapp",
      "killall python3 || true",  # Kill any existing Python processes
      "nohup python3 app.py > app.log 2>&1 &",
      "sleep 5",  # Give it a moment to start
      "ps aux | grep python",  # Check if it's running
      "cat app.log",  # Output any startup errors
      "echo 'Application deployment complete!'"
    ]
  }
}

#########################
# Output Public URL
#########################

output "flask_app_url" {
  value       = "http://${aws_eip.flask_app_eip.public_ip}:5000"
  description = "The public URL to access the Flask app"
}