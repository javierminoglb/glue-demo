provider "aws" {
  region = "us-east-1" # Change to your preferred region
}

# ==========================================
# 1. STORAGE (S3 BUCKETS)
# ==========================================

# S3 Bucket for Raw Landing, Intermediate Staging, and Glue Scripts
resource "aws_s3_bucket" "analytics_bucket" {
  bucket        = "company-analytics-data-lake-2026"
  force_destroy = true
}

# Create folder structures inside the bucket
resource "aws_s3_object" "folder_landing" {
  bucket = aws_s3_bucket.analytics_bucket.id
  key    = "landing/clicks/"
}

resource "aws_s3_object" "folder_staging" {
  bucket = aws_s3_bucket.analytics_bucket.id
  key    = "staging/"
}

resource "aws_s3_object" "folder_scripts" {
  bucket = aws_s3_bucket.analytics_bucket.id
  key    = "scripts/"
}

# ==========================================
# 2. NETWORKING & SECURITY
# ==========================================

resource "aws_vpc" "analytics_vpc" {
  cidr_block           = "10.0.0.0/16"
  enable_dns_hostnames = true
}

resource "aws_subnet" "analytics_subnet" {
  vpc_id            = aws_vpc.analytics_vpc.id
  cidr_block        = "10.0.1.0/24"
  availability_zone = "us-east-1a"
}

resource "aws_security_group" "analytics_sg" {
  name        = "analytics-common-sg"
  vpc_id      = aws_vpc.analytics_vpc.id
  description = "Allows communication between Glue and Redshift"

  ingress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    self        = true
  }

  ingress {
    from_port   = 5439
    to_port     = 5439
    protocol    = "tcp"
    cidr_blocks = ["10.0.0.0/16"] # Redshift Port
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }
}

# S3 VPC Endpoint (Crucial for Glue to write to S3 without internet traversal)
resource "aws_vpc_endpoint" "s3_endpoint" {
  vpc_id       = aws_vpc.analytics_vpc.id
  service_name = "com.amazonaws.us-east-1.s3"
}

# ==========================================
# 3. AMAZON REDSHIFT CLUSTER
# ==========================================

resource "aws_redshift_subnet_group" "redshift_subnet_gp" {
  name       = "redshift-subnet-group"
  subnet_ids = [aws_subnet.analytics_subnet.id]
}

resource "aws_redshift_cluster" "redshift" {
  cluster_identifier  = "analytics-redshift-cluster"
  database_name       = "dev"
  master_username     = "awsuser"
  master_password     = "SecurePass123!" # In production, use AWS Secrets Manager
  node_type           = "ra3.xlplus"
  cluster_type        = "single-node"
  cluster_subnet_group_name = aws_redshift_subnet_group.redshift_subnet_gp.name
  vpc_security_group_ids    = [aws_security_group.analytics_sg.id]
  skip_final_snapshot       = true
}

# ==========================================
# 4. AWS GLUE (SPARK ETL ENGINE)
# ==========================================

# IAM Role for Glue Execution
resource "aws_iam_role" "glue_role" {
  name = "AWSGlueExecutionRole-Analytics"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Action    = "sts:AssumeRole"
      Effect    = "Allow"
      Principal = { Service = "://amazonaws.com" }
    }]
  })
}

# Attach AWS Managed Policy for Glue Service
resource "aws_iam_role_policy_attachment" "glue_service" {
  role       = aws_iam_role.glue_role.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AWSGlueServiceRole"
}

# Inline Custom Policy for S3 and Redshift access
resource "aws_iam_role_policy" "glue_s3_redshift" {
  name = "GlueS3AndRedshiftAccess"
  role = aws_iam_role.glue_role.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect   = "Allow"
        Action   = ["s3:GetObject", "s3:PutObject", "s3:DeleteObject", "s3:ListBucket"]
        Resource = ["${aws_s3_bucket.analytics_bucket.arn}", "${aws_s3_bucket.analytics_bucket.arn}/*"]
      },
      {
        Effect   = "Allow"
        Action   = ["redshift:GetClusterCredentials", "redshift-data:*"]
        Resource = ["*"]
      }
    ]
  })
}

# Glue VPC Connection (Enables Spark to talk to Redshift inside the VPC)
resource "aws_glue_connection" "redshift_conn" {
  name            = "glue-redshift-vpc-connection"
  connection_type = "JDBC"

  connection_properties = {
    JDBC_CONNECTION_URL = "jdbc:redshift://${aws_redshift_cluster.redshift.endpoint}/dev"
    USERNAME            = "awsuser"
    PASSWORD            = "SecurePass123!"
  }

  physical_connection_requirements {
    availability_zone      = "us-east-1a"
    security_group_id_list = [aws_security_group.analytics_sg.id]
    subnet_id              = aws_subnet.analytics_subnet.id
  }
}

# The AWS Glue Spark Job
resource "aws_glue_job" "clickstream_etl" {
  name              = "clickstream_avro_to_redshift"
  role_arn          = aws_iam_role.glue_role.arn
  glue_version      = "4.0" # Uses Spark 3.3.0 and Python 3
  worker_type       = "G.2X" # High memory worker type for heavy 300GB+ load
  number_of_workers = 15     # Scale workers up or down based on volume

  connections = [aws_glue_connection.redshift_conn.name]

  command {
    name            = "glueetl"
    script_location = "s3://${aws_s3_bucket.analytics_bucket.id}/scripts/clickstream_etl.py"
    python_version  = "3"
  }

  default_arguments = {
    "--job-bookmark-option"      = "job-bookmark-enable"
    "--TempDir"                  = "s3://${aws_s3_bucket.analytics_bucket.id}/staging/"
    "--enable-metrics"           = "true"
    "--enable-continuous-cloudwatch-log" = "true"
  }
}

# ==========================================
# 5. APACHE AIRFLOW (MWAA ENVIRONMENT)
# ==========================================

# IAM Role for Airflow
resource "aws_iam_role" "mwaa_role" {
  name = "AmazonMWAAExecutionRole-Analytics"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Action    = "sts:AssumeRole"
      Effect    = "Allow"
      Principal = { Service = "://amazonaws.com" }
    }]
  })
}

resource "aws_iam_role_policy" "mwaa_policy" {
  name = "MWAAExecutionPolicy"
  role = aws_iam_role.mwaa_role.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect   = "Allow"
        Action   = "airflow:PublishMetrics"
        Resource = "*"
      },
      {
        Effect   = "Allow"
        Action   = ["s3:GetObject", "s3:ListBucket"]
        Resource = ["${aws_s3_bucket.analytics_bucket.arn}", "${aws_s3_bucket.analytics_bucket.arn}/*"]
      },
      {
        Effect   = "Allow"
        Action   = ["glue:StartJobRun", "glue:GetJobRun", "glue:GetJobRuns"]
        Resource = ["${aws_glue_job.clickstream_etl.arn}"]
      }
    ]
  })
}

# Managed Workflows for Apache Airflow (MWAA) environment
resource "aws_mwaa_environment" "airflow" {
  name               = "analytics-airflow-orchestrator"
  execution_role_arn = aws_iam_role.mwaa_role.arn
  airflow_version    = "2.10.1" # Modern, highly stable Airflow environment
  environment_class  = "mw1.small"

  network_configuration {
    security_group_ids = [aws_security_group.analytics_sg.id]
    subnet_ids         = [aws_subnet.analytics_subnet.id, aws_subnet.analytics_subnet.id] # MWAA requires 2 subnets
  }

  source_bucket_arn = aws_s3_bucket.analytics_bucket.arn
  dag_s3_path       = "dags/"
}
