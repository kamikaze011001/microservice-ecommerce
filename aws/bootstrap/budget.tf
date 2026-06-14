# aws/bootstrap/budget.tf
#
# Goal: an AWS Budgets monthly COST budget that emails you when ACTUAL spend
# crosses a threshold of var.budget_limit_usd.
#
# Use resource: aws_budgets_budget
#   - budget_type  = "COST"
#   - time_unit    = "MONTHLY"
#   - limit_amount = var.budget_limit_usd   (note: this attribute is a STRING)
#   - limit_unit   = "USD"
#   - Add a notification block: comparison_operator GREATER_THAN, threshold 80
#     (percent), threshold_type PERCENTAGE, notification_type ACTUAL, and
#     subscriber_email_addresses = [var.budget_email].
#   - Optional bonus: a second notification at threshold 100 with
#     notification_type FORECASTED (warns before you even spend it).
#
# Docs:
#   https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/budgets_budget
#
# Write your resource below; ask Claude to review before applying.

resource "aws_budgets_budget" "cost" {
  budget_type  = "COST"
  time_unit    = "MONTHLY"
  limit_amount = tostring(var.budget_limit_usd)
  limit_unit   = "USD"

  notification {
    comparison_operator        = "GREATER_THAN"
    threshold                  = 80
    threshold_type             = "PERCENTAGE"
    notification_type          = "ACTUAL"
    subscriber_email_addresses = [var.budget_email]
  }

  notification {
    comparison_operator        = "GREATER_THAN"
    threshold                  = 100
    threshold_type             = "PERCENTAGE"
    notification_type          = "FORECASTED"
    subscriber_email_addresses = [var.budget_email]
  }
}
