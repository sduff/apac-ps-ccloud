resource "confluent_kafka_cluster" "gwilliams" {
  display_name = "gwilliams-pgsql-test"
  availability = "SINGLE_ZONE"
  cloud        = "AWS"
  region       = "ap-southeast-2"
  basic {}

  environment {
    id = confluent_environment.shared-env.id
  }

  lifecycle {
    prevent_destroy = true
  }
}