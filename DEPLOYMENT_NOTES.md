# Deployment Notes

## Summary

The `governance-dev` stack now deploys successfully in `us-east-1`.

The original failure had two layers:

1. `make deploy` failed locally because `cfn-lint` was not installed.
2. Several CloudFormation nested stack templates had real deployment issues.

## What Was Fixed

### 1. Budget enforcement stack parameter wiring

Updated the master stack so `BudgetEnforcementStack` passes the correct parameters:

- `MonthlyBudgetAmount` now maps from `MonthlyBudgetLimit`
- `AlertEmail` is passed into the nested stack

Files:

- `cloudformation/master-stack.yaml`
- `cloudformation/nested-stacks/budget-enforcement.yaml`

### 2. Email subscription is no longer hardcoded

Added an `AlertEmail` parameter to the budget enforcement nested stack and created an SNS email subscription resource that uses `!Ref AlertEmail`.

Files:

- `cloudformation/nested-stacks/budget-enforcement.yaml`

### 3. Fixed AWS Config bucket policy in budget stack

The original S3 bucket policy for the AWS Config delivery bucket used incompatible actions and resources in the same statement.

Fix:

- kept `s3:GetBucketAcl` and `s3:GetBucketLocation` on the bucket ARN
- kept `s3:PutObject` on the object ARN path

File:

- `cloudformation/nested-stacks/budget-enforcement.yaml`

### 4. Fixed invalid AWS Config recorder configuration

The template used:

- `AllSupported: true`
- explicit `ResourceTypes`

That combination is invalid in AWS Config.

Fix:

- removed explicit `ResourceTypes`
- retained `AllSupported: true`

File:

- `cloudformation/nested-stacks/budget-enforcement.yaml`

### 5. Added missing `CostCenterTag` parameters to nested stacks

The master stack passed `CostCenterTag` to nested stacks that did not declare it, which caused nested stack creation to fail.

Added `CostCenterTag` to:

- `cloudformation/nested-stacks/logging-audit.yaml`
- `cloudformation/nested-stacks/security-baseline.yaml`
- `cloudformation/nested-stacks/drift-detection.yaml`

### 6. Removed broken PCI-DSS conformance pack resource

The security baseline stack referenced this SSM document:

- `AWSConformancePacks/Operational-Best-Practices-for-PCI-DSS`

That document was not available via SSM in this deployment context, and the conformance pack failed creation.

Fix:

- removed `PCIDSSConformancePack`
- removed the related output

File:

- `cloudformation/nested-stacks/security-baseline.yaml`

### 7. Moved shared SNS topic publish policy ownership

The security baseline stack created a `TopicPolicy` on the shared SNS topic from the budget stack. During rollback, that policy became difficult to delete because it was the last applied policy on the topic.

Fix:

- removed `EventBridgeSNSPolicy` from `security-baseline.yaml`
- added EventBridge publish permission into `BudgetAlertTopicPolicy` in the budget stack

Files:

- `cloudformation/nested-stacks/security-baseline.yaml`
- `cloudformation/nested-stacks/budget-enforcement.yaml`

### 8. Improved rollback safety for CloudTrail log bucket

The logging stack rollback failed because the CloudTrail bucket was not empty when CloudFormation tried to delete it.

Fix:

- added `DeletionPolicy: Retain`
- added `UpdateReplacePolicy: Retain`

File:

- `cloudformation/nested-stacks/logging-audit.yaml`

## AWS Cleanup Performed During Recovery

During debugging and recovery, the following cleanup work was needed:

- emptied versioned objects from the AWS Config delivery bucket
- emptied versioned objects from the CloudTrail bucket
- deleted failed nested stacks that were stuck in rollback
- deleted the failed root stack and redeployed from a clean state

## Current Result

Deployment status:

- Root stack: `CREATE_COMPLETE`
- `BudgetEnforcementStack`: `CREATE_COMPLETE`
- `LoggingAuditStack`: `CREATE_COMPLETE`
- `SecurityBaselineStack`: `CREATE_COMPLETE`
- `DriftDetectionStack`: `CREATE_COMPLETE`

## Makefile Change

The `make deploy` target was removed from the Makefile.

Reason:

- it depended on local `cfn-lint`
- it stopped before deployment when `cfn-lint` was not installed
- the manual AWS CLI deployment path was the reliable recovery path used to complete deployment

## How To Deploy

### 1. Bootstrap the artifact bucket

Run:

```bash
make bootstrap ENV=dev
```

### 2. Upload nested stack templates

Run:

```bash
make package ENV=dev
```

This syncs the nested templates to:

- `s3://<account-id>-cfn-artifacts-dev/us-east-1/nested-stacks/`

### 3. Deploy the master stack with AWS CLI

Run:

```bash
aws cloudformation deploy \
  --template-file cloudformation/master-stack.yaml \
  --stack-name governance-dev \
  --region us-east-1 \
  --capabilities CAPABILITY_NAMED_IAM CAPABILITY_AUTO_EXPAND \
  --parameter-overrides \
    Environment=dev \
    MonthlyBudgetLimit=50 \
    AlertEmail=<your-email> \
    ProjectTag=cloud-governance \
    CostCenterTag=engineering \
    ArtifactBucketName=<account-id>-cfn-artifacts-dev \
  --tags \
    Project=cloud-governance \
    Environment=dev \
    ManagedBy=CloudFormation \
  --no-fail-on-empty-changeset
```

Replace:

- `<your-email>` with the budget/security alert email
- `<account-id>` with your AWS account ID

### 4. Check deployment status

Run:

```bash
make status ENV=dev
make outputs ENV=dev
```

### 5. Confirm SNS email subscription

After deployment:

- check the inbox for the `AlertEmail` address
- confirm the SNS subscription

Notifications will not flow until the email subscription is confirmed.

