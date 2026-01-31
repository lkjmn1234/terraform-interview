resource "aws_ecr_repository" "app_repo" {
  name = "my-app-repo"
  image_scanning_configuration {
    scan_on_push = true
  }
}

resource "aws_secretsmanager_secret" "app_secret" {
  name = "my-app/db-credentials"
}

resource "aws_secretsmanager_secret_version" "app_secret_val" {
  secret_id     = aws_secretsmanager_secret.app_secret.id
  secret_string = jsonencode({
    FROM_MICROSERVICE = "from microservice"
    FROM_MAIN = "from main"
    MICROSERVICE_URL = "http://microservice:3001"
  })
}