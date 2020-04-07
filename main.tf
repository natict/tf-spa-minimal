variable "aws_region" {}   // eu-west-1
variable "name" {}         // myapp
variable "domain_name" {}  // app.example.com
variable "zone_name" {}    // example.com.

#
# Locals
#
locals {
  api_gw_name = var.name
  lambda_name = var.name
  s3_bucket_name = var.name
  wildcard_domain_name = "*.${var.domain_name}"                 // *.app.example.com
  cloudfront_origin_domain_name = "latest.${var.domain_name}"   // latest.app.example.com
}

#
# Providers
#

provider "aws" {
  region = var.aws_region
}

// We need a provider for us-east-1 to manage CloudFront SSL Certificates
provider "aws" {
  alias = "us-east-1"
  region = "us-east-1"
}

#
# Common Data Sources
#

data "aws_region" "current" {}
data "aws_caller_identity" "current" {}

#
# S3 Bucket
#

resource "aws_s3_bucket" "bucket" {
  bucket        = local.s3_bucket_name
  acl           = "private"
}

#
# Lambda (serving objects from the S3 bucket)
#

resource "aws_iam_role" "lambda_role" {
  name = local.lambda_name
  assume_role_policy = <<EOF
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Action": "sts:AssumeRole",
      "Principal": {
        "Service": "lambda.amazonaws.com"
      },
      "Effect": "Allow",
      "Sid": ""
    }
  ]
}
EOF
}

resource "aws_iam_policy" "allow_read_from_s3_bucket" {
  name = "tf-read-s3-${aws_s3_bucket.bucket.id}"
  policy = <<EOF
{
    "Version": "2012-10-17",
    "Statement": [
        {
            "Effect": "Allow",
            "Action": [
                "s3:Get*",
                "s3:List*"
            ],
            "Resource": [
                "arn:aws:s3:::${aws_s3_bucket.bucket.id}",
                "arn:aws:s3:::${aws_s3_bucket.bucket.id}/*"
            ]
        }
    ]
}
EOF
}

resource "aws_iam_policy" "allow_logging_to_cloudwatch_logs" {
  name = "tf-lambda-${local.lambda_name}-cloudwatch-logs"
  policy = <<EOF
{
    "Version": "2012-10-17",
    "Statement": [
        {
            "Effect": "Allow",
            "Action": [
                "logs:CreateLogGroup",
                "logs:CreateLogStream",
                "logs:PutLogEvents"
            ],
            "Resource": [
                "arn:aws:logs:${data.aws_region.current.name}:${data.aws_caller_identity.current.account_id}:log-group:/aws/lambda/${local.lambda_name}:*"
            ]
        }
    ]
}
EOF
}

resource "aws_iam_role_policy_attachment" "lambda_s3" {
  policy_arn = aws_iam_policy.allow_read_from_s3_bucket.arn
  role = aws_iam_role.lambda_role.name
}

resource "aws_iam_role_policy_attachment" "lambda_cloudwatch" {
  policy_arn = aws_iam_policy.allow_logging_to_cloudwatch_logs.arn
  role = aws_iam_role.lambda_role.name
}

data "archive_file" "lambda_src_zip" {
  type        = "zip"
  output_path = "lambda_src.zip"
  source_dir = "${path.module}/src"
}

resource "aws_lambda_function" "lambda" {
  filename         = data.archive_file.lambda_src_zip.output_path
  source_code_hash = data.archive_file.lambda_src_zip.output_base64sha256

  function_name = local.lambda_name
  handler = "index.handler"
  role = aws_iam_role.lambda_role.arn
  runtime = "nodejs12.x"
  timeout = 180

  environment {
    variables = {
      S3_BUCKET = aws_s3_bucket.bucket.id
    }
  }

  // Enable quick prefix mapping (without applying TF)
  lifecycle {
    ignore_changes = [environment]
  }
}

resource "aws_lambda_permission" "allow_api_gateway" {
  statement_id  = "AllowExecutionFromAPIGateway"
  action        = "lambda:InvokeFunction"
  function_name = aws_lambda_function.lambda.function_name
  principal     = "apigateway.amazonaws.com"

  # More: http://docs.aws.amazon.com/apigateway/latest/developerguide/api-gateway-control-access-using-iam-policies-to-invoke-api.html
  source_arn = "arn:aws:execute-api:${data.aws_region.current.name}:${data.aws_caller_identity.current.account_id}:${aws_api_gateway_rest_api.api.id}/*/*"
}

#
# API Gateway (route incoming traffic to the Lambda)
#
resource "aws_api_gateway_rest_api" "api" {
  name = local.api_gw_name
  binary_media_types = ["*/*"]

  endpoint_configuration {
    types = ["REGIONAL"]
  }
}

data "aws_api_gateway_resource" "root" {
  rest_api_id = aws_api_gateway_rest_api.api.id
  path = "/"
}

resource "aws_api_gateway_resource" "resource" {
  path_part = "{proxy+}"
  parent_id = aws_api_gateway_rest_api.api.root_resource_id
  rest_api_id = aws_api_gateway_rest_api.api.id
}

locals {
  api_gw_resources = [
    aws_api_gateway_resource.resource.id,
    data.aws_api_gateway_resource.root.id
  ]
  methods = [
    "GET",
    "HEAD"
  ]
}

resource "aws_api_gateway_method" "methods" {
  # Each resource should have GET and HEAD
  # Circumvent TF error: value of 'count' cannot be computed
  count = 4  # length(local.api_gw_resources) * length(local.methods)

  rest_api_id = aws_api_gateway_rest_api.api.id
  resource_id = element(local.api_gw_resources, count.index%length(local.api_gw_resources))
  http_method = element(local.methods, floor(count.index/length(local.methods)))
  authorization = "NONE"
}

resource "aws_api_gateway_integration" "integrations" {
  count = length(aws_api_gateway_method.methods)

  rest_api_id = aws_api_gateway_rest_api.api.id
  resource_id = element(aws_api_gateway_method.methods.*.resource_id, count.index)
  http_method = element(aws_api_gateway_method.methods.*.http_method, count.index)
  integration_http_method = "POST"
  type = "AWS_PROXY"
  uri = aws_lambda_function.lambda.invoke_arn
}

resource "aws_api_gateway_deployment" "deploy" {
  depends_on = [ aws_api_gateway_integration.integrations ]

  rest_api_id = aws_api_gateway_rest_api.api.id
  stage_name = "release"
}

resource "aws_api_gateway_base_path_mapping" "map" {
  api_id = aws_api_gateway_rest_api.api.id
  stage_name = aws_api_gateway_deployment.deploy.stage_name
  domain_name = aws_api_gateway_domain_name.domain.domain_name
}

resource "aws_api_gateway_domain_name" "domain" {
  domain_name = local.wildcard_domain_name
  regional_certificate_arn = aws_acm_certificate_validation.wildcard_cert.certificate_arn
  security_policy = "TLS_1_2"

  endpoint_configuration {
    types = ["REGIONAL"]
  }
}

#
# Route53 (wildcard and root domain names) and ACM (SSL certificates)
#

data "aws_route53_zone" "zone" {
  name = var.zone_name
  private_zone = false
}

// Wildcard record

resource "aws_route53_record" "wildcard" {
  zone_id = data.aws_route53_zone.zone.id
  name = aws_api_gateway_domain_name.domain.domain_name
  type = "A"

  alias {
    name = aws_api_gateway_domain_name.domain.regional_domain_name
    zone_id = aws_api_gateway_domain_name.domain.regional_zone_id
    evaluate_target_health = true
  }
}

// Wildcard SSL Certificate

resource "aws_acm_certificate" "wildcard_cert" {
  domain_name = local.wildcard_domain_name
  subject_alternative_names = [var.domain_name]
  validation_method = "DNS"
}

resource "aws_route53_record" "validation" {
  # ACM validation is the same for example.com and *.example.com
  name = aws_acm_certificate.wildcard_cert.domain_validation_options[0].resource_record_name
  type = aws_acm_certificate.wildcard_cert.domain_validation_options[0].resource_record_type
  zone_id = data.aws_route53_zone.zone.id
  records = [aws_acm_certificate.wildcard_cert.domain_validation_options[0].resource_record_value]
  ttl = 60
}

resource "aws_acm_certificate_validation" "wildcard_cert" {
  certificate_arn = aws_acm_certificate.wildcard_cert.arn
  validation_record_fqdns = [aws_route53_record.validation.fqdn]
}

// Cloudfront domain record

resource "aws_route53_record" "cloudfront" {
  zone_id = data.aws_route53_zone.zone.id
  name = var.domain_name
  type = "A"

  alias {
    name = aws_cloudfront_distribution.distribution.domain_name
    zone_id = aws_cloudfront_distribution.distribution.hosted_zone_id
    evaluate_target_health = false
  }
}

// CloudFront SSL Certificate (same, but in us-east-1)

resource "aws_acm_certificate" "cloudfront_cert" {
  domain_name = local.wildcard_domain_name
  subject_alternative_names = [var.domain_name]
  validation_method = "DNS"

  provider = aws.us-east-1 # Certificates for Cloudfront must reside in us-east-1
}

resource "aws_acm_certificate_validation" "cloudfront_cert" {
  certificate_arn = aws_acm_certificate.cloudfront_cert.arn
  validation_record_fqdns = [aws_route53_record.validation.fqdn]

  provider = aws.us-east-1 # Certificates for Cloudfront must reside in us-east-1
}

#
# CloudFront (caching for root domain)
#
resource "random_uuid" "cloudfront_origin_id" {}

resource "aws_cloudfront_distribution" "distribution" {
  aliases = [ var.domain_name ]
  comment = "Distribution for ${var.name} frontend application"
  enabled = true
  is_ipv6_enabled = true
  price_class = "PriceClass_100"

  default_cache_behavior {
    allowed_methods = ["GET", "HEAD"]
    cached_methods = ["GET", "HEAD"]
    compress = true
    target_origin_id = random_uuid.cloudfront_origin_id.result
    viewer_protocol_policy = "redirect-to-https"

    forwarded_values {
      query_string = false

      cookies {
        forward = "none"
      }
    }
  }

  origin {
    domain_name = local.cloudfront_origin_domain_name
    origin_id = random_uuid.cloudfront_origin_id.result

    custom_origin_config {
      http_port = 80
      https_port = 443
      origin_protocol_policy = "https-only"
      origin_ssl_protocols = ["TLSv1.2"]
    }
  }

  restrictions {
    geo_restriction {
      restriction_type = "none"
    }
  }

  viewer_certificate {
    acm_certificate_arn = aws_acm_certificate.cloudfront_cert.arn
    ssl_support_method = "sni-only"
  }

  depends_on = [aws_acm_certificate_validation.cloudfront_cert]
}