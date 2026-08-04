resource "aws_dynamodb_table" "analytics" {
  name         = "ToggleMasterAnalytics"
  billing_mode = "PAY_PER_REQUEST"
  hash_key     = "event_id"

  attribute {
    name = "event_id"
    type = "S"
  }

  point_in_time_recovery {
    enabled = true
  }
}

resource "aws_sqs_queue" "analytics_dlq" {
  name                    = "togglemaster-analytics-events-dlq"
  sqs_managed_sse_enabled = true
}

resource "aws_sqs_queue" "analytics" {
  name                    = "togglemaster-analytics-events"
  sqs_managed_sse_enabled = true

  redrive_policy = jsonencode({
    deadLetterTargetArn = aws_sqs_queue.analytics_dlq.arn
    maxReceiveCount     = 5
  })
}
