locals {
  default_tags = {
    Project = "tofu-ml"
    Owner   = "Nakul Khargonkar"
  }
}

# ==================================================
# ==================== VPC =========================
# ==================================================
module "vpc" {
  source = "terraform-aws-modules/vpc/aws"

  name = "my-vpc"
  cidr = "10.0.0.0/16"

  azs             = ["us-east-1a", "us-east-1b"]
  private_subnets = ["10.0.1.0/28", "10.0.2.0/28"]
  public_subnets  = ["10.0.101.0/28", "10.0.102.0/28"]
  intra_subnets   = ["10.0.201.0/28", "10.0.202.0/28"]

  enable_nat_gateway = true
  single_nat_gateway = true

  tags = {
    Terraform   = "true"
    Environment = "dev"
  }
}

# ==================================================
# ================== SECRET ========================
# ==================================================

resource "random_password" "db_password" {
  length  = 20
  special = false
}

resource "aws_secretsmanager_secret" "db_credentials" {
  name        = "dbPassword"
  description = "Database credentials for RDS instance"
  tags        = local.default_tags
}

resource "aws_secretsmanager_secret_version" "db_credentials_version" {
  secret_id     = aws_secretsmanager_secret.db_credentials.id
  secret_string = random_password.db_password.result
}

# ==================================================
# ================= IAM ROLE =======================
# ==================================================
resource "aws_iam_role" "TASKROLE" {
  name = "TASKROLE"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Action = "sts:AssumeRole"
        Effect = "Allow"
        Principal = {
          Service = "ecs-tasks.amazonaws.com"
        }
      }
    ]
  })
  tags = local.default_tags
}

resource "aws_iam_role_policy_attachment" "TASKROLE_s3_policy_attachment" {
  role       = aws_iam_role.TASKROLE.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonS3FullAccess"
}

resource "aws_iam_role_policy_attachment" "TASKROLE_ecs_policy_attachment" {
  role       = aws_iam_role.TASKROLE.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonECS_FullAccess"
}

# ==================================================
# ================= S3 BUCKET ======================
# ==================================================

data "aws_caller_identity" "current" {}

resource "aws_s3_bucket" "my_bucket" {
  bucket = "${var.project_name}-artifacts-${data.aws_caller_identity.current.account_id}"
  tags   = local.default_tags
}

resource "aws_s3_bucket_public_access_block" "my_bucket" {
  bucket                  = aws_s3_bucket.my_bucket.id
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

# ==================================================
# ============= S3 GATEWAY ENDPOINT =================
# ==================================================
resource "aws_vpc_endpoint" "s3" {
  vpc_id            = module.vpc.vpc_id
  service_name      = "com.amazonaws.${var.region}.s3"
  vpc_endpoint_type = "Gateway"
  route_table_ids = concat(
    module.vpc.private_route_table_ids,
    module.vpc.intra_route_table_ids,
    module.vpc.public_route_table_ids,
  )
  tags = local.default_tags
}

# ==================================================
# ============= ECS EXECUTION ROLE =================
# ==================================================
resource "aws_iam_role" "execution_role" {
  name = "${var.project_name}-execution-role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Action = "sts:AssumeRole"
        Effect = "Allow"
        Principal = {
          Service = "ecs-tasks.amazonaws.com"
        }
      }
    ]
  })
  tags = local.default_tags
}

resource "aws_iam_role_policy_attachment" "execution_role_managed" {
  role       = aws_iam_role.execution_role.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AmazonECSTaskExecutionRolePolicy"
}

# Allow the execution role to read the DB password secret injected into the container.
resource "aws_iam_role_policy" "execution_role_secrets" {
  name = "${var.project_name}-execution-secrets"
  role = aws_iam_role.execution_role.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect   = "Allow"
        Action   = ["secretsmanager:GetSecretValue"]
        Resource = [aws_secretsmanager_secret.db_credentials.arn]
      }
    ]
  })
}

# ==================================================
# ================ ECR REPOSITORY ==================
# ==================================================
resource "aws_ecr_repository" "mlflow" {
  name                 = "mlflow-containers"
  force_delete         = true
  image_tag_mutability = "MUTABLE"

  image_scanning_configuration {
    scan_on_push = true
  }

  tags = local.default_tags
}

# Build the MLflow container image and push it to ECR.
# Requires Docker and the AWS CLI to be available on the machine running tofu/terraform.
resource "null_resource" "docker_build_push" {
  triggers = {
    dockerfile = filemd5("${path.module}/container/Dockerfile")
  }

  provisioner "local-exec" {
    command = <<-EOT
      aws ecr get-login-password --region ${var.region} | ${var.container_cli} login --username AWS --password-stdin ${aws_ecr_repository.mlflow.repository_url}
      ${var.container_cli} build --platform linux/amd64 -t ${aws_ecr_repository.mlflow.repository_url}:latest ${path.module}/container
      ${var.container_cli} push ${aws_ecr_repository.mlflow.repository_url}:latest
    EOT
  }

  depends_on = [aws_ecr_repository.mlflow]
}

# ==================================================
# ============= DATABASE PARAMETER GROUP ===========
# ==================================================
resource "aws_db_parameter_group" "mlflow" {
  name        = "${var.project_name}-mysql"
  family      = "mysql8.4"
  description = "Parameter group for MLflow MySQL database with trigger creation enabled"

  parameter {
    name  = "log_bin_trust_function_creators"
    value = "1"
  }

  tags = local.default_tags
}

# ==================================================
# ================ DATABASE (RDS) ==================
# ==================================================
resource "aws_db_subnet_group" "mlflow" {
  name       = "${var.project_name}-db-subnet-group"
  subnet_ids = module.vpc.intra_subnets
  tags       = local.default_tags
}

resource "aws_security_group" "rds" {
  name        = "sg_rds"
  description = "Allow inbound MySQL traffic from within the VPC"
  vpc_id      = module.vpc.vpc_id

  ingress {
    description = "MySQL from VPC"
    from_port   = var.db_port
    to_port     = var.db_port
    protocol    = "tcp"
    cidr_blocks = [module.vpc.vpc_cidr_block]
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = local.default_tags
}

resource "aws_db_instance" "mysql" {
  identifier             = "${var.project_name}-mysql"
  db_name                = var.db_name
  engine                 = "mysql"
  engine_version         = "8.4.5"
  instance_class         = "db.t3.micro"
  allocated_storage      = 20
  storage_type           = "gp3"
  username               = var.db_username
  password               = random_password.db_password.result
  port                   = var.db_port
  db_subnet_group_name   = aws_db_subnet_group.mlflow.name
  vpc_security_group_ids = [aws_security_group.rds.id]
  parameter_group_name   = aws_db_parameter_group.mlflow.name
  publicly_accessible    = false
  multi_az               = false
  skip_final_snapshot    = true
  deletion_protection    = false

  tags = local.default_tags
}

# ==================================================
# ================== ECS CLUSTER ===================
# ==================================================
resource "aws_ecs_cluster" "mlflow" {
  name = "mlflow"
  tags = local.default_tags
}

resource "aws_cloudwatch_log_group" "mlflow" {
  name              = "/ecs/mlflow"
  retention_in_days = 30
  tags              = local.default_tags
}

# ==================================================
# ============= FARGATE TASK DEFINITION ============
# ==================================================
resource "aws_ecs_task_definition" "mlflow" {
  family                   = "mlflow"
  requires_compatibilities = ["FARGATE"]
  network_mode             = "awsvpc"
  cpu                      = "4096"
  memory                   = "8192"
  task_role_arn            = aws_iam_role.TASKROLE.arn
  execution_role_arn       = aws_iam_role.execution_role.arn

  container_definitions = jsonencode([
    {
      name      = "mlflow"
      image     = "${aws_ecr_repository.mlflow.repository_url}:latest"
      essential = true
      portMappings = [
        {
          containerPort = var.container_port
          hostPort      = var.container_port
          protocol      = "tcp"
        }
      ]
      environment = [
        { name = "BUCKET", value = "s3://${aws_s3_bucket.my_bucket.bucket}" },
        { name = "HOST", value = aws_db_instance.mysql.address },
        { name = "PORT", value = tostring(var.db_port) },
        { name = "DATABASE", value = var.db_name },
        { name = "USERNAME", value = var.db_username },
      ]
      secrets = [
        {
          name      = "PASSWORD"
          valueFrom = aws_secretsmanager_secret.db_credentials.arn
        }
      ]
      logConfiguration = {
        logDriver = "awslogs"
        options = {
          "awslogs-group"         = aws_cloudwatch_log_group.mlflow.name
          "awslogs-region"        = var.region
          "awslogs-stream-prefix" = "mlflow"
        }
      }
    }
  ])

  depends_on = [null_resource.docker_build_push]
  tags       = local.default_tags
}

# ==================================================
# ============ FARGATE SERVICE SECURITY ============
# ==================================================
resource "aws_security_group" "fargate" {
  name        = "sg_fargate"
  description = "MLflow Fargate service security group"
  vpc_id      = module.vpc.vpc_id

  ingress {
    description = "Allow inbound from VPC for mlflow"
    from_port   = var.container_port
    to_port     = var.container_port
    protocol    = "tcp"
    cidr_blocks = [module.vpc.vpc_cidr_block]
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = local.default_tags
}

# ==================================================
# ============= NETWORK LOAD BALANCER ==============
# ==================================================
resource "aws_lb" "mlflow" {
  name               = "mlflow-nlb"
  internal           = false
  load_balancer_type = "network"
  subnets            = module.vpc.public_subnets
  tags               = local.default_tags
}

resource "aws_lb_target_group" "mlflow" {
  name        = "mlflow-tg"
  port        = var.container_port
  protocol    = "TCP"
  vpc_id      = module.vpc.vpc_id
  target_type = "ip"

  health_check {
    protocol            = "TCP"
    port                = "traffic-port"
    healthy_threshold   = 3
    unhealthy_threshold = 3
    interval            = 30
  }

  tags = local.default_tags
}

resource "aws_lb_listener" "mlflow" {
  load_balancer_arn = aws_lb.mlflow.arn
  port              = 80
  protocol          = "TCP"

  default_action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.mlflow.arn
  }
}

# ==================================================
# ================= ECS SERVICE ====================
# ==================================================
resource "aws_ecs_service" "mlflow" {
  name            = "mlflow"
  cluster         = aws_ecs_cluster.mlflow.id
  task_definition = aws_ecs_task_definition.mlflow.arn
  desired_count   = 1
  launch_type     = "FARGATE"

  network_configuration {
    subnets          = module.vpc.private_subnets
    security_groups  = [aws_security_group.fargate.id]
    assign_public_ip = false
  }

  load_balancer {
    target_group_arn = aws_lb_target_group.mlflow.arn
    container_name   = "mlflow"
    container_port   = var.container_port
  }

  depends_on = [aws_lb_listener.mlflow]
  tags       = local.default_tags
}

# ==================================================
# ================== AUTOSCALING ===================
# ==================================================
resource "aws_appautoscaling_target" "mlflow" {
  max_capacity       = 2
  min_capacity       = 1
  resource_id        = "service/${aws_ecs_cluster.mlflow.name}/${aws_ecs_service.mlflow.name}"
  scalable_dimension = "ecs:service:DesiredCount"
  service_namespace  = "ecs"
}

resource "aws_appautoscaling_policy" "mlflow_cpu" {
  name               = "mlflow-cpu-autoscaling"
  policy_type        = "TargetTrackingScaling"
  resource_id        = aws_appautoscaling_target.mlflow.resource_id
  scalable_dimension = aws_appautoscaling_target.mlflow.scalable_dimension
  service_namespace  = aws_appautoscaling_target.mlflow.service_namespace

  target_tracking_scaling_policy_configuration {
    predefined_metric_specification {
      predefined_metric_type = "ECSServiceAverageCPUUtilization"
    }
    target_value       = 70
    scale_in_cooldown  = 60
    scale_out_cooldown = 60
  }
}
