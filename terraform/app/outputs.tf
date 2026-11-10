output "instance_id" {
  value = aws_instance.app.id
}

output "public_ip" {
  value = aws_instance.app.public_ip
}

output "app_url" {
  value = "http://${aws_instance.app.public_dns}${var.host_port == 80 ? "" : ":${var.host_port}"}"
}

output "log_group" {
  value = aws_cloudwatch_log_group.app.name
}
