output "alb_arn"         { value = aws_lb.public.arn }
output "alb_dns"         { value = aws_lb.public.dns_name }
output "target_group_arn"{ value = aws_lb_target_group.frontend.arn }
output "alb_arn_suffix" { value = aws_lb.public.arn_suffix }
