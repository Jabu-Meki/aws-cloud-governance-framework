# AWS Cloud Governance Framework

CloudFormation-based AWS governance baseline that brings together cost controls, logging, security monitoring, and drift detection into a single deployable framework.

This project was built to show practical infrastructure engineering skills across:

- infrastructure as code with nested CloudFormation stacks
- AWS governance and cost control design
- operational guardrails and monitoring
- cross-service integration across S3, SNS, Lambda, CloudTrail, Config, GuardDuty, EventBridge, Access Analyzer, and StackSets
- failure recovery, rollback debugging, and deployment hardening

## Why This Project Matters

Many cloud projects stop at provisioning resources. This one focuses on governance after provisioning:

- How do we control spend before it runs away?
- How do we centralize alerts across different AWS services?
- How do we detect drift between declared infrastructure and deployed infrastructure?
- How do we surface risky activity like root account use, missing MFA signals, and policy changes?
- How do we design CloudFormation so failures are understandable and recoverable?

The result is a portfolio project that is not just about creating infrastructure, but about operating it responsibly.

## What The Framework Deploys

The master stack orchestrates four nested stacks.

### 1. Budget Enforcement

Purpose:
- create budget thresholds and cost alerts
- centralize notifications through SNS
- trigger automated remediation when a budget breach occurs
- stand up AWS Config recording and snapshot delivery

Key resources:
- SNS topic for governance alerts
- email SNS subscription
- three monthly AWS Budget thresholds
- Lambda remediation function
- Lambda execution role
- AWS Config recorder
- AWS Config delivery channel
- Config delivery S3 bucket

### 2. Logging And Audit

Purpose:
- record account activity with CloudTrail
- create CloudWatch alarms for high-signal security events
- provide audit-friendly storage and analytics foundations

Key resources:
- CloudTrail trail
- CloudTrail S3 log bucket
- CloudWatch Logs integration
- metric filters for:
  - root account login
  - console login without MFA
  - IAM policy changes
  - CloudTrail configuration changes
  - unauthorized API calls
  - S3 policy changes
- CloudWatch alarms routed to the shared SNS topic
- Athena results bucket and query layer

### 3. Security Baseline

Purpose:
- enable native AWS security monitoring services
- route important findings into the same shared alerting pipeline
- add automated remediation flow for public S3 exposure

Key resources:
- GuardDuty detector
- Access Analyzer
- EventBridge rules for GuardDuty and Access Analyzer findings
- IAM roles for automation
- SSM automation-triggering workflow for S3 remediation

### 4. Drift Detection

Purpose:
- check whether deployed infrastructure still matches CloudFormation intent
- alert when stacks drift
- demonstrate multi-region governance awareness

Key resources:
- drift detection Lambda
- EventBridge schedule
- Lambda log group
- drift logging bucket
- StackSet definition for regional monitoring baseline

## Architecture Overview

```text
                    +---------------------------+
                    |   master-stack.yaml       |
                    |   governance-<env>        |
                    +------------+--------------+
                                 |
      +--------------------------+---------------------------+
      |                          |                           |
      v                          v                           v
+-------------+        +----------------+         +------------------+
| Budget      |        | Logging &      |         | Security         |
| Enforcement |        | Audit          |         | Baseline         |
+------+------+        +--------+-------+         +---------+--------+
       |                        |                           |
       | SNS topic              | CloudTrail/Alarms        | GuardDuty/Analyzer
       | Budget alerts          | Athena foundation        | EventBridge rules
       | Config recorder        |                           |
       +------------+-----------+------------+--------------+
                    |                        |
                    v                        v
                Shared SNS alert topic   Drift Detection stack
                                         Lambda + schedule + StackSet
```

## Technical Highlights

This repository demonstrates several implementation decisions that are worth calling out in an interview or portfolio review.

### Nested Stack Orchestration

The top-level stack in [cloudformation/master-stack.yaml](cloudformation/master-stack.yaml) coordinates stack-to-stack dependencies and passes shared values such as:

- environment
- budget value
- cost allocation tags
- alert topic ARN
- config bucket name

This makes the project easier to reason about than one monolithic template and mirrors how larger CloudFormation estates are often structured.

### Shared Alerting Channel

Multiple governance domains publish into a single SNS topic:

- budgets
- security events
- drift alerts

This creates one operational inbox instead of scattered service-specific notifications.

### Recovery And Hardening Work

During development, this project exposed real CloudFormation failure modes, including:

- nested stack parameter mismatches
- AWS Config policy issues
- invalid AWS Config recorder settings
- bad external document references
- cross-stack policy ownership problems
- rollback failures caused by versioned S3 buckets

The repo now includes hardening changes based on those failures, not just happy-path template writing.

### Tags And Cost Attribution

The stack design consistently uses:

- `Environment`
- `Project`
- `CostCenter`

This reflects a practical FinOps mindset rather than purely technical provisioning.

## Repository Structure

```text
.
├── cloudformation/
│   ├── master-stack.yaml
│   └── nested-stacks/
│       ├── budget-enforcement.yaml
│       ├── logging-audit.yaml
│       ├── security-baseline.yaml
│       └── drift-detection.yaml
├── Makefile
├── README.md
└── DEPLOYMENT_NOTES.md
```

## Key Files

- [cloudformation/master-stack.yaml](cloudformation/master-stack.yaml)
  The orchestration layer for all nested stacks.

- [cloudformation/nested-stacks/budget-enforcement.yaml](cloudformation/nested-stacks/budget-enforcement.yaml)
  Budgeting, SNS alerting, remediation Lambda, and AWS Config setup.

- [cloudformation/nested-stacks/logging-audit.yaml](cloudformation/nested-stacks/logging-audit.yaml)
  CloudTrail, alarms, and Athena audit foundation.

- [cloudformation/nested-stacks/security-baseline.yaml](cloudformation/nested-stacks/security-baseline.yaml)
  GuardDuty, Access Analyzer, and S3 remediation workflow.

- [cloudformation/nested-stacks/drift-detection.yaml](cloudformation/nested-stacks/drift-detection.yaml)
  Drift detection Lambda, schedule, and StackSet definition.

- [DEPLOYMENT_NOTES.md](DEPLOYMENT_NOTES.md)
  Detailed notes on deployment failures, fixes, and recovery steps.

## Deployment Model

This project deploys nested stack templates from S3.

The workflow is:

1. Create an artifact bucket.
2. Upload nested stack templates to S3.
3. Deploy the master stack with parameter overrides.

## Prerequisites

- AWS CLI v2 installed
- AWS credentials configured for the target account
- permissions for CloudFormation, IAM, S3, SNS, Lambda, CloudTrail, Config, EventBridge, GuardDuty, Access Analyzer, CloudWatch, Budgets, and StackSets

Optional:

- `cfn-lint` if you want to run the lint target

## How To Deploy

### 1. Bootstrap The Artifact Bucket

```bash
make bootstrap ENV=dev
```

### 2. Optional Validation

```bash
make validate ENV=dev
```

Optional lint:

```bash
make lint
```

### 3. Upload Nested Templates

```bash
make package ENV=dev
```

### 4. Deploy The Master Stack

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

- `<your-email>` with your notification email
- `<account-id>` with your AWS account ID

### 5. Verify Deployment

```bash
make status ENV=dev
make outputs ENV=dev
```

### 6. Confirm SNS Email Subscription

After deployment, AWS sends an SNS subscription confirmation email. Alerts will not flow until it is confirmed.

## Supported Make Targets

- `make bootstrap ENV=dev`
- `make lint`
- `make validate ENV=dev`
- `make package ENV=dev`
- `make deploy-guided ENV=dev`
- `make status ENV=dev`
- `make outputs ENV=dev`
- `make destroy ENV=dev`
- `make clean`

## Troubleshooting

### `make lint` fails

Install `cfn-lint`:

```bash
pip install cfn-lint
```

### Stack deletion gets stuck on S3 buckets

Several buckets in this project are versioned. If deletion fails, remove all object versions first, then retry the stack deletion.

### Email notifications are missing

Check whether the SNS subscription is still pending confirmation.

### CloudFormation rollback is partial

Look at:

- root stack events
- nested stack events
- bucket versions for retained or versioned S3 buckets

This project intentionally surfaced that real governance stacks often fail on teardown logic rather than creation syntax.

## Limitations

This section is intentionally direct. The goal of the project is to demonstrate solid engineering judgment, not to pretend the framework is production-complete.

### 1. Single-Account Focus

The design is mainly oriented around one AWS account at a time. It does not implement a full AWS Organizations multi-account governance model with delegated admin patterns, SCPs, centralized logging accounts, or organization-wide Config aggregators.

### 2. Region Assumptions

The deployment flow is centered on `us-east-1`. While parts of the design reference multi-region concepts, the operational path and testing were not generalized into a fully region-agnostic deployment framework.

### 3. StackSet Implementation Is Lightweight

The drift detection stack includes a StackSet definition, but this is more of a governance-awareness demonstration than a mature multi-region rollout solution. It is not a complete StackSet operations framework.

### 4. No CI/CD Pipeline

There is no full CI/CD workflow in the repository. Deployment is manual through AWS CLI and Makefile helpers. A production-grade version should add:

- template validation in CI
- change set review
- automated promotion across environments
- policy-as-code checks

### 5. Limited Application Code Surface

The Lambda functionality is embedded in CloudFormation rather than broken out into separately tested packages. This keeps the project self-contained, but it limits maintainability, local testing depth, and packaging discipline.

### 6. Incomplete FinOps Depth

The budgeting layer demonstrates practical alerting and remediation, but it is not a full FinOps platform. It does not include:

- cost anomaly detection workflows
- showback or chargeback dashboards
- CUR ingestion pipelines
- executive reporting automation

### 7. Security Controls Are A Baseline, Not A Full Program

The security stack enables useful native services, but it is not a comprehensive cloud security program. It does not include:

- Security Hub aggregation
- detective and preventive controls across all major AWS services
- centralized incident response automation
- organization-wide detective guardrails

### 8. Some AWS Service Integrations Were Simplified For Reliability

During recovery work, a broken PCI-DSS conformance pack reference was removed because it was not deployable in the tested context. That was the correct reliability choice for the project, but it means the current stack favors deployability over maximum control coverage.

### 9. Manual Cleanup May Be Needed On Failed Rollbacks

Because the project uses versioned S3 buckets and services like CloudTrail and Config that can continue writing during lifecycle transitions, failed rollbacks may require manual bucket cleanup before CloudFormation can finish deletion.

### 10. Not Yet Packaged As A Reusable Product

This is a strong engineering portfolio project, but not yet a polished internal platform product. A more reusable version would add:

- environment templates
- parameter files
- clearer release/versioning strategy
- automated integration testing
- modular documentation per stack


## This project demonstrates:

- ability to design beyond simple resource provisioning
- understanding of AWS operational risk, not just syntax
- ownership of debugging and hardening failed deployments
- cross-service reasoning across cost, security, logging, and operations
- honesty about tradeoffs and limitations

## Additional Notes

For detailed failure analysis and recovery history, see:

- [DEPLOYMENT_NOTES.md](DEPLOYMENT_NOTES.md)
