# Provider mocks: these plans neither read AWS nor create resources.
mock_provider "aws" {
  mock_data "aws_caller_identity" {
    defaults = { account_id = "123456789012" }
  }
  mock_data "aws_partition" {
    defaults = { partition = "aws" }
  }
  mock_data "aws_vpcs" {
    defaults = { ids = ["vpc-12345678"] }
  }
  mock_data "aws_subnets" {
    defaults = { ids = ["subnet-a", "subnet-b", "subnet-c"] }
  }
  mock_data "aws_route_tables" {
    defaults = { ids = ["rtb-demo"] }
  }
  mock_data "aws_availability_zones" {
    defaults = { names = ["ap-south-1a", "ap-south-1b"] }
  }
  mock_data "aws_route_table" {
    defaults = {
      associations = [{ main = true, subnet_id = "" }]
      routes       = [{ cidr_block = "0.0.0.0/0", gateway_id = "igw-demo" }]
    }
  }
  mock_data "aws_subnet" {
    defaults = {
      availability_zone          = "ap-south-1a"
      available_ip_address_count = 100
      cidr_block                 = "172.31.0.0/20"
    }
  }
}

run "select_distinct_azs" {
  command = plan
  override_data {
    target = data.aws_subnet.candidate["subnet-c"]
    values = {
      availability_zone          = "ap-south-1b"
      available_ip_address_count = 100
      cidr_block                 = "172.31.16.0/20"
    }
  }
  assert {
    condition     = toset(aws_lb.demo.subnets) == toset(["subnet-a", "subnet-c"])
    error_message = "Must skip subnet-b in the same AZ and select subnet-c."
  }
  assert {
    condition     = aws_ecs_service.demo.desired_count == 2 && aws_ecs_service.demo.network_configuration[0].assign_public_ip
    error_message = "The default service needs two tasks and public IPs for image pulling."
  }
}

run "reject_single_az" {
  command         = plan
  expect_failures = [aws_lb.demo]
}
