locals {
  master_password         = var.password == "" ? random_password.master_password.result : var.password
  performance_kms_key     = join("", aws_kms_key.aurora_performance_insights_key.*.keys_id)
  performance_kms_key_arn = join("", aws_kms_key.aurora_performance_insights_key.*.arn)
  database_id             = var.db_id == "" ? random_string.db_cluster_identifier.result : var.db_id
}

# Random string to use as master password unless one is specified
resource "random_password" "master_password" {
  length  = 16
  special = false
}

data "aws_iam_role" "enhanced_monitoring" {
  name = "rds-enhanced-monitoring-mattermost-cloud-${var.environment}-provisioning"
}

resource "aws_kms_key" "aurora_storage_key" {
  description             = format("rds-multitenant-storage-key-%s-%s", split("-", var.vpc_id)[1], local.database_id)
  deletion_window_in_days = 7
}

resource "aws_kms_key" "aurora_performance_insights_key" {
  count = var.performance_insights_enabled == true ? 1 : 0

  description             = format("rds-multitenant-performance-insights-key-%s-%s", split("-", var.vpc_id)[1], local.database_id)
  deletion_window_in_days = 7
}

resource "aws_kms_alias" "aurora_storage_alias" {
  name          = "alias/${format("rds-multitenant-storage-key-%s-%s", split("-", var.vpc_id)[1], local.database_id)}"
  target_key_id = aws_kms_key.aurora_storage_key.key_id
}

resource "aws_kms_alias" "aurora_performance_insights_alias" {
  count = var.performance_insights_enabled == true ? 1 : 0

  name          = "alias/${format("rds-multitenant-performance-insights-key-%s-%s", split("-", var.vpc_id)[1], local.database_id)}"
  target_key_id = local.performance_kms_key
}

data "aws_security_group" "db_sg" {
  name = format("mattermost-cloud-%s-provisioning-%s-db-sg", var.environment, join("", split(".", split("/", data.aws_vpc.provisioning_vpc.cidr_block)[0])))
}

data "aws_vpc" "provisioning_vpc" {
  id = var.vpc_id
}

resource "aws_rds_cluster" "provisioning_rds_cluster" {
  cluster_identifier              = format("rds-cluster-multitenant-%s-%s", split("-", var.vpc_id)[1], local.database_id)
  engine                          = var.engine
  engine_version                  = var.engine_version
  kms_key_id                      = aws_kms_key.aurora_storage_key.arn
  master_username                 = var.username
  master_password                 = local.master_password
  final_snapshot_identifier       = "${var.final_snapshot_identifier_prefix}-${format("rds-cluster-multitenant-%s-%s", split("-", var.vpc_id)[1], local.database_id)}"
  skip_final_snapshot             = var.skip_final_snapshot
  deletion_protection             = var.deletion_protection
  backup_retention_period         = var.backup_retention_period
  preferred_backup_window         = var.preferred_backup_window
  preferred_maintenance_window    = var.preferred_maintenance_window
  port                            = var.port
  db_subnet_group_name            = "mattermost-provisioner-db-${var.vpc_id}"
  vpc_security_group_ids          = [data.aws_security_group.db_sg.id]
  storage_encrypted               = var.storage_encrypted
  apply_immediately               = var.apply_immediately
  db_cluster_parameter_group_name = "mattermost-provisioner-rds-cluster-pg"
  copy_tags_to_snapshot           = var.copy_tags_to_snapshot
  enabled_cloudwatch_logs_exports = var.enabled_cloudwatch_logs_exports

  tags = merge(
    {
      "Counter"               = 0,
      "MultitenantDatabaseID" = format("rds-cluster-multitenant-%s-%s", split("-", var.vpc_id)[1], local.database_id),
      "VpcID"                 = var.vpc_id,
      "DatabaseType"          = "multitenant-rds",
      "MattermostCloudInstallationDatabase" = "MySQL/Aurora"
    },
    var.tags
  )
  lifecycle {
    ignore_changes = [
      tags["Counter"]
    ]
  }
}

resource "aws_rds_cluster_instance" "provisioning_rds_db_instance" {
  count                           = var.replica_min
  identifier                      = format("rds-db-instance-multitenant-%s-%s-%s", split("-", var.vpc_id)[1], local.database_id, (count.index + 1))
  cluster_identifier              = aws_rds_cluster.provisioning_rds_cluster.id
  engine                          = var.engine
  engine_version                  = var.engine_version
  instance_class                  = var.instance_type
  db_subnet_group_name            = "mattermost-provisioner-db-${var.vpc_id}"
  db_parameter_group_name         = "mattermost-provisioner-rds-pg"
  preferred_maintenance_window    = var.preferred_maintenance_window
  apply_immediately               = var.apply_immediately
  monitoring_role_arn             = data.aws_iam_role.enhanced_monitoring.arn
  monitoring_interval             = var.monitoring_interval
  promotion_tier                  = count.index + 1
  performance_insights_enabled    = var.performance_insights_enabled
  performance_insights_kms_key_id = local.performance_kms_key_arn

  tags = var.tags

  lifecycle {
    ignore_changes = [
      instance_class,
    ]
  }
}

resource "random_string" "db_cluster_identifier" {
  length = 8
}

resource "aws_appautoscaling_target" "read_replica_count" {
  max_capacity       = var.replica_scale_max
  min_capacity       = var.replica_scale_min
  resource_id        = "cluster:${aws_rds_cluster.provisioning_rds_cluster.cluster_identifier}"
  scalable_dimension = "rds:cluster:ReadReplicaCount"
  service_namespace  = "rds"
}

resource "aws_appautoscaling_policy" "autoscaling_read_replica_count" {
  name               = format("rds-target-metric-%s-%s", split("-", var.vpc_id)[1], local.database_id)
  policy_type        = "TargetTrackingScaling"
  resource_id        = "cluster:${aws_rds_cluster.provisioning_rds_cluster.cluster_identifier}"
  scalable_dimension = "rds:cluster:ReadReplicaCount"
  service_namespace  = "rds"

  target_tracking_scaling_policy_configuration {
    predefined_metric_specification {
      predefined_metric_type = var.predefined_metric_type
    }

    scale_in_cooldown  = var.replica_scale_in_cooldown
    scale_out_cooldown = var.replica_scale_out_cooldown
    target_value       = var.predefined_metric_type == "RDSReaderAverageCPUUtilization" ? var.replica_scale_cpu : var.replica_scale_connections
  }

  depends_on = [aws_appautoscaling_target.read_replica_count]
}

resource "aws_secretsmanager_secret" "master_password" {
  name = format("rds-cluster-multitenant-%s-%s", split("-", var.vpc_id)[1], local.database_id)
}

resource "aws_secretsmanager_secret_version" "master_password" {
  secret_id     = aws_secretsmanager_secret.master_password.id
  secret_string = local.master_password
}

data "aws_sns_topic" "horizontal_scaling_sns_topic" {
  name = "cloud-db-factory-vertical-scaling-${var.environment}"
}

resource "aws_cloudwatch_metric_alarm" "db_instances_alarm_cpu" {
  count                     = var.replica_min
  alarm_name                = format("rds-db-instance-multitenant-%s-%s-%s-cpu", split("-", var.vpc_id)[1], local.database_id, (count.index + 1))
  comparison_operator       = "GreaterThanOrEqualToThreshold"
  evaluation_periods        = "3"
  metric_name               = "CPUUtilization"
  namespace                 = "AWS/RDS"
  period                    = "600"
  statistic                 = "Average"
  threshold                 = "70"
  alarm_description         = "This metric monitors RDS DB Instance cpu utilization"
  actions_enabled           = true  
  alarm_actions             = [data.aws_sns_topic.horizontal_scaling_sns_topic.arn]
  dimensions                = {DBInstanceIdentifier = aws_rds_cluster_instance.provisioning_rds_db_instance[count.index].identifier}
}

resource "aws_cloudwatch_metric_alarm" "db_instances_alarm_memory" {
  count                     = var.replica_min
  alarm_name                = format("rds-db-instance-multitenant-%s-%s-%s-memory", split("-", var.vpc_id)[1], local.database_id, (count.index + 1))
  comparison_operator       = "LessThanOrEqualToThreshold"
  evaluation_periods        = "3"
  metric_name               = "FreeableMemory"
  namespace                 = "AWS/RDS"
  period                    = "600"
  statistic                 = "Average"
  threshold                 = "100000000"
  alarm_description         = "This metric monitors RDS DB Instance freeable memory"
  actions_enabled           = true  
  alarm_actions             = [data.aws_sns_topic.horizontal_scaling_sns_topic.arn]
  dimensions                = {DBInstanceIdentifier = aws_rds_cluster_instance.provisioning_rds_db_instance[count.index].identifier}
}


