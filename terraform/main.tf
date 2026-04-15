# ---------------------------------------------------------
# ACCOUNT INFO & LOCAL VARIABLES
# ---------------------------------------------------------

# This "data" block automatically fetches your current AWS Account ID and details.
# We use this later to make sure our S3 bucket names are globally unique.
data "aws_caller_identity" "current" {}

# "locals" are like variables that you can reuse throughout your code to keep things clean.
locals {
  # If you are using a custom domain, this creates a list with both the root (example.com) 
  # and the www version (www.example.com). If not, it stays empty.
  aliases = var.use_custom_domain && var.root_domain != "" ? [
    var.root_domain,
    "www.${var.root_domain}"
  ] : []

  # This combines your project name and environment (e.g., "myproject-prod") to use as a prefix for naming things.
  name_prefix = "${var.project_name}-${var.environment}"

  # These tags are attached to all your resources to help you identify and organize them in AWS.
  common_tags = {
    Project     = var.project_name
    Environment = var.environment
    ManagedBy   = "terraform"
  }
}

# ---------------------------------------------------------
# PRIVATE STORAGE (BACKEND MEMORY)
# ---------------------------------------------------------

# Creates an S3 bucket to store private data for your application (like conversation memory).
resource "aws_s3_bucket" "memory" {
  bucket = "${local.name_prefix}-memory-${data.aws_caller_identity.current.account_id}"
  tags   = local.common_tags
}

# This security block ensures that everything in the memory bucket is strictly private.
# It blocks all public access to prevent accidental data leaks.
resource "aws_s3_bucket_public_access_block" "memory" {
  bucket = aws_s3_bucket.memory.id

  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

# Enforces that the AWS account owner has full control over all files in this bucket.
resource "aws_s3_bucket_ownership_controls" "memory" {
  bucket = aws_s3_bucket.memory.id

  rule {
    object_ownership = "BucketOwnerEnforced"
  }
}

# ---------------------------------------------------------
# PUBLIC STORAGE (FRONTEND WEBSITE)
# ---------------------------------------------------------

# Creates an S3 bucket to hold your website files (HTML, CSS, JavaScript).
resource "aws_s3_bucket" "frontend" {
  bucket = "${local.name_prefix}-frontend-${data.aws_caller_identity.current.account_id}"
  tags   = local.common_tags
}

# Unlike the memory bucket, this block explicitly ALLOWS public access
# because people need to be able to view your website on the internet.
resource "aws_s3_bucket_public_access_block" "frontend" {
  bucket = aws_s3_bucket.frontend.id

  block_public_acls       = false
  block_public_policy     = false
  ignore_public_acls      = false
  restrict_public_buckets = false
}

# Tells AWS to treat this bucket like a website and defines the main page (index.html) 
# and the error page (404.html).
resource "aws_s3_bucket_website_configuration" "frontend" {
  bucket = aws_s3_bucket.frontend.id

  index_document {
    suffix = "index.html"
  }

  error_document {
    key = "404.html"
  }
}

# A security policy that officially grants the public permission to "read" (GetObject) 
# the files in your frontend bucket so the website actually loads in their browser.
resource "aws_s3_bucket_policy" "frontend" {
  bucket = aws_s3_bucket.frontend.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid       = "PublicReadGetObject"
        Effect    = "Allow"
        Principal = "*"
        Action    = "s3:GetObject"
        Resource  = "${aws_s3_bucket.frontend.arn}/*"
      },
    ]
  })

  # This ensures Terraform opens the public access block BEFORE applying this policy.
  depends_on = [aws_s3_bucket_public_access_block.frontend]
}

# ---------------------------------------------------------
# SECURITY: IAM ROLE FOR LAMBDA
# ---------------------------------------------------------

# Creates an Identity and Access Management (IAM) role. This is like an ID card 
# that allows your Lambda function to securely interact with other AWS services.
resource "aws_iam_role" "lambda_role" {
  name = "${local.name_prefix}-lambda-role"
  tags = local.common_tags

  # This policy explicitly states that the AWS Lambda service is allowed to use this ID card.
  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Action = "sts:AssumeRole"
        Effect = "Allow"
        Principal = {
          Service = "lambda.amazonaws.com"
        }
      },
    ]
  })
}

# Attaches a pre-made AWS policy that gives the Lambda basic permissions, 
# like the ability to write error logs to CloudWatch.
#resource "aws_iam_role_policy_attachment" "lambda_basic" {
#  policy_arn = "arn:aws:iam::aws:policy/service-role/AWSLambdaBasicExecutionRole"
#  role       = aws_iam_role.lambda_role.name
#}

# Gives the Lambda function full access to Amazon Bedrock (AWS's AI/Generative AI service).
resource "aws_iam_role_policy_attachment" "lambda_bedrock" {
  policy_arn = "arn:aws:iam::aws:policy/AmazonBedrockFullAccess"
  role       = aws_iam_role.lambda_role.name
}

# Gives the Lambda function full access to read/write from Amazon S3 (so it can use the memory bucket).
resource "aws_iam_role_policy_attachment" "lambda_s3" {
  policy_arn = "arn:aws:iam::aws:policy/AmazonS3FullAccess"
  role       = aws_iam_role.lambda_role.name
}

# ---------------------------------------------------------
# BACKEND: AWS LAMBDA FUNCTION
# ---------------------------------------------------------

# The actual serverless backend function that runs your Python code.
resource "aws_lambda_function" "api" {
  filename         = "${path.module}/../backend/lambda-deployment.zip" # Where your code is located
  function_name    = "${local.name_prefix}-api"
  role             = aws_iam_role.lambda_role.arn                        # Attaches the IAM ID card we made above
  handler          = "lambda_handler.handler"                            # The specific Python function to run
  source_code_hash = filebase64sha256("${path.module}/../backend/lambda-deployment.zip") # Detects if code changed so Terraform knows to update it
  runtime          = "python3.12"                                        # The programming language
  architectures    = ["x86_64"]
  timeout          = var.lambda_timeout                                  # How long the function is allowed to run before timing out
  tags             = local.common_tags

  # Passes environment variables into your Python code so it knows about the bucket and domain.
  environment {
    variables = {
      CORS_ORIGINS     = var.use_custom_domain ? "https://${var.root_domain},https://www.${var.root_domain}" : "https://${aws_cloudfront_distribution.main.domain_name}"
      S3_BUCKET        = aws_s3_bucket.memory.id
      USE_S3           = "true"
      OPENAI_API_KEY   = var.openai_api_key
      #BEDROCK_MODEL_ID = var.bedrock_model_id
    }
  }

  # Ensures CloudFront is created first, because the Lambda needs the CloudFront domain for CORS_ORIGINS.
  depends_on = [aws_cloudfront_distribution.main]
}

# ---------------------------------------------------------
# FRONT DOOR: API GATEWAY
# ---------------------------------------------------------

# Creates an HTTP API. This acts as the bridge between the internet and your Lambda function.
resource "aws_apigatewayv2_api" "main" {
  name          = "${local.name_prefix}-api-gateway"
  protocol_type = "HTTP"
  tags          = local.common_tags

  # CORS (Cross-Origin Resource Sharing) configuration ensures only your website 
  # is allowed to make requests to this API, keeping it safe from malicious sites.
  cors_configuration {
    allow_credentials = false
    allow_headers     = ["*"]
    allow_methods     = ["GET", "POST", "OPTIONS"]
    allow_origins     = ["*"]
    max_age           = 300
  }
}

# Creates a deployment "stage" for the API. The auto_deploy flag means changes go live automatically.
# It also includes rate limiting (throttling) to prevent abuse or sudden traffic spikes.
resource "aws_apigatewayv2_stage" "default" {
  api_id      = aws_apigatewayv2_api.main.id
  name        = "$default"
  auto_deploy = true
  tags        = local.common_tags

  default_route_settings {
    throttling_burst_limit = var.api_throttle_burst_limit
    throttling_rate_limit  = var.api_throttle_rate_limit
  }
}

# Connects the API Gateway to your specific Lambda function.
resource "aws_apigatewayv2_integration" "lambda" {
  api_id           = aws_apigatewayv2_api.main.id
  integration_type = "AWS_PROXY"
  integration_uri  = aws_lambda_function.api.invoke_arn
}

# ---------------------------------------------------------
# API ROUTES
# ---------------------------------------------------------
# These blocks define the specific URLs (endpoints) your API will respond to.

# Route for the root URL path (e.g., api.yoursite.com/)
resource "aws_apigatewayv2_route" "get_root" {
  api_id    = aws_apigatewayv2_api.main.id
  route_key = "GET /"
  target    = "integrations/${aws_apigatewayv2_integration.lambda.id}"
}

# Route for sending chat messages (e.g., api.yoursite.com/chat)
resource "aws_apigatewayv2_route" "post_chat" {
  api_id    = aws_apigatewayv2_api.main.id
  route_key = "POST /chat"
  target    = "integrations/${aws_apigatewayv2_integration.lambda.id}"
}

# Route to check if the API is online and healthy (e.g., api.yoursite.com/health)
resource "aws_apigatewayv2_route" "get_health" {
  api_id    = aws_apigatewayv2_api.main.id
  route_key = "GET /health"
  target    = "integrations/${aws_apigatewayv2_integration.lambda.id}"
}

# Explicitly grants API Gateway the permission to actually trigger your Lambda function.
resource "aws_lambda_permission" "api_gw" {
  statement_id  = "AllowExecutionFromAPIGateway"
  action        = "lambda:InvokeFunction"
  function_name = aws_lambda_function.api.function_name
  principal     = "apigateway.amazonaws.com"
  source_arn    = "${aws_apigatewayv2_api.main.execution_arn}/*/*"
}

# ---------------------------------------------------------
# CONTENT DELIVERY: CLOUDFRONT
# ---------------------------------------------------------

# Creates a Content Delivery Network (CDN) distribution. This takes your S3 website files 
# and caches them on servers all around the world so they load incredibly fast for users.
resource "aws_cloudfront_distribution" "main" {
  aliases = local.aliases # Attaches your custom domains (if you have them)
  
  # Sets up HTTPS/SSL. It uses a custom certificate if you provided a domain, 
  # or the default AWS certificate if you are just using a generated CloudFront URL.
  viewer_certificate {
    acm_certificate_arn            = var.use_custom_domain ? aws_acm_certificate.site[0].arn : null
    cloudfront_default_certificate = var.use_custom_domain ? false : true
    ssl_support_method             = var.use_custom_domain ? "sni-only" : null
    minimum_protocol_version       = "TLSv1.2_2021"
  }

  # Tells CloudFront where to pull the files from (your frontend S3 bucket).
  origin {
    domain_name = aws_s3_bucket_website_configuration.frontend.website_endpoint
    origin_id   = "S3-${aws_s3_bucket.frontend.id}"

    custom_origin_config {
      http_port              = 80
      https_port             = 443
      origin_protocol_policy = "http-only"
      origin_ssl_protocols   = ["TLSv1.2"]
    }
  }

  enabled             = true
  is_ipv6_enabled     = true
  default_root_object = "index.html" # What page to load when someone visits the base URL
  tags                = local.common_tags

  # Configures how CloudFront caches files. 
  # For example, it forces all HTTP traffic to redirect to secure HTTPS.
  default_cache_behavior {
    allowed_methods  = ["DELETE", "GET", "HEAD", "OPTIONS", "PATCH", "POST", "PUT"]
    cached_methods   = ["GET", "HEAD"]
    target_origin_id = "S3-${aws_s3_bucket.frontend.id}"

    forwarded_values {
      query_string = false
      cookies {
        forward = "none"
      }
    }

    viewer_protocol_policy = "redirect-to-https"
    min_ttl                = 0
    default_ttl            = 3600
    max_ttl                = 86400
  }

  # Allows anyone in the world to access the distribution (no geographic blocks).
  restrictions {
    geo_restriction {
      restriction_type = "none"
    }
  }

  # If a user tries to visit a page that doesn't exist (like /about), this catches the 404 error
  # and redirects them back to index.html. This is very important for Single Page Applications (like React/Vue).
  custom_error_response {
    error_code         = 404
    response_code      = 200
    response_page_path = "/index.html"
  }
}

# ---------------------------------------------------------
# OPTIONAL: CUSTOM DOMAIN (ROUTE 53 & ACM)
# ---------------------------------------------------------
# The "count" argument in these blocks means they will ONLY be created if 
# you set var.use_custom_domain to true. Otherwise, Terraform ignores them.

# Fetches your existing Domain Name System (DNS) zone from AWS Route53.
data "aws_route53_zone" "root" {
  count        = var.use_custom_domain ? 1 : 0
  name         = var.root_domain
  private_zone = false
}

# Requests a free SSL/TLS certificate from AWS Certificate Manager (ACM) 
# so your custom domain can securely use "https://". CloudFront requires certificates to be in the us-east-1 region.
resource "aws_acm_certificate" "site" {
  count                     = var.use_custom_domain ? 1 : 0
  provider                  = aws.us_east_1
  domain_name               = var.root_domain
  subject_alternative_names = ["www.${var.root_domain}"]
  validation_method         = "DNS"
  lifecycle { create_before_destroy = true }
  tags = local.common_tags
}

# Creates a specific DNS record to prove to AWS that you actually own the custom domain.
resource "aws_route53_record" "site_validation" {
  for_each = var.use_custom_domain ? {
    for dvo in aws_acm_certificate.site[0].domain_validation_options :
    dvo.domain_name => dvo
  } : {}

  zone_id = data.aws_route53_zone.root[0].zone_id
  name    = each.value.resource_record_name
  type    = each.value.resource_record_type
  ttl     = 300
  records = [each.value.resource_record_value]
}

# Tells Terraform to wait until the SSL certificate is fully validated before proceeding.
resource "aws_acm_certificate_validation" "site" {
  count           = var.use_custom_domain ? 1 : 0
  provider        = aws.us_east_1
  certificate_arn = aws_acm_certificate.site[0].arn
  validation_record_fqdns = [
    for r in aws_route53_record.site_validation : r.fqdn
  ]
}

# ---------------------------------------------------------
# DNS RECORDS
# ---------------------------------------------------------
# These final blocks connect your custom domain names directly to your CloudFront distribution.

# Connects your root domain (e.g., example.com) over IPv4
resource "aws_route53_record" "alias_root" {
  count   = var.use_custom_domain ? 1 : 0
  zone_id = data.aws_route53_zone.root[0].zone_id
  name    = var.root_domain
  type    = "A"

  alias {
    name                   = aws_cloudfront_distribution.main.domain_name
    zone_id                = aws_cloudfront_distribution.main.hosted_zone_id
    evaluate_target_health = false
  }
}

# Connects your root domain over IPv6
resource "aws_route53_record" "alias_root_ipv6" {
  count   = var.use_custom_domain ? 1 : 0
  zone_id = data.aws_route53_zone.root[0].zone_id
  name    = var.root_domain
  type    = "AAAA"

  alias {
    name                   = aws_cloudfront_distribution.main.domain_name
    zone_id                = aws_cloudfront_distribution.main.hosted_zone_id
    evaluate_target_health = false
  }
}

# Connects the "www" version of your domain (e.g., www.example.com) over IPv4
resource "aws_route53_record" "alias_www" {
  count   = var.use_custom_domain ? 1 : 0
  zone_id = data.aws_route53_zone.root[0].zone_id
  name    = "www.${var.root_domain}"
  type    = "A"

  alias {
    name                   = aws_cloudfront_distribution.main.domain_name
    zone_id                = aws_cloudfront_distribution.main.hosted_zone_id
    evaluate_target_health = false
  }
}

# Connects the "www" version of your domain over IPv6
resource "aws_route53_record" "alias_www_ipv6" {
  count   = var.use_custom_domain ? 1 : 0
  zone_id = data.aws_route53_zone.root[0].zone_id
  name    = "www.${var.root_domain}"
  type    = "AAAA"

  alias {
    name                   = aws_cloudfront_distribution.main.domain_name
    zone_id                = aws_cloudfront_distribution.main.hosted_zone_id
    evaluate_target_health = false
  }
}