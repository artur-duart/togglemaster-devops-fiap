resource "aws_iam_policy" "evaluation" {
  name = "togglemaster-evaluation-sqs"
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect   = "Allow"
      Action   = ["sqs:SendMessage"]
      Resource = aws_sqs_queue.analytics.arn
    }]
  })
}

resource "aws_iam_policy" "analytics" {
  name = "togglemaster-analytics"
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect   = "Allow"
        Action   = ["sqs:ReceiveMessage", "sqs:DeleteMessage"]
        Resource = aws_sqs_queue.analytics.arn
      },
      {
        Effect   = "Allow"
        Action   = ["dynamodb:PutItem"]
        Resource = aws_dynamodb_table.analytics.arn
      }
    ]
  })
}

resource "kubernetes_namespace" "togglemaster" {
  metadata {
    name = "togglemaster"
  }
}

# ---------- evaluation ----------
data "aws_iam_policy_document" "evaluation_assume" {
  statement {
    effect  = "Allow"
    actions = ["sts:AssumeRoleWithWebIdentity"]

    principals {
      type        = "Federated"
      identifiers = [module.eks.oidc_provider_arn]
    }

    condition {
      test     = "StringEquals"
      variable = "${module.eks.oidc_provider}:sub"
      values   = ["system:serviceaccount:togglemaster:evaluation-sa"]
    }

    condition {
      test     = "StringEquals"
      variable = "${module.eks.oidc_provider}:aud"
      values   = ["sts.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "evaluation" {
  name               = "togglemaster-evaluation"
  assume_role_policy = data.aws_iam_policy_document.evaluation_assume.json
}

resource "aws_iam_role_policy_attachment" "evaluation" {
  role       = aws_iam_role.evaluation.name
  policy_arn = aws_iam_policy.evaluation.arn
}

resource "kubernetes_service_account" "evaluation" {
  metadata {
    name      = "evaluation-sa"
    namespace = kubernetes_namespace.togglemaster.metadata[0].name
    annotations = {
      "eks.amazonaws.com/role-arn" = aws_iam_role.evaluation.arn
    }
  }
}

# ---------- analytics ----------
data "aws_iam_policy_document" "analytics_assume" {
  statement {
    effect  = "Allow"
    actions = ["sts:AssumeRoleWithWebIdentity"]

    principals {
      type        = "Federated"
      identifiers = [module.eks.oidc_provider_arn]
    }

    condition {
      test     = "StringEquals"
      variable = "${module.eks.oidc_provider}:sub"
      values   = ["system:serviceaccount:togglemaster:analytics-sa"] # 🆕
    }

    condition {
      test     = "StringEquals"
      variable = "${module.eks.oidc_provider}:aud"
      values   = ["sts.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "analytics" {
  name               = "togglemaster-analytics"
  assume_role_policy = data.aws_iam_policy_document.analytics_assume.json
}

resource "aws_iam_role_policy_attachment" "analytics" {
  role       = aws_iam_role.analytics.name
  policy_arn = aws_iam_policy.analytics.arn
}

resource "kubernetes_service_account" "analytics" {
  metadata {
    name      = "analytics-sa"
    namespace = kubernetes_namespace.togglemaster.metadata[0].name
    annotations = {
      "eks.amazonaws.com/role-arn" = aws_iam_role.analytics.arn
    }
  }
}
