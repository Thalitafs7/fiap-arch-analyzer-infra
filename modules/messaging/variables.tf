variable "project_name" {
  description = "Project name prefix for resource naming (e.g. arch-analyzer). Queues are named <project_name>-processing-<env> and <project_name>-processing-dlq-<env>."
  type        = string
}

variable "environment" {
  description = "Environment name (e.g. dev, prod). Appended to all resource names."
  type        = string
}

variable "visibility_timeout_seconds" {
  description = "Visibility timeout for the Processing_Queue in seconds. Must be >= the maximum expected LLM processing time. Req 5.2 mandates 600."
  type        = number
  default     = 600
}

variable "max_receive_count" {
  description = "Number of times a message can be received before being moved to the DLQ. Req 5.3 mandates 3."
  type        = number
  default     = 3
}

variable "message_retention_seconds" {
  description = "How long SQS retains unprocessed messages on the Processing_Queue (seconds). Default 4 days."
  type        = number
  default     = 345600 # 4 days
}
