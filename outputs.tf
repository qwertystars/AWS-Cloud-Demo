output "cluster_name" {
  value = aws_ecs_cluster.demo.name
}
output "service_name" {
  value = aws_ecs_service.demo.name
}
output "load_balancer_dns" {
  value = aws_lb.demo.dns_name
}
output "demo_url" {
  description = "Open this URL or use ./demo.sh to observe the backend identities."
  value       = "http://${aws_lb.demo.dns_name}"
}
output "target_group_arn" {
  value = aws_lb_target_group.demo.arn
}
output "region" {
  value = var.region
}
output "account_id" {
  value = data.aws_caller_identity.current.account_id
}
