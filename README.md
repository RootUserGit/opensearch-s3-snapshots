# Amazon OpenSearch to S3 Snapshots: Automation & Disaster Recovery

A production-ready guide, IAM policy templates, shell scripts, and configuration manifests for automating manual snapshots from **Amazon OpenSearch Service** into your own **customer-managed S3 bucket**.

---

## Why Use Customer-Managed S3 Snapshots?

By default, Amazon OpenSearch Service takes hourly automated snapshots and retains them for 14 days. While helpful for short-term recovery, automated snapshots have major operational limitations:

1. **Storage Opacity:** Snapshots are stored in an AWS-managed S3 bucket that you cannot view, download, or directly interact with.
2. **Hard Retention Limits:** You cannot retain snapshots beyond 14 days without paying full OpenSearch cluster storage prices.
3. **Zero Portability:** You cannot directly export AWS-managed snapshots to another AWS account, another region, or a local environment for testing.
4. **No Tiered Storage Savings:** You cannot apply S3 Lifecycle policies (e.g., transitioning older snapshots to S3 Standard-IA) to lower storage costs.

By registering your own Amazon S3 bucket as a snapshot repository, you unlock:
- **Long-term compliance archives:** Keep data for 30, 90, or 365+ days.
- **Cross-account & cross-region DR:** Restore snapshots directly into a separate disaster recovery cluster or AWS account.
- **Cost optimization:** Use S3 Lifecycle transitions (e.g. Standard to Standard-IA after 30 days).
- **Logical isolation:** Segment backup paths by cluster, environment, or microservice.

---

## Architecture & End-to-End Flow

```
+-----------------------------------------------------------------------------------+
| AWS Account                                                                       |
|                                                                                   |
|  +------------------+         Signed API Request          +--------------------+  |
|  | EC2 / Bastion    | ----------------------------------> | Amazon OpenSearch  |  |
|  | (awscurl / IAM)  |       (PUT _snapshot/my-repo)       | Domain             |  |
|  +------------------+                                     +--------------------+  |
|          |                                                          |             |
|          | iam:PassRole                                             | sts:Assume  |
|          v                                                          v             |
|  +-----------------------------------------------------------------------------+  |
|  | IAM Role: opensearch-s3-snapshot-role (Trusted: es.amazonaws.com)          |  |
|  +-----------------------------------------------------------------------------+  |
|                                         |                                         |
|                                         | PutObject / GetObject / ListBucket      |
|                                         v                                         |
|                    +-----------------------------------------+                    |
|                    | Customer S3 Bucket                      |                    |
|                    | s3://my-opensearch-backup-bucket/       |                    |
|                    |   └── opensearch-snapshots/             |                    |
|                    |         └── prod-cluster/               |                    |
|                    |               ├── daily/                |                    |
|                    |               └── web-portal/           |                    |
|                    +-----------------------------------------+                    |
+-----------------------------------------------------------------------------------+
```

1. **OpenSearch assumes an IAM role** (`opensearch-s3-snapshot-role`) via the `es.amazonaws.com` service principal.
2. **An administrator identity (EC2 role or developer IAM)** signs an API request (`awscurl`) to register the repository, passing the snapshot IAM role to OpenSearch.
3. **OpenSearch checks internal security** (Fine-Grained Access Control). The caller's IAM ARN must be mapped to the `manage_snapshots` backend role.
4. **OpenSearch writes snapshot segments** directly to the target S3 bucket under your specified `base_path`.
5. **OpenSearch Snapshot Management (SM) plugin** automates recurring daily snapshots and enforces retention cleanup policies.

---

## Repository Structure

```
opensearch-s3-snapshots/
├── README.md                              # Complete deployment guide & architecture
├── BLOG.md                                # Humanized, relatable engineering blog post
├── BLOG.html                              # Clean HTML blog ready to publish to CMS
├── dev-tools-cheatsheet.md                # Everyday OpenSearch Dev Tools commands
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
1. Create a dedicated bucket in the **same AWS Region** as your OpenSearch domain (e.g., `my-opensearch-backup-bucket`).
2. Enable **Default Server-Side Encryption** (`SSE-S3` or `SSE-KMS`).
3. Enable **Bucket Versioning** if desired, or leave disabled for standard snapshot storage.
4. Add an **S3 Lifecycle Rule**:
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
3. Attach the custom inline policy from [`iam-policies/opensearch-s3-snapshot-policy.json`](./iam-policies/opensearch-s3-snapshot-policy.json) (replace bucket name with your actual S3 bucket):
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
The identity that executes the repository registration (e.g. an EC2 instance profile, AWS SSM Session role, or developer IAM role) must be allowed to:
- Call OpenSearch HTTP endpoints.
- Pass the snapshot IAM role to the OpenSearch service.

Attach [`iam-policies/ec2-pass-role-policy.json`](./iam-policies/ec2-pass-role-policy.json) to your execution role (replace account ID and domain):
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
If your OpenSearch domain has **Fine-Grained Access Control (FGAC)** enabled (standard for all production domains), IAM permissions alone are **not enough**. OpenSearch's internal security plugin will reject repository creation with:

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
Connect to your EC2 instance or local terminal authenticated with the execution role credentials.

Install `awscurl` (handles AWS SigV4 request signing):
```bash
sudo yum install python3 python3-pip -y
sudo pip3 install awscurl
```

Execute the registration script or curl command:
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
OpenSearch includes an integrated **Snapshot Management** plugin (OpenSearch ≥ 2.1) that handles automated scheduling and retention cleanup without requiring external Lambda functions or cron servers.

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
  "indices": "web-portal-*",
  "ignore_unavailable": true,
  "include_global_state": false
}
```

#### Perform Safe Restore (Rename indices to avoid overwriting live data)
```json
POST _snapshot/daily-snapshots/manual-test-snapshot/_restore
{
  "indices": "web-portal-*",
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

## Troubleshooting Guide

| Symptom | Root Cause | Solution |
| :--- | :--- | :--- |
| **`403 Forbidden: no permissions for [cluster:admin/repository/put]`** | The caller's IAM ARN is not mapped in OpenSearch security. | Add the caller's IAM role ARN to **Backend roles** under the `manage_snapshots` role in OpenSearch Dashboards. |
| **`AmazonS3Exception: Access Denied (Status Code: 403)`** | Snapshot role missing S3 `ListBucket` or `PutObject` permissions, or path prefix mismatch. | Verify `Condition` prefix in [`opensearch-s3-snapshot-policy.json`](./iam-policies/opensearch-s3-snapshot-policy.json) matches the `base_path` in your repository registration. |
| **`repository_verification_exception`** | Bucket is in a different region than declared in repository settings, or KMS key permissions missing. | Ensure the S3 bucket region matches the OpenSearch domain region, and specify `"region": "<region>"` in settings. |
| **Restores are extremely slow or timing out** | Snapshot files were migrated to S3 Glacier or Glacier Deep Archive. | Exclude OpenSearch snapshot directories from deep archive lifecycle rules. Standard and Standard-IA are recommended. |
