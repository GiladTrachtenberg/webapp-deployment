terraform {
#assumes s3 bucket and dynamodb table already set up
#to store tf state file (according to the relevant best practice)
    backend "s3" {
    bucket = "devops-directive-tf-state"
    key = "03-basics/web-app/terraform.tfstate"
    region = "us-east-1"
    dynamodb_table = "terraform-state-locking"
    encrypt = true
  }

#configuring the official aws provider
    required_providers {
        aws = {
            source = "hashicorp/aws"
            version = "~> 4.0"
      }
    }

#configuring right region (virginia) 
    provider "aws" {
        region = "us-east-1"
  }
    
 #configuring the aws instance which will serve the blue html index file
 #the script will instal and run nginx
    resource "aws_instance" "instance_blue" {
        ami = "ami-011899242bb902164" #Ubuntu 20.04 LTS us-east-1
        instance_type = "t2.micro"
        security_groups = [aws_security_group.instances.name]
        user_data = <<-EOF
            #!/bin/bash
            sudo apt update
            sudo apt install nginx
            aws s3 cp s3://${aws_s3_bucket.bucket.id}/blue/index.html /etc/nginx/html/index.html
            sudo systemctl start nginx
            EOF
    }

#configuring the aws instance which will serve the red html index file
#the script will instal and run nginx
    resource "aws_instance" "instance_red" {
        ami = "ami-011899242bb902164" #Ubuntu 20.04 LTS us-east-1
        instance_type = "t2.micro"
        security_groups = [aws_security_group.instances.name]
        user_data = <<-EOF
            #!/bin/bash
            sudo apt update
            sudo apt install nginx
            aws s3 cp s3://${aws_s3_bucket.bucket.id}/blue/index.html /etc/nginx/html/index.html
            sudo systemctl start nginx
            EOF
    }

#the bucket which the instances will access in order to pull the html index files
    resource "aws_s3_bucket" "bucket" {
        bucket = "devops-directive-web-app-data"
        versioning {
            enabled = true
        }
    }

#the bucket acl - setting it to private
resource "aws_s3_bucket_acl" "example" {
  bucket = aws_s3_bucket.b.id
  acl    = "private"
}

#creating the red-html object
    resource "aws_s3_bucket_object" "red-html" {
        bucket = "your_bucket_name"
        key    = "new_object_key"
        source = "./red/index.html"

  etag = filemd5("./red/index.html")
}

#creating the blue-html object

    resource "aws_s3_bucket_object" "blue-html" {
        bucket = "devops-directive-web-app-data"
        key    = "new_object_key"
        source = "./blue/index.html"

  etag = filemd5("./blue/index.html")
}

#configuring encryption for the s3 bucket

    server_side_encryption_configuration {
        rule {
            apply_server_side_encryption_by_default {
                sse_algorithm = "AE256"
            }
        }
    }
}

#configuring to use the default vpc in us-east-1 region

data "aws_vpc" "default_vpc" {
    default = true
}

#configuring to use the default subnet in the default vpc

data "aws_subnet_ids" "default_subnet" {
    vpc_id = data.aws_vpc.default_vpc.id
}

#configuring the security group for the instances

resource "aws_security_group" "instances" {
    name = "instance-security-group"
}

#configuring the aforementioned security group's rule to allow traffic to and from port 80 on all IP addresses

resource "aws_security_group_rule" "allow" {
    type = "ingress"
    security_group_id = aws_security_group.instances.id

    from_port = 80
    to_port = 80
    protocol = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
}


#creating the first target group for the alb - red
resource "aws_lb_target_group" "instance-red" {
  name     = "tg-red"
  target_type = "instance"
  target_group_arn = aws_lb_target_group.instance-red.arn
  target_id        = aws_instance.instance_red.id
  port     = 80
  protocol = "HTTP"
  vpc_id   = data.aws_vpc.default_vpc.id

  health_check {
    path = "/blue"
    protocol = "HTTP"
    matcher = "200"
    interval = 15
    timeout = 3
    healthy_threshold = 2
    unhealthy_threshold = 2
  }
}

#creating the second target group for the alb - blue 
resource "aws_lb_target_group" "instance-blue" {
  name     = "tg-blue"
  target_group_arn = aws_lb_target_group.instance-blue.arn
  target_id        = aws_instance.instance_blue.id
  target_type = "instance"
  port     = 80
  protocol = "HTTP"
  vpc_id   = data.aws_vpc.default_vpc.id

  health_check {
    path = "/blue"
    protocol = "HTTP"
    matcher = "200"
    interval = 15
    timeout = 3
    healthy_threshold = 2
    unhealthy_threshold = 2
  }
}

#listener rules configuration

resource "aws_lb_listener" "http" {
    load_balancer_arn = aws_lb.load_balancer.arn
    port = 80
    protocol = "HTTP"

#return a 404 page in case of an error
    default_action {
      type = "fixed-response"

      fixed_response {
        content_type = "text/plain"
        message_body = "404: page not found"
        status_code = 404
      }
    }
}

#create IAM role that will ahve access to our ec2, in order to pull files from the s3 bucket
resource "aws_iam_role" "SSMRoleForEC2" {
    name = "SSMRoleForEC2" 
    assume_role_policy = <<EOF
    {
        “Version”: “2012–10–17”,
        “Statement”: [  
            {
                “Effect”: “Allow”,
                “Principal”: {
                “Service”: “ec2.amazonaws.com”
            },
            "Action": “sts:AssumeRole”
    }
    ]
    EOF
}

resource "aws_iam_instance_profile" "SSMRoleForEC2" {
  name = "SSMRoleForEC2"
  role = aws_iam_role.SSMRoleForEC2.name
}

#attaching the managed policies to the iam role we've created

resource "aws_iam_role_policy_attachment" "role-policy-attachment" {
    for_each = toset ([
        "arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore",
        "arn:aws:iam::aws:policy/AmazonS3ReadOnlyAccess"
    ])
    role = aws_iam_role.SSMRoleForEC2.name
    policy_arn = each.value
}
