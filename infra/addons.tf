resource "helm_release" "metrics_server" {
  name       = "metrics-server"
  repository = "https://kubernetes-sigs.github.io/metrics-server/"
  chart      = "metrics-server"
  version    = "3.14.0"
  namespace  = "kube-system"
}

resource "helm_release" "ingress_nginx" {
  name             = "ingress-nginx"
  repository       = "https://kubernetes.github.io/ingress-nginx"
  chart            = "ingress-nginx"
  version          = "4.15.1"
  namespace        = "ingress-nginx"
  create_namespace = true
}

resource "aws_iam_policy" "keda" {
  name = "togglemaster-keda-sqs"
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect   = "Allow"
      Action   = ["sqs:GetQueueAttributes"]
      Resource = aws_sqs_queue.analytics.arn
    }]
  })
}

data "aws_iam_policy_document" "keda_assume" {
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
      values   = ["system:serviceaccount:keda:keda-operator"]
    }

    condition {
      test     = "StringEquals"
      variable = "${module.eks.oidc_provider}:aud"
      values   = ["sts.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "keda" {
  name               = "togglemaster-keda"
  assume_role_policy = data.aws_iam_policy_document.keda_assume.json
}

resource "aws_iam_role_policy_attachment" "keda" {
  role       = aws_iam_role.keda.name
  policy_arn = aws_iam_policy.keda.arn
}

resource "helm_release" "keda" {
  name             = "keda"
  repository       = "https://kedacore.github.io/charts"
  chart            = "keda"
  version          = "2.20.2"
  namespace        = "keda"
  create_namespace = true

  set {
    name  = "serviceAccount.operator.annotations.eks\\.amazonaws\\.com/role-arn"
    value = aws_iam_role.keda.arn
  }
}
