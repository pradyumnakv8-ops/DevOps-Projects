# Terraform Backend Details

This document collects the Terraform backend details discussed for the `DevOps-Project-01` infrastructure. The backend stores Terraform state remotely in Amazon S3, in the `ap-south-1` region.

## What is a Terraform backend?

A Terraform backend determines where Terraform stores state. State maps Terraform resource addresses (such as `aws_vpc.main`) to the real infrastructure resources Terraform manages. Terraform reads state to plan changes and writes state after successful operations.

State can include resource IDs, endpoint information, configuration data, and sensitive values. Treat it as confidential even if variables are marked `sensitive`.

## Where to configure it

Put the backend block inside the existing `terraform` block in a `.tf` file in the Terraform root directory, such as `provider.tf`. Do not put backend configuration in `terraform.tfvars`.

Example `provider.tf` configuration:

```hcl
terraform {
  # S3 native lock-file support requires Terraform 1.10 or later.
  required_version = ">= 1.10.0"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
  }

  backend "s3" {
    bucket       = "replace-with-a-globally-unique-state-bucket"
    key          = "java-login-app/dev/terraform.tfstate"
    region       = "ap-south-1"
    encrypt      = true
    use_lockfile = true
  }
}

provider "aws" {
  region = var.aws_region
}
```

The provider region may use `var.aws_region`. Backend settings are initialized before Terraform evaluates variables, so backend values must be literal values. They cannot reference variables, locals, or resources.

## Backend settings

| Setting | Meaning |
| --- | --- |
| `bucket` | Existing S3 bucket that stores the state object. S3 bucket names must be globally unique. |
| `key` | Object path for this environment's state. Use a different key for every environment. |
| `region` | AWS region where the state bucket is located; here, `ap-south-1`. |
| `encrypt` | Requests encryption for Terraform's state object. Configure and verify bucket encryption too. |
| `use_lockfile` | Enables S3-native locking to prevent concurrent changes to the same state. Requires Terraform 1.10 or later. |

Use a separate key for each environment, for example:

```text
java-login-app/dev/terraform.tfstate
java-login-app/staging/terraform.tfstate
java-login-app/prod/terraform.tfstate
```

The key is an object path; S3 does not require the folder-like prefixes to be created beforehand.

## Create and secure the S3 bucket

Create the bucket before running `terraform init`. Replace the placeholder with a globally unique name:

```bash
aws s3api create-bucket \
  --bucket replace-with-a-globally-unique-state-bucket \
  --region ap-south-1 \
  --create-bucket-configuration LocationConstraint=ap-south-1
```

Enable versioning to preserve prior state versions:

```bash
aws s3api put-bucket-versioning \
  --bucket replace-with-a-globally-unique-state-bucket \
  --versioning-configuration Status=Enabled
```

Enable default encryption with SSE-S3:

```bash
aws s3api put-bucket-encryption \
  --bucket replace-with-a-globally-unique-state-bucket \
  --server-side-encryption-configuration \
  '{"Rules":[{"ApplyServerSideEncryptionByDefault":{"SSEAlgorithm":"AES256"}}]}'
```

Block public access:

```bash
aws s3api put-public-access-block \
  --bucket replace-with-a-globally-unique-state-bucket \
  --public-access-block-configuration \
  'BlockPublicAcls=true,IgnorePublicAcls=true,BlockPublicPolicy=true,RestrictPublicBuckets=true'
```

Restrict IAM access to approved operators and deployment roles. For stronger protection, enforce HTTPS and least-privilege access through the bucket policy and IAM policies.

## Initialize Terraform

First verify the AWS identity and then initialize from the Terraform root directory:

```bash
aws sts get-caller-identity
cd DevOps-Project-01/infrastructure-v2
terraform init
```

If Terraform was already initialized with another backend configuration, use:

```bash
terraform init -reconfigure
```

`-reconfigure` points Terraform at the newly configured backend; it does not migrate local state. If local state already exists and must be copied to S3, use `terraform init` and carefully review Terraform's state-migration prompt. Confirm the AWS account, bucket, key, and environment before approving migration.

## Locking

With `use_lockfile = true`, Terraform uses an S3 lock object to prevent concurrent operations from changing the same state simultaneously. Do not manually delete a lock object while an operation may still be running. Use `terraform force-unlock` only after confirming the lock is stale and verifying the lock ID.

This setting requires Terraform 1.10 or later. Older Terraform versions commonly use a DynamoDB table for locking. Use the locking method supported by the Terraform version in use and consult its backend documentation before changing the configuration.

## State security and good practices

- Never commit `terraform.tfstate`, `terraform.tfstate.*`, plan files, credentials, or secret-bearing variable files.
- Keep the S3 bucket private and block public access.
- Enable S3 versioning and encryption.
- Restrict read/write permissions to the people and automation that need them.
- Use distinct state keys for development, staging, and production.
- Protect state backups and prior object versions as carefully as the live state.
- Review `terraform plan` before applying.
- A variable marked `sensitive` is redacted in CLI output but may still be stored in state.

## Common issues

- **Bucket not found:** Create the bucket before running `terraform init`.
- **Access denied:** Check the active AWS identity and permissions for the bucket and object key.
- **Wrong region:** Ensure the backend `region` matches the bucket's region.
- **Unsupported `use_lockfile`:** Upgrade to Terraform 1.10 or later, or configure the locking approach supported by the installed version.
- **Unexpected state or environment:** Stop before applying. Verify the AWS account, bucket, key, and workspace/environment. Do not overwrite or migrate state blindly.
- **Bucket name unavailable:** S3 bucket names are globally unique; choose another name and update the backend block consistently.

## Suggested workflow

```bash
aws sts get-caller-identity
terraform init
terraform fmt -recursive
terraform validate
terraform plan
# Apply only after reviewing the plan.
terraform apply
```

## Summary

The backend configuration tells Terraform:

- `bucket`: where state is stored
- `key`: which state object and environment to use
- `region`: where the S3 bucket lives
- `encrypt`: request encryption for state writes
- `use_lockfile`: prevent concurrent state operations

Create and secure the bucket before initialization. Keep state private, versioned, encrypted, and separate by environment.
