variable "project"        {}
variable "environment"    {}
variable "vpc_id"         {}
variable "db_subnet_ids"  { type = list(string) }
variable "sg_rds_id"      {}
variable "db_name"        {}
variable "db_username"    {}
variable "db_password"    { sensitive = true }
variable "instance_class"          { default = "db.t4g.micro" }
variable "engine_version"          { default = "8.4.8" }
variable "backup_retention_period" { default = 7 }
