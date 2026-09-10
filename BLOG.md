# Taking Control of Amazon OpenSearch Backups: Automating Snapshots to Your Own S3 Bucket

If you run Amazon OpenSearch in production, you probably know that AWS automatically takes hourly snapshots and keeps them for 14 days. On paper, that sounds like a solid backup plan. 

In reality, those automated snapshots have serious operational catches:
- They sit in a hidden, AWS-managed S3 bucket you cannot see, download, or inspect.
- You cannot export them to a different AWS account or another region for disaster recovery.
- You cannot keep them longer than 14 days. If an auditor asks for last quarter's logs, AWS automated snapshots cannot help you.
- If someone accidentally deletes the OpenSearch domain, every single automated snapshot vanishes with it.

If your cluster stores application logs, audit trails, security events, or business-critical indexes, relying only on AWS automated backups is a disaster waiting to happen.

The fix is simple: store manual snapshots in an S3 bucket you own and automate the entire lifecycle. This guide walks through the exact pattern we implemented—covering IAM roles, the infamous 403 permission gotcha that trips up almost everyone, daily automation, and safe restores.

---

## How It Works Under the Hood

OpenSearch does not need background agents or complex sync jobs. When you trigger a snapshot, the OpenSearch service assumes an IAM role you provide, talks directly to Amazon S3, and writes your cluster's Lucene index files into a prefix you define.

To make this happen, three pieces must work together:
1. **The Snapshot IAM Role:** Trusted by the OpenSearch service (`es.amazonaws.com`) with read/write access to your S3 bucket.
2. **The Execution Role (Bastion or CI/CD):** The identity making the signed HTTP request to register the repository. It needs permission to pass the snapshot role to OpenSearch (`iam:PassRole`).
3. **OpenSearch Internal Security:** If your domain uses Fine-Grained Access Control (FGAC), OpenSearch blocks your request unless your execution role ARN is mapped inside OpenSearch Dashboards.

---

## Step 1: Create the S3 Bucket (Avoid the Glacier Trap)

Create a dedicated S3 bucket in the **same AWS region** as your OpenSearch domain (e.g., `my-opensearch-backup-bucket`). Keeping both in the same region ensures zero data transfer fees.

Enable default server-side encryption (`SSE-S3`), and set up your lifecycle policy with care. 

### Why You Should Avoid S3 Glacier
Many engineers try to save money by setting a lifecycle rule that transitions backups to Glacier after a few days. **Do not do this with OpenSearch snapshots.**

OpenSearch requires instant, random read access to snapshot metadata and index chunks whenever it checks repository status or runs a restore. If those files are locked in Glacier, repository checks fail, and restores time out.

**The sweet spot:**
- Keep new snapshots in **S3 Standard**.
- Add a lifecycle rule transitioning objects under `opensearch-snapshots/` to **S3 Standard-Infrequent Access (Standard-IA)** after 30 days. You get immediate millisecond access at significantly lower storage costs.

---

## Step 2: The Two IAM Roles You Need

You need two distinct IAM roles: one for OpenSearch itself, and one for the machine running the setup commands.

### 1. The Role OpenSearch Assumes (`opensearch-s3-snapshot-role`)
First, create an IAM role with this trust policy:

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

Next, attach an inline policy granting permissions on your bucket:

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

### 2. Permissions for Your Execution Role (EC2 or Bastion)
You cannot register snapshot repositories through the AWS web console. You must send an HTTP request to the OpenSearch cluster endpoint. 

Whether you run this from an EC2 instance, AWS Systems Manager (SSM), or a local machine, that calling role needs access to OpenSearch and permission to pass the snapshot role:

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

---

## Step 3: The Wall Everyone Hits (OpenSearch Internal Security)

This is where nine out of ten engineers get stuck. 

You set up the IAM roles, verify your S3 permissions, make the API call, and get hit with:

```json
{
  "type": "security_exception",
  "reason": "no permissions for [cluster:admin/repository/put] and User [name=arn:aws:iam::123456789012:role/ec2-ssm-role, ...]",
  "status": 403
}
```

Even if your IAM role has AWS `AdministratorAccess`, OpenSearch still rejects you. 

When **Fine-Grained Access Control (FGAC)** is enabled, OpenSearch enforces its own internal role-based access control. Getting past IAM just reaches the cluster; OpenSearch's internal security decides whether you can actually touch repositories.

### The 60-Second Fix:
1. Log into **OpenSearch Dashboards**.
2. Go to **Security** → **Roles**.
3. Locate the built-in role named `manage_snapshots` and click to edit it.
4. Open the **Mapped users** tab and click **Manage mapping**.
5. Under **Backend roles**, add the ARN of your execution role:
   `arn:aws:iam::123456789012:role/ec2-ssm-role`
6. Click **Map**.

Once mapped, your execution identity has full cluster rights to create and manage repositories.

---

## Step 4: Register the S3 Repository with awscurl

Because OpenSearch endpoints require AWS Signature Version 4 (SigV4) authentication, standard `curl` fails unless you pass signed headers. 

Use `awscurl`, a lightweight tool that signs HTTP requests using your instance credentials:

```bash
sudo yum install python3 python3-pip -y
sudo pip3 install awscurl
```

Register your repository:

```bash
awscurl -XPUT "https://search-my-opensearch-domain-xxxxxx.us-east-1.es.amazonaws.com/_snapshot/daily-snapshots" \
  --service es \
  --region us-east-1 \
  -H 'Content-Type: application/json' \
  -d '{
    "type": "s3",
    "settings": {
      "bucket": "my-opensearch-backup-bucket",
      "base_path": "opensearch-snapshots/prod-cluster/daily",
      "region": "us-east-1",
      "role_arn": "arn:aws:iam::123456789012:role/opensearch-s3-snapshot-role"
    }
  }'
```

Verify that OpenSearch can talk to S3:

```bash
awscurl -XGET "https://search-my-opensearch-domain-xxxxxx.us-east-1.es.amazonaws.com/_snapshot/_all" \
  --service es \
  --region us-east-1
```

If it returns `{"daily-snapshots":{"type":"s3", ...}}`, your cluster and S3 bucket are officially linked.

---

## Step 5: Automate Daily Snapshots (No Lambda Needed)

In older Elasticsearch setups, automating snapshots meant writing custom Lambda functions or running external cron containers. 

OpenSearch includes a native **Snapshot Management (SM)** plugin (available in OpenSearch 2.1+) that runs schedules and retention cleanup directly on the cluster.

Create the automated daily policy:

```bash
awscurl -XPOST "https://search-my-opensearch-domain-xxxxxx.us-east-1.es.amazonaws.com/_plugins/_sm/policies/daily-snapshot-policy" \
  --service es \
  --region us-east-1 \
  -H 'Content-Type: application/json' \
  -d '{
    "description": "Daily automated snapshot policy to S3 with 7-day retention",
    "creation": {
      "schedule": {
        "cron": {
          "expression": "0 20 * * *",
          "timezone": "UTC"
        }
      },
      "time_limit": "1h"
    },
    "deletion": {
      "schedule": {
        "cron": {
          "expression": "0 21 * * *"
        }
      },
      "delete_condition": {
        "max_count": 7,
        "min_count": 1
      },
      "time_limit": "1h"
    },
    "snapshot_config": {
      "repository": "daily-snapshots",
      "indices": "*",
      "date_format": "yyyy-MM-dd-HH-mm",
      "include_global_state": true
    }
  }'
```

Every night at 20:00 UTC, OpenSearch snapshots all indices to S3. At 21:00 UTC, it cleans up and removes anything older than the last 7 snapshots. The entire process runs completely hands-free.

---

## Step 6: Testing a Safe Restore (The Index Renaming Trick)

A backup strategy you have never tested is not a strategy—it is a guess.

When testing restores, the last thing you want is to overwrite live indices or corrupt active data. You can safely restore any snapshot into new, isolated indices using `rename_pattern` and `rename_replacement`.

### 1. Run an on-demand snapshot:
```json
PUT _snapshot/daily-snapshots/manual-test-snapshot
{
  "indices": "web-portal-logs-*",
  "ignore_unavailable": true,
  "include_global_state": false
}
```

### 2. Restore into safe test indices:
```json
POST _snapshot/daily-snapshots/manual-test-snapshot/_restore
{
  "indices": "web-portal-logs-2026.09.10",
  "rename_pattern": "(.+)",
  "rename_replacement": "$1_restored",
  "include_global_state": false
}
```

OpenSearch pulls the index chunks from S3 and restores them as `web-portal-logs-2026.09.10_restored`. You can inspect document counts, verify search health, and delete the restored index when done—all without risking production workloads.

---

## Key Takeaways from the Trenches

- **Organize by Cluster and App:** Structure your S3 paths like `opensearch-snapshots/<environment>/<app-name>/`. Clean folder layouts make restores and audits painless.
- **Keep Shard Counts Healthy:** Snapshots work shard by shard. If your cluster has thousands of tiny, 100 MB shards, snapshots take hours and spike cluster CPU. Consolidate small indices.
- **Cross-Account Migrations are Easy:** Because snapshot files sit in a standard S3 bucket, migrating to another AWS account is as simple as granting the target account's OpenSearch role read access to the bucket.

---

## Wrapping Up

AWS automated snapshots are fine for emergency rollbacks within 14 days, but genuine data ownership requires storing backups in your own S3 bucket. 

Once this setup is in place, your backups are portable, your retention policies are enforced, and your disaster recovery strategy is real.

*All policy templates, shell scripts, and Dev Tools commands are available on GitHub: [RootUserGit/opensearch-s3-snapshots](https://github.com/RootUserGit/opensearch-s3-snapshots).*
