# Amazon OpenSearch to S3 Snapshots: Automation & Disaster Recovery

A production-ready guide, IAM policy templates, shell scripts, and configuration manifests for automating manual snapshots from **Amazon OpenSearch Service** into your own **customer-managed Amazon S3 bucket**.

---

## Architectural Overview

### 1. End-to-End Traffic & Snapshot Flow
The request flow travels from the execution client (EC2/Bastion) through OpenSearch's internal security layer, prompting the service principal to stream snapshot data directly into your designated S3 bucket:

![OpenSearch to S3 Architecture](images/opensearch_s3_flow.jpg)

### 2. Two-Layer Security Model (AWS IAM vs. OpenSearch FGAC)
Understanding the division between cloud infrastructure permissions and database-internal authorization prevents the common 403 Forbidden error:

![Two-Layer Security Model](images/opensearch_permissions_model.jpg)

---

## Why Use Customer-Managed S3 Snapshots?

By default, Amazon OpenSearch Service takes hourly automated snapshots and retains them for 14 days. While helpful for immediate rollbacks, automated snapshots have critical operational constraints:

1. **Storage Opacity:** Snapshots are stored in an AWS-managed S3 bucket that you cannot view, download, or directly interact with.
2. **Hard Retention Limits:** You cannot retain automated snapshots beyond 14 days without paying full OpenSearch cluster storage prices.
3. **Zero Portability:** You cannot directly export AWS-managed snapshots to another AWS account, another region, or an on-premise cluster for testing.
4. **No Tiered Storage Savings:** You cannot apply [Amazon S3 Lifecycle Policies](https://docs.aws.amazon.com/AmazonS3/latest/userguide/object-lifecycle-mgmt.html) (such as transitioning older snapshots to [S3 Standard-IA](https://docs.aws.amazon.com/AmazonS3/latest/userguide/storage-class-intro.html)) to optimize long-term storage costs.

By registering your own Amazon S3 bucket as a snapshot repository, you unlock:
- **Long-term compliance archives:** Keep data for 30, 90, or 365+ days.
- **Cross-account & cross-region DR:** Restore snapshots directly into a separate disaster recovery cluster or AWS account.
- **Cost optimization:** Use S3 Lifecycle transitions (e.g., Standard to Standard-IA after 30 days).
- **Logical isolation:** Segment backup paths by cluster, environment, or microservice.

---

## Repository Structure

```
opensearch-s3-snapshots/
├── README.md                              # Complete deployment guide & architecture
├── BLOG.md                                # Humanized, relatable engineering blog post
├── BLOG.html                              # Clean HTML blog ready to publish to CMS
├── dev-tools-cheatsheet.md                # Everyday OpenSearch Dev Tools commands
├── images/
│   ├── opensearch_s3_flow.jpg             # End-to-end cloud architecture diagram
│   └── opensearch_permissions_model.jpg   # Two-layer security diagram (IAM vs FGAC)
├── iam-policies/
│   ├── opensearch-s3-trust-policy.json    # Allows es.amazonaws.com to assume role
│   ├── opensearch-s3-snapshot-policy.json # S3 bucket read/write/list permissions
│   └── ec2-pass-role-policy.json          # Allows caller to pass snapshot role & call ES
└── opensearch-config/
    ├── register-repository.sh             # Bash script to register S3 repositories
    ├── daily-snapshot-policy.json         # Automated daily SM cron policy
    ├── manual-snapshot.json               # Payload for on-demand manual snapshot
    └── restore-snapshot.json              # Payload for safe index restore with renaming
```

---

## Step-by-Step Implementation Guide

### Step 1: Create the Dedicated S3 Bucket
1. Create a dedicated bucket in the **same AWS Region** as your OpenSearch domain (e.g., `my-opensearch-backup-bucket`). Keeping both in the same region ensures zero cross-region data transfer fees.
2. Enable **Default Server-Side Encryption** (`SSE-S3` or `SSE-KMS`).
3. Add an [Amazon S3 Lifecycle Rule](https://docs.aws.amazon.com/AmazonS3/latest/userguide/object-lifecycle-mgmt.html):
   - Transition objects under prefix `opensearch-snapshots/` to **S3 Standard-IA** after 30 days.
   - *Note:* Do not transition snapshots to S3 Glacier or Deep Archive if you expect OpenSearch to restore them on demand. OpenSearch requires real-time read access to snapshot metadata and data chunks.

### Step 2: Create the OpenSearch Snapshot IAM Role
OpenSearch needs permission to read and write snapshot artifacts in your S3 bucket.

1. Create an IAM Role named `opensearch-s3-snapshot-role`.
2. Attach the trust relationship from [`iam-policies/opensearch-s3-trust-policy.json`](./iam-policies/opensearch-s3-trust-policy.json):
   ```json
   {
     "Version": "2012-10-17",
     "Statement": [
       {
         "Effect": "Allow",
         "Principal": { "Service": "es.amazonaws.com" },
         "Action": "sts:AssumeRole"
       }
     ]
   }
   ```
3. Attach the custom inline policy from [`iam-policies/opensearch-s3-snapshot-policy.json`](./iam-policies/opensearch-s3-snapshot-policy.json):
   ```json
   {
     "Version": "2012-10-17",
     "Statement": [
       {
         "Effect": "Allow",
         "Action": ["s3:ListBucket"],
         "Resource": ["arn:aws:s3:::my-opensearch-backup-bucket"],
         "Condition": {
           "StringLike": { "s3:prefix": ["opensearch-snapshots/*", "opensearch-snapshots"] }
         }
       },
       {
         "Effect": "Allow",
         "Action": ["s3:GetObject", "s3:PutObject", "s3:DeleteObject"],
         "Resource": ["arn:aws:s3:::my-opensearch-backup-bucket/opensearch-snapshots/*"]
       }
     ]
   }
   ```

### Step 3: Grant Your Execution Role Permission to Pass the Role
The identity that executes the repository registration (e.g. an EC2 instance profile, AWS SSM Session role, or developer IAM role) must be allowed to call OpenSearch HTTP endpoints and pass the snapshot role via [`iam:PassRole`](https://docs.aws.amazon.com/IAM/latest/UserGuide/id_roles_use_passrole.html).

Attach [`iam-policies/ec2-pass-role-policy.json`](./iam-policies/ec2-pass-role-policy.json) to your execution role:
```json
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Effect": "Allow",
      "Action": ["es:ESHttpPut", "es:ESHttpGet", "es:ESHttpPost"],
      "Resource": ["arn:aws:es:us-east-1:123456789012:domain/my-opensearch-cluster/*"]
    },
    {
      "Effect": "Allow",
      "Action": "iam:PassRole",
      "Resource": "arn:aws:iam::123456789012:role/opensearch-s3-snapshot-role"
    }
  ]
}
```

### Step 4: Map the Execution Role in OpenSearch Dashboards (The Critical Pitfall)
If your OpenSearch domain has [Fine-Grained Access Control (FGAC)](https://docs.aws.amazon.com/opensearch-service/latest/developerguide/fgac.html) enabled, AWS IAM only authenticates your identity. The internal security plugin evaluates permissions inside the cluster. If unmapped, it returns:

```json
{
  "type": "security_exception",
  "reason": "no permissions for [cluster:admin/repository/put] and User [name=arn:aws:iam::123456789012:role/ec2-ssm-role, ...]"
}
```

**How to fix:**
1. Open **OpenSearch Dashboards**.
2. Navigate to **Security** → **Roles**.
3. Locate the built-in `manage_snapshots` role and click **Edit**.
4. Click the **Mapped users** tab → **Manage mapping**.
5. Under **Backend roles**, paste the full ARN of your execution role:
   ```text
   arn:aws:iam::123456789012:role/ec2-ssm-role
   ```
6. Click **Map**.

---

### Step 5: Register the S3 Snapshot Repository
Connect to your **EC2 Bastion Host** (e.g. via AWS Systems Manager Session Manager).

Install `awscurl` (which handles [AWS Signature Version 4](https://docs.aws.amazon.com/general/latest/gr/signing_aws_api_requests.html) request signing):
```bash
sudo yum install python3 python3-pip -y
sudo pip3 install awscurl
```

Execute the registration script:
```bash
./opensearch-config/register-repository.sh \
  "https://search-my-opensearch-domain-xxxxxx.us-east-1.es.amazonaws.com" \
  "us-east-1" \
  "my-opensearch-backup-bucket" \
  "arn:aws:iam::123456789012:role/opensearch-s3-snapshot-role"
```

Verify that the repository is registered:
```bash
awscurl -XGET "https://search-my-opensearch-domain-xxxxxx.us-east-1.es.amazonaws.com/_snapshot/_all" \
  --service es \
  --region us-east-1
```

---

### Step 6: Automate Daily Snapshots via Snapshot Management (SM)
OpenSearch includes an integrated [Snapshot Management (SM)](https://opensearch.org/docs/latest/tuning-your-cluster/availability-and-recovery/snapshots/snapshot-management/) plugin (OpenSearch ≥ 2.1) that handles automated scheduling and retention cleanup without requiring external Lambda functions or cron servers.

Create the automated daily policy:
```bash
awscurl -XPOST "https://search-my-opensearch-domain-xxxxxx.us-east-1.es.amazonaws.com/_plugins/_sm/policies/daily-snapshot-policy" \
  --service es \
  --region us-east-1 \
  -H 'Content-Type: application/json' \
  -d @opensearch-config/daily-snapshot-policy.json
```

**Policy Behavior:**
- **Creation Schedule:** Runs every night at 20:00 UTC (`cron: 0 20 * * *`).
- **Deletion Schedule:** Evaluates retention every night at 21:00 UTC (`cron: 0 21 * * *`).
- **Retention Rule:** Retains the last 7 daily snapshots (`max_count: 7`, `min_count: 1`), automatically pruning older backups.

---

### Step 7: Test Safe Restore with Index Renaming
Before relying on backups, test an on-demand snapshot and restoration in a non-production cluster.

#### Trigger Manual Snapshot
```json
PUT _snapshot/daily-snapshots/manual-test-snapshot
{
  "indices": "application-logs-*",
  "ignore_unavailable": true,
  "include_global_state": false
}
```

#### Perform Safe Restore (Rename indices to avoid overwriting live data)
```json
POST _snapshot/daily-snapshots/manual-test-snapshot/_restore
{
  "indices": "application-logs-*",
  "rename_pattern": "(.+)",
  "rename_replacement": "$1_restored",
  "include_global_state": false
}
```

Verify restored indices:
```text
GET _cat/indices/*_restored?v
```

---

## Authoritative Documentation & References

- [Amazon OpenSearch Service Manual Snapshots Guide](https://docs.aws.amazon.com/opensearch-service/latest/developerguide/managedomains-snapshots.html)
- [OpenSearch Snapshot Management (SM) Documentation](https://opensearch.org/docs/latest/tuning-your-cluster/availability-and-recovery/snapshots/snapshot-management/)
- [OpenSearch Fine-Grained Access Control (FGAC)](https://docs.aws.amazon.com/opensearch-service/latest/developerguide/fgac.html)
- [AWS IAM PassRole Best Practices](https://docs.aws.amazon.com/IAM/latest/UserGuide/id_roles_use_passrole.html)
- [Amazon S3 Storage Classes & Lifecycle Management](https://docs.aws.amazon.com/AmazonS3/latest/userguide/storage-class-intro.html)
- [AWS Signature Version 4 (SigV4) Signing](https://docs.aws.amazon.com/general/latest/gr/signing_aws_api_requests.html)
- [awscurl Open-Source CLI Tool](https://github.com/okigan/awscurl)
