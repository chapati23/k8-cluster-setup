# For this to work the following environment variables need to be set
# - AWS_REGION
# - VPC_ID
# - CLUSTER_NAME
# - DB_POSTGRES_VERSION
# - DB_NAME
# - DB_USER
# - DB_PASSWORD

# Also, you need to be logged in to AWS in your shell
# - `aws configure`

variable "aws_credentials_path" {}
variable "aws_region" {}
variable "cluster_name" {}
variable "db_identifier" {}
variable "db_instance_class" {}
variable "db_name" {}
variable "db_password" {}
variable "db_postgres_version" {}
variable "db_user" {}
variable "multi_az" {}
variable "skip_final_snapshot" {}
variable "vpc_id" {}

provider "aws" {
  region = "${var.aws_region}"
  shared_credentials_file = "${var.aws_credentials_path}"
}

variable "subnet_1_cidr" {
  type = "string"
  default = "10.0.11.0/24" # should not overlap with subnets of kubernetes cluster
}

variable "subnet_2_cidr" {
  type = "string"
  default = "10.0.12.0/24" # should not overlap with subnets of kubernetes cluster
}

resource "aws_security_group" "default" {
  name        = "allow_vpc_internal"
  description = "Allow all egress traffic. Restrict ingress to VPC internal"
  vpc_id      = "${var.vpc_id}"

  ingress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["10.0.0.0/8"]
  }

  egress {
    from_port       = 0
    to_port         = 0
    protocol        = "-1"
    cidr_blocks     = ["0.0.0.0/0"]
  }
}

resource "aws_db_subnet_group" "default" {
  name        = "db_subnet_group_${var.cluster_name}"
  description = "Our main group of subnets for the ${var.cluster_name} cluster"
  subnet_ids  = ["${aws_subnet.subnet_1.id}", "${aws_subnet.subnet_2.id}"]
}

resource "aws_subnet" "subnet_1" {
  vpc_id            = "${var.vpc_id}"
  cidr_block        = "${var.subnet_1_cidr}"
  availability_zone = "${var.aws_region}a"

  tags {
    Name = "db_subnet_1_${var.cluster_name}"
  }
}

resource "aws_subnet" "subnet_2" {
  vpc_id            = "${var.vpc_id}"
  cidr_block        = "${var.subnet_2_cidr}"
  availability_zone = "${var.aws_region}b"

  tags {
    Name = "db_subnet_2_${var.cluster_name}"
  }
}

resource "aws_db_instance" "default" {
  depends_on                 = ["aws_db_subnet_group.default"]
  allocated_storage          = "10" # Storage size in GB
  auto_minor_version_upgrade = true
  db_subnet_group_name       = "${aws_db_subnet_group.default.name}"
  engine                     = "postgres"
  engine_version             = "${var.db_postgres_version}"
  identifier                 = "${var.db_identifier}"
  instance_class             = "${var.db_instance_class}"
  multi_az                   = "${var.multi_az}"
  name                       = "${var.db_name}"
  password                   = "${var.db_password}"
  skip_final_snapshot        = "${var.skip_final_snapshot}"
  storage_encrypted          = true
  username                   = "${var.db_user}"
  vpc_security_group_ids     = ["${aws_security_group.default.id}"]
}

output "db_instance_id" {
  value = "${aws_db_instance.default.id}"
}

output "db_url" {
  value = "${aws_db_instance.default.address}"
}
