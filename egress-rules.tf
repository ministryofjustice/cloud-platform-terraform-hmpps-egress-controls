data "aws_vpc" "selected" {
  count = var.enable_egress_controls ? 1 : 0

  filter {
    name   = "tag:Name"
    values = [var.vpc_name]
  }
}

data "aws_subnets" "private" {
  count = var.enable_egress_controls ? 1 : 0

  filter {
    name   = "vpc-id"
    values = [data.aws_vpc.selected[0].id]
  }

  tags = {
    SubnetType = "Private"
  }
}

data "aws_subnet" "private" {
  for_each = var.enable_egress_controls ? toset(data.aws_subnets.private[0].ids) : toset([])

  id = each.value
}

data "aws_subnets" "eks_private" {
  count = var.enable_egress_controls ? 1 : 0

  filter {
    name   = "vpc-id"
    values = [data.aws_vpc.selected[0].id]
  }

  tags = {
    SubnetType = "EKS-Private"
  }
}

data "aws_subnet" "eks_private" {
  for_each = var.enable_egress_controls ? toset(data.aws_subnets.eks_private[0].ids) : toset([])

  id = each.value
}

locals {
  enable_envoy_resources        = var.enable_envoy_setup || var.enable_egress_controls
  envoy_proxy_full_name         = "${var.resource_name_prefix}-${var.envoy_proxy_name}"
  envoy_proxy_url               = "http://${local.envoy_proxy_full_name}.${var.namespace}.svc.cluster.local:${var.envoy_proxy_port}"
  envoy_proxy_no_proxy          = "127.0.0.1,localhost,.svc,.cluster.local"
  envoy_java_proxy_tool_options = "-Dhttp.proxyHost=${local.envoy_proxy_full_name} -Dhttp.proxyPort=${var.envoy_proxy_port} -Dhttps.proxyHost=${local.envoy_proxy_full_name} -Dhttps.proxyPort=${var.envoy_proxy_port} -Dhttp.nonProxyHosts=localhost|127.*|*.svc|*.cluster.local -Dhttps.nonProxyHosts=localhost|127.*|*.svc|*.cluster.local"
  vpc_egress_cidr_blocks = distinct(concat(
    [for subnet in data.aws_subnet.private : subnet.cidr_block],
    [for subnet in data.aws_subnet.eks_private : subnet.cidr_block]
  ))

  envoy_labels = {
    app                          = local.envoy_proxy_full_name
    "app.kubernetes.io/name"     = var.envoy_proxy_name
    "app.kubernetes.io/instance" = local.envoy_proxy_full_name
  }

  envoy_allowed_host_rbac_permissions = concat(
    flatten([
      for host in distinct(concat(var.envoy_default_allowed_hosts_exact, var.envoy_extra_allowed_hosts_exact)) : [
        {
          header = {
            name = ":authority"
            string_match = {
              exact = host
            }
          }
        },
        {
          header = {
            name = ":authority"
            string_match = {
              exact = format("%s:443", host)
            }
          }
        }
      ]
    ]),
    flatten([
      for suffix in distinct(concat(var.envoy_default_allowed_hosts_suffixes, var.envoy_extra_allowed_hosts_suffixes)) : [
        {
          header = {
            name = ":authority"
            string_match = {
              suffix = suffix
            }
          }
        },
        {
          header = {
            name = ":authority"
            string_match = {
              suffix = format("%s:443", suffix)
            }
          }
        }
      ]
    ])
  )

  calico_egress_policies = merge({
    # Default deny for egress once the allow rules below are in place.
    deny-egress-order = {
      apiVersion = "projectcalico.org/v3"
      kind       = "NetworkPolicy"
      metadata = {
        name      = "${var.resource_name_prefix}-deny-egress-order"
        namespace = var.namespace
      }
      spec = {
        order    = 90.0
        selector = "all()"
        egress = [
          {
            action = "Deny"
          }
        ]
        types = ["Egress"]
      }
    }

    # Allows the Envoy pod to connect to upstream HTTPS endpoints.
    allow-envoy-https-proxy-upstream-egress = {
      apiVersion = "projectcalico.org/v3"
      kind       = "NetworkPolicy"
      metadata = {
        name      = "${var.resource_name_prefix}-allow-envoy-https-proxy-upstream-egress"
        namespace = var.namespace
      }
      spec = {
        order    = 50.0
        selector = "app == \"${local.envoy_proxy_full_name}\""
        egress = [
          {
            action   = "Allow"
            protocol = "TCP"
            destination = {
              nets  = ["0.0.0.0/0"]
              ports = [443]
            }
          }
        ]
        types = ["Egress"]
      }
    }

    # Allows all pods to reach the cluster DNS service.
    allow-dns-egress = {
      apiVersion = "projectcalico.org/v3"
      kind       = "NetworkPolicy"
      metadata = {
        name      = "${var.resource_name_prefix}-allow-dns-egress"
        namespace = var.namespace
      }
      spec = {
        order    = 20.0
        selector = "all()"
        egress = [
          {
            action   = "Allow"
            protocol = "UDP"
            destination = {
              nets  = ["10.100.0.10/32"]
              ports = [53]
            }
          },
          {
            action   = "Allow"
            protocol = "TCP"
            destination = {
              nets  = ["10.100.0.10/32"]
              ports = [53]
            }
          }
        ]
        types = ["Egress"]
      }
    }

    # Allows all pods to reach kube-dns or coredns in kube-system.
    allow-kube-dns-coredns-kubedns = {
      apiVersion = "projectcalico.org/v3"
      kind       = "NetworkPolicy"
      metadata = {
        name      = "${var.resource_name_prefix}-allow-kube-dns-coredns-kubedns"
        namespace = var.namespace
      }
      spec = {
        order    = 25.0
        selector = "all()"
        egress = [
          {
            action   = "Allow"
            protocol = "UDP"
            destination = {
              namespaceSelector = "kubernetes.io/metadata.name == \"kube-system\""
              selector          = "k8s-app in {\"kube-dns\", \"coredns\"}"
              ports             = [53]
            }
          },
          {
            action   = "Allow"
            protocol = "TCP"
            destination = {
              namespaceSelector = "kubernetes.io/metadata.name == \"kube-system\""
              selector          = "k8s-app in {\"kube-dns\", \"coredns\"}"
              ports             = [53]
            }
          }
        ]
        types = ["Egress"]
      }
    }

    # Allows pods to communicate with other pods in the same namespace.
    allow-pod-to-pod-same-namespace-egress = {
      apiVersion = "projectcalico.org/v3"
      kind       = "NetworkPolicy"
      metadata = {
        name      = "${var.resource_name_prefix}-allow-pod-to-pod-same-namespace-egress"
        namespace = var.namespace
      }
      spec = {
        order    = 30.0
        selector = "all()"
        egress = [
          {
            action = "Allow"
            destination = {
              selector = "all()"
            }
          }
        ]
        types = ["Egress"]
      }
    }

    # Allows pods to send HTTPS traffic to the Envoy proxy service.
    allow-egress-envoy-https-proxy = {
      apiVersion = "projectcalico.org/v3"
      kind       = "NetworkPolicy"
      metadata = {
        name      = "${var.resource_name_prefix}-allow-egress-envoy-https-proxy"
        namespace = var.namespace
      }
      spec = {
        order    = 40.0
        selector = "all()"
        egress = [
          {
            action   = "Allow"
            protocol = "TCP"
            destination = {
              selector = "app == \"${local.envoy_proxy_full_name}\""
              ports    = [var.envoy_proxy_port]
            }
          }
        ]
        types = ["Egress"]
      }
    }
    }, length(local.vpc_egress_cidr_blocks) > 0 ? {
    # Allows all pods to directly access private VPC address ranges (RDS and ElastiCache ports).
    allow-vpc-egress = {
      apiVersion = "projectcalico.org/v3"
      kind       = "NetworkPolicy"
      metadata = {
        name      = "${var.resource_name_prefix}-allow-vpc-egress"
        namespace = var.namespace
      }
      spec = {
        order    = 35.0
        selector = "all()"
        egress = [
          {
            action   = "Allow"
            protocol = "TCP"
            destination = {
              nets  = local.vpc_egress_cidr_blocks
              ports = [5432]
            }
          },
          {
            action   = "Allow"
            protocol = "TCP"
            destination = {
              nets  = local.vpc_egress_cidr_blocks
              ports = [6379]
            }
          }
        ]
        types = ["Egress"]
      }
    }
  } : {})
}

# Calico policies that enforce egress controls and allow the Envoy proxy path.
resource "kubernetes_manifest" "calico_egress_policies" {
  for_each = var.enable_egress_controls ? { for name, policy in local.calico_egress_policies : name => policy } : tomap({})

  manifest = each.value
}

# Envoy config map used by the proxy deployment.
resource "kubernetes_config_map_v1" "envoy_https_proxy" {
  count = local.enable_envoy_resources ? 1 : 0

  metadata {
    name      = local.envoy_proxy_full_name
    namespace = var.namespace
    labels    = local.envoy_labels
    annotations = {
      "app.kubernetes.io/managed-by" = "terraform"
    }
  }

  data = {
    "envoy.yaml" = <<EOT
admin:
  address:
    socket_address:
      address: 127.0.0.1
      port_value: 9901

static_resources:
  listeners:
  - name: https_proxy_listener
    address:
      socket_address:
        address: 0.0.0.0
        port_value: ${var.envoy_proxy_port}
    filter_chains:
    - filters:
      - name: envoy.filters.network.http_connection_manager
        typed_config:
          "@type": type.googleapis.com/envoy.extensions.filters.network.http_connection_manager.v3.HttpConnectionManager
          stat_prefix: https_proxy
          codec_type: AUTO
          use_remote_address: true
          access_log:
          - name: envoy.access_loggers.stdout
            typed_config:
              "@type": type.googleapis.com/envoy.extensions.access_loggers.stream.v3.StdoutAccessLog
              log_format:
                json_format:
                  start_time: "%START_TIME%"
                  method: "%REQ(:METHOD)%"
                  authority: "%REQ(:AUTHORITY)%"
                  path: "%REQ(X-ENVOY-ORIGINAL-PATH?:PATH)%"
                  protocol: "%PROTOCOL%"
                  downstream_client_address: "%DOWNSTREAM_DIRECT_REMOTE_ADDRESS%"
                  downstream_client_ip: "%DOWNSTREAM_DIRECT_REMOTE_ADDRESS_WITHOUT_PORT%"
                  downstream_remote_address: "%DOWNSTREAM_REMOTE_ADDRESS%"
                  downstream_remote_ip: "%DOWNSTREAM_REMOTE_ADDRESS_WITHOUT_PORT%"
                  response_code: "%RESPONSE_CODE%"
                  response_code_details: "%RESPONSE_CODE_DETAILS%"
                  upstream_host: "%UPSTREAM_HOST%"
                  upstream_cluster: "%UPSTREAM_CLUSTER%"
                  upstream_service_time_ms: "%RESP(X-ENVOY-UPSTREAM-SERVICE-TIME)%"
                  bytes_received: "%BYTES_RECEIVED%"
                  bytes_sent: "%BYTES_SENT%"
                  duration_ms: "%DURATION%"
                  route_name: "%ROUTE_NAME%"
                  requested_server_name: "%REQUESTED_SERVER_NAME%"
          route_config:
            name: https_proxy_route
            virtual_hosts:
            - name: approved-upstreams
              domains:
              - "*"
              routes:
              - match:
                  connect_matcher: {}
                route:
                  cluster: dynamic_forward_proxy_cluster
                  upgrade_configs:
                  - upgrade_type: CONNECT
                    connect_config: {}
          upgrade_configs:
          - upgrade_type: CONNECT
          http_filters:
          - name: envoy.filters.http.rbac
            typed_config:
              "@type": type.googleapis.com/envoy.extensions.filters.http.rbac.v3.RBAC
              rules:
                action: ALLOW
                policies:
                  approved-hosts:
                    permissions:
                      ${indent(22, yamlencode(local.envoy_allowed_host_rbac_permissions))}
                    principals:
                    - any: true
          - name: envoy.filters.http.dynamic_forward_proxy
            typed_config:
              "@type": type.googleapis.com/envoy.extensions.filters.http.dynamic_forward_proxy.v3.FilterConfig
              dns_cache_config:
                name: dynamic_forward_proxy_cache_config
                dns_lookup_family: V4_ONLY
                host_ttl: ${var.envoy_dns_host_ttl}
          - name: envoy.filters.http.router
            typed_config:
              "@type": type.googleapis.com/envoy.extensions.filters.http.router.v3.Router

  clusters:
  - name: dynamic_forward_proxy_cluster
    connect_timeout: ${var.envoy_connect_timeout}
    lb_policy: CLUSTER_PROVIDED
    cluster_type:
      name: envoy.clusters.dynamic_forward_proxy
      typed_config:
        "@type": type.googleapis.com/envoy.extensions.clusters.dynamic_forward_proxy.v3.ClusterConfig
        dns_cache_config:
          name: dynamic_forward_proxy_cache_config
          dns_lookup_family: V4_ONLY
          host_ttl: ${var.envoy_dns_host_ttl}
EOT
  }
}

# Envoy deployment that runs the HTTPS proxy.
resource "kubernetes_deployment_v1" "envoy_https_proxy" {
  count = local.enable_envoy_resources ? 1 : 0

  metadata {
    name      = local.envoy_proxy_full_name
    namespace = var.namespace
    labels    = local.envoy_labels
    annotations = {
      "app.kubernetes.io/managed-by" = "terraform"
    }
  }

  spec {
    replicas                  = var.envoy_proxy_replicas
    min_ready_seconds         = 10
    progress_deadline_seconds = 600
    revision_history_limit    = 5

    strategy {
      type = "RollingUpdate"

      rolling_update {
        max_surge       = "1"
        max_unavailable = "0"
      }
    }

    selector {
      match_labels = local.envoy_labels
    }

    template {
      metadata {
        labels = local.envoy_labels
        annotations = {
          "checksum/envoy-config" = sha256(kubernetes_config_map_v1.envoy_https_proxy[0].data["envoy.yaml"])
        }
      }

      spec {
        security_context {
          run_as_non_root = true
          run_as_user     = 101
          run_as_group    = 101
        }

        init_container {
          name  = "validate-envoy-config"
          image = var.envoy_image

          command = ["envoy"]
          args = [
            "--mode",
            "validate",
            "-c",
            "/etc/envoy/envoy.yaml",
          ]

          volume_mount {
            name       = "envoy-config"
            mount_path = "/etc/envoy/envoy.yaml"
            sub_path   = "envoy.yaml"
            read_only  = true
          }
        }

        container {
          name  = "envoy"
          image = var.envoy_image

          args = [
            "-c",
            "/etc/envoy/envoy.yaml",
            "--service-cluster",
            local.envoy_proxy_full_name,
            "--log-level",
            var.envoy_log_level,
          ]

          port {
            name           = "proxy"
            container_port = var.envoy_proxy_port
          }

          port {
            name           = "admin"
            container_port = 9901
          }

          readiness_probe {
            tcp_socket {
              port = "proxy"
            }
            period_seconds = 10
          }

          liveness_probe {
            tcp_socket {
              port = "proxy"
            }
            initial_delay_seconds = 15
            period_seconds        = 20
          }

          resources {
            requests = {
              cpu    = "100m"
              memory = "128Mi"
            }
            limits = {
              cpu    = "500m"
              memory = "256Mi"
            }
          }

          security_context {
            allow_privilege_escalation = false
          }

          volume_mount {
            name       = "envoy-config"
            mount_path = "/etc/envoy/envoy.yaml"
            sub_path   = "envoy.yaml"
            read_only  = true
          }
        }

        volume {
          name = "envoy-config"
          config_map {
            name = kubernetes_config_map_v1.envoy_https_proxy[0].metadata[0].name
          }
        }
      }
    }
  }
}

# Pod disruption budget for the Envoy proxy pods.
resource "kubernetes_pod_disruption_budget_v1" "envoy_https_proxy" {
  count = local.enable_envoy_resources ? 1 : 0

  metadata {
    name      = local.envoy_proxy_full_name
    namespace = var.namespace
    labels    = local.envoy_labels
    annotations = {
      "app.kubernetes.io/managed-by" = "terraform"
    }
  }

  spec {
    min_available = "1"

    selector {
      match_labels = local.envoy_labels
    }
  }
}

# ClusterIP service that exposes the Envoy proxy inside the namespace.
resource "kubernetes_service_v1" "envoy_https_proxy" {
  count = local.enable_envoy_resources ? 1 : 0

  metadata {
    name      = local.envoy_proxy_full_name
    namespace = var.namespace
    labels    = local.envoy_labels
    annotations = {
      "app.kubernetes.io/managed-by" = "terraform"
    }
  }

  spec {
    selector = local.envoy_labels

    port {
      name        = "https-proxy"
      port        = var.envoy_proxy_port
      target_port = var.envoy_proxy_port
    }

    type = "ClusterIP"
  }
}

# Secret with proxy env vars for application pods.
resource "kubernetes_secret_v1" "envoy_https_proxy_env" {
  count = local.enable_envoy_resources ? 1 : 0

  metadata {
    name      = "${local.envoy_proxy_full_name}-env"
    namespace = var.namespace
    labels    = local.envoy_labels
    annotations = {
      "app.kubernetes.io/managed-by" = "terraform"
    }
  }

  data = {
    HTTP_PROXY              = local.envoy_proxy_url
    HTTPS_PROXY             = local.envoy_proxy_url
    NO_PROXY                = local.envoy_proxy_no_proxy
    http_proxy              = local.envoy_proxy_url
    https_proxy             = local.envoy_proxy_url
    no_proxy                = local.envoy_proxy_no_proxy
    JAVA_PROXY_TOOL_OPTIONS = local.envoy_java_proxy_tool_options
  }
}
