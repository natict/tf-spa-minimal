# tf-spa-minimal
Minimal Terraform configuration for Single Page Applications

# Usage
## Creating the infrastructure
- Configure `terraform.tfvars`
```hcl-terraform
aws_region  =   "eu-west-1"
domain_name =   "app.example.com"
name        =   "test-app"
zone_name   =   "example.com."
```

- Apply Terraform
```shell script
terraform init
terraform apply
```

## Continuous Delivery
- Add a version
```shell script
yarn build  # build the SPA, put the results in ./dist
aws s3 sync ./dist s3://YOUR-BUCKET-NAME/v1-2-3
# You can now access https://v1-2-3.app.example.com
```

- Deploy a version publicly (or revert)
```shell script
aws lambda update-function-configuration --function-name YOUR-FUNCTION-NAME --environment '{"Variables": {"S3_BUCKET": "YOUR-BUCKET-NAME", "latest": "v1-2-3"}}'
aws cloudfront create-invalidation --distribution-id YOUR-DISTRIBUTION-ID --paths '/*'
# invalidation might take up to 5 minutes, then you can access v1-2-3 at https://app.example.com
```

# Note
For real production use you should add:
- Lifecycle policy and/or Lambda to remove old versions from the bucket
- Manage retention for the Lambda CloudWatch log group
- Proper tagging
- Least privilege IAM policies
