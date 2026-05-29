resource "aws_eks_cluster" "this" {
  name     = var.cluster_name
  role_arn = var.cluster_role_arn
  version  = var.kubernetes_version

  vpc_config {
    subnet_ids              = concat(var.private_subnet_ids, var.public_subnet_ids)
    endpoint_private_access = true
    endpoint_public_access  = var.endpoint_public_access
    security_group_ids      = [var.node_security_group_id]
  }

  # Logs do control plane (relevante para SRE/observabilidade da Fase 5)
  enabled_cluster_log_types = ["api", "audit", "authenticator"]

  tags = {
    Name      = var.cluster_name
    Component = "kubernetes-cluster"
  }
}

# OIDC provider pre-requisito para IRSA (ArgoCD, Velero, External Secrets, etc.)
# AWS Academy NAO permite criar OIDC providers (iam:CreateOpenIDConnectProvider negado).
# Em contas reais, ativar via create_oidc_provider=true.
data "tls_certificate" "cluster" {
  count = var.create_oidc_provider ? 1 : 0
  url   = aws_eks_cluster.this.identity[0].oidc[0].issuer
}

resource "aws_iam_openid_connect_provider" "eks" {
  count           = var.create_oidc_provider ? 1 : 0
  client_id_list  = ["sts.amazonaws.com"]
  thumbprint_list = [data.tls_certificate.cluster[0].certificates[0].sha1_fingerprint]
  url             = aws_eks_cluster.this.identity[0].oidc[0].issuer

  tags = {
    Name      = "${var.cluster_name}-oidc-provider"
    Component = "iam"
  }
}

resource "aws_launch_template" "nodes" {
  name_prefix = "${var.cluster_name}-nodes-"

  # 2 SGs anexados em cada node:
  #  1. node_security_group_id — trafego EXTERNO (HTTP/HTTPS, NodePort)
  #  2. cluster_security_group_id — trafego INTRA-CLUSTER (all -1 self,
  #     auto-criado pelo EKS, contem DNS UDP/53 entre nodes).
  #
  # Sem o cluster SG, pods em nodes onde CoreDNS NAO roda nao conseguem
  # resolver DNS (UDP/53 cross-node bloqueado). Esse SG eh anexado
  # automaticamente pelo EKS quando aws_eks_node_group NAO usa launch
  # template — mas como temos launch template (necessario p/ IMDSv2),
  # precisamos explicita-lo aqui. Padrao recomendado pela AWS.
  vpc_security_group_ids = [
    var.node_security_group_id,
    aws_eks_cluster.this.vpc_config[0].cluster_security_group_id,
  ]

  # Quando o node group usa launch template, o disk_size NAO pode estar
  # no aws_eks_node_group — precisa vir do bloco block_device_mappings aqui.
  block_device_mappings {
    device_name = "/dev/xvda"
    ebs {
      volume_size           = var.node_disk_size
      volume_type           = "gp3"
      delete_on_termination = true
      encrypted             = true
    }
  }

  metadata_options {
    http_tokens                 = "required" # IMDSv2 obrigatorio (security)
    http_put_response_hop_limit = 2          # 2 hops necessario para pods acessarem IMDS
  }

  tag_specifications {
    resource_type = "instance"
    tags = {
      Name      = "${var.cluster_name}-node"
      Component = "kubernetes-node"
    }
  }
}

resource "aws_eks_node_group" "this" {
  cluster_name    = aws_eks_cluster.this.name
  node_group_name = "${var.cluster_name}-ng"
  node_role_arn   = var.node_role_arn
  subnet_ids      = var.private_subnet_ids

  scaling_config {
    desired_size = var.node_desired_size
    min_size     = var.node_min_size
    max_size     = var.node_max_size
  }

  instance_types = var.node_instance_types
  ami_type       = "AL2023_x86_64_STANDARD"
  # disk_size NAO declarado aqui — conflita com launch template; ver block_device_mappings acima.

  launch_template {
    id      = aws_launch_template.nodes.id
    version = aws_launch_template.nodes.latest_version
  }

  update_config {
    max_unavailable = 1
  }

  tags = {
    Name      = "${var.cluster_name}-ng"
    Component = "kubernetes-nodegroup"
  }

  depends_on = [aws_eks_cluster.this]
}
