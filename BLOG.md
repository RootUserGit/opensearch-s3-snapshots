# Why AWS Automated Snapshots Aren’t Enough: How to Automate OpenSearch Backups to Your Own S3 Bucket

If you run [Amazon OpenSearch Service](https://docs.aws.amazon.com/opensearch-service/latest/developerguide/what-is.html) in production, you likely rely on automated hourly snapshots. Retaining backups for 14 days sounds great on paper. 

In reality, automated snapshots come with serious operational catches:
- They sit in a hidden, AWS-managed S3 bucket you cannot see, download, or inspect.
- You cannot export them to a different AWS account or region for disaster recovery.
- You cannot keep them past 14 days. If auditors request quarterly logs, automated snapshots cannot help.
- If someone deletes the OpenSearch domain, every automated snapshot vanishes immediately with it.

If your cluster stores application logs, audit trails, or critical indexes, relying solely on automated backups is an operational risk.

The solution is simple: store manual snapshots in an Amazon S3 bucket you own and automate the entire lifecycle. This guide walks through our production pattern—covering IAM roles, CloudShell vs. Bastion trade-offs, the 403 permission gotcha, daily automation, and safe restores.

---

## How It Works Under the Hood

OpenSearch does not require background agents or complex sync jobs. When you trigger a snapshot, the OpenSearch service assumes an IAM role you provide, connects directly to Amazon S3, and writes your cluster's Lucene index files into a prefix you define.

![Amazon OpenSearch to S3 Architecture](images/opensearch_s3_flow.jpg)

To make this work, three components must align:
1. **The Snapshot IAM Role:** Trusted by the OpenSearch service (`es.amazonaws.com`) with read/write access to your S3 bucket.
2. **The Bastion Host Execution Role:** The identity making the signed HTTP request to register the repository. It needs permission to pass the snapshot role to OpenSearch via [`iam:PassRole`](https://docs.aws.amazon.com/IAM/latest/UserGuide/id_roles_use_passrole.html).
3. **OpenSearch Internal Security:** If your domain uses [Fine-Grained Access Control (FGAC)](https://docs.aws.amazon.com/opensearch-service/latest/developerguide/fgac.html), OpenSearch blocks your request unless your execution role ARN is mapped inside OpenSearch Dashboards.

---

## Step 1: Create the S3 Bucket (Avoid the Glacier Trap)

Create a dedicated S3 bucket in the **same AWS region** as your OpenSearch domain (e.g., `my-opensearch-backup-bucket`) to avoid cross-region data transfer fees. Enable default server-side encryption (`SSE-S3`), and configure your [Amazon S3 Lifecycle Management](https://docs.aws.amazon.com/AmazonS3/latest/userguide/object-lifecycle-mgmt.html) policy with care.

### Why You Should Avoid S3 Glacier
Many engineers attempt to cut storage costs by transitioning backups to Glacier. **Do not do this with OpenSearch snapshots.**

OpenSearch requires instant, random read access to snapshot metadata and index chunks. If those files reside in Glacier, repository checks fail and restores time out.

**The recommended lifecycle approach:**
- Store active snapshots in **S3 Standard**.
- Transition objects under `opensearch-snapshots/` to [**S3 Standard-Infrequent Access (Standard-IA)**](https://docs.aws.amazon.com/AmazonS3/latest/userguide/storage-class-intro.html) after 30 days. You retain millisecond retrieval times at significantly lower storage costs.

---

## Step 2: The Two IAM Roles You Need

You need two distinct IAM roles: one for OpenSearch itself, and one for the machine executing registration commands.

### 1. The Role OpenSearch Assumes (`opensearch-s3-snapshot-role`)
Create an IAM role with this trust policy:

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

Attach an inline policy granting permissions on your bucket:

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

### 2. Permissions for Your Bastion Host Execution Role
You cannot register snapshot repositories through the AWS web console; you must send an HTTP request to the OpenSearch endpoint. 

The calling role needs access to OpenSearch and permission to pass the snapshot role:

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

### Bastion Host vs. AWS CloudShell: Which Should You Use?
A common question when registering snapshot repositories is: *"Can I just use AWS CloudShell instead of launching an EC2 Bastion?"*

The answer depends on how your OpenSearch cluster is networked:
- **Public OpenSearch Domains:** **Yes.** If your cluster endpoint is public, [AWS CloudShell](https://docs.aws.amazon.com/cloudshell/latest/userguide/welcome.html) is ideal for quick testing. It comes pre-authenticated with your console session—just run `pip install awscurl` and execute the registration API in seconds.
- **Private VPC OpenSearch Domains (Production):** **No.** In production, OpenSearch domains reside inside private VPC subnets without public ingress. Default CloudShell environments run outside your VPC on AWS-managed shared networks and cannot resolve or route to private VPC endpoints.
- **The Verdict:** For production VPC clusters, an **EC2 Bastion Host** inside the same VPC accessed via [AWS Systems Manager Session Manager](https://docs.aws.amazon.com/systems-manager/latest/userguide/session-manager.html) is the battle-tested standard. It requires no public IPs, no open SSH ports, and communicates securely over private VPC networking.

---

## Step 3: The Wall Everyone Hits (OpenSearch Internal Security)

This is where nine out of ten engineers get stuck. 

You configure IAM roles, verify S3 permissions, make the API call, and get hit with:

```json
{
  "type": "security_exception",
  "reason": "no permissions for [cluster:admin/repository/put] and User [name=arn:aws:iam::123456789012:role/ec2-ssm-role, ...]",
  "status": 403
}
```

Even if your IAM role has `AdministratorAccess`, OpenSearch still rejects the request. 

![Two-Layer Security Model: AWS IAM vs. OpenSearch FGAC](images/opensearch_permissions_model.jpg)

When **Fine-Grained Access Control (FGAC)** is enabled, OpenSearch enforces internal role-based access control. AWS IAM only authenticates your identity; OpenSearch internal security decides if you can manage repositories.

### The 60-Second Fix:
1. Log into **OpenSearch Dashboards**.
2. Navigate to **Security** → **Roles**.
3. Locate the built-in role named `manage_snapshots` and click **Edit**.
4. Open the **Mapped users** tab and click **Manage mapping**.
5. Under **Backend roles**, paste the ARN of your execution role:
   `arn:aws:iam::123456789012:role/ec2-ssm-role`
6. Click **Map**.

Once mapped, your execution identity has full cluster rights to create and manage repositories.

---

## Step 4: Register the S3 Repository with awscurl

Log into your EC2 Bastion Host. Because OpenSearch endpoints require [AWS Signature Version 4 (SigV4)](https://docs.aws.amazon.com/general/latest/gr/signing_aws_api_requests.html) authentication, standard `curl` fails unless you pass signed headers. 

Use [`awscurl`](https://github.com/okigan/awscurl), a lightweight CLI tool that signs HTTP requests using your instance credentials:

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

Verify that OpenSearch connects to S3:

```bash
awscurl -XGET "https://search-my-opensearch-domain-xxxxxx.us-east-1.es.amazonaws.com/_snapshot/_all" \
  --service es \
  --region us-east-1
```

If it returns `{"daily-snapshots":{"type":"s3", ...}}`, your cluster and S3 bucket are officially linked.

---

## Step 5: Automate Daily Snapshots (No Lambda Needed)

Historically, automating snapshots required custom Lambda functions or external cron jobs. 

OpenSearch includes a native [Snapshot Management (SM)](https://opensearch.org/docs/latest/tuning-your-cluster/availability-and-recovery/snapshots/snapshot-management/) plugin that handles schedules and retention cleanup directly on the cluster.

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

Every night at 20:00 UTC, OpenSearch snapshots all indices to S3. At 21:00 UTC, it purges snapshots older than the last 7. The lifecycle runs completely hands-free.

---

## Step 6: Testing a Safe Restore (The Index Renaming Trick)

A backup strategy you have never tested is not a strategy—it is a guess.

When testing restores, avoid overwriting live indices by restoring into isolated target indices using `rename_pattern` and `rename_replacement` via the [OpenSearch Snapshot Restore API](https://docs.aws.amazon.com/opensearch-service/latest/developerguide/managedomains-snapshots.html#managedomains-restore-snapshots).

### 1. Run an on-demand snapshot:
```json
PUT _snapshot/daily-snapshots/manual-test-snapshot
{
  "indices": "application-logs-*",
  "ignore_unavailable": true,
  "include_global_state": false
}
```

### 2. Restore into safe test indices:
```json
POST _snapshot/daily-snapshots/manual-test-snapshot/_restore
{
  "indices": "application-logs-2026.09.10",
  "rename_pattern": "(.+)",
  "rename_replacement": "$1_restored",
  "include_global_state": false
}
```

OpenSearch pulls the index chunks from S3 and restores them as `application-logs-2026.09.10_restored`. You can inspect document counts, verify search health, and delete the test index when finished—without impacting production traffic.

---

## Key Takeaways from the Trenches

- **Organize by Cluster and Service:** Structure S3 paths like `opensearch-snapshots/<environment>/<service-name>/`. Clean layouts make replication and audits simple.
- **Keep Shard Counts Healthy:** Snapshots run per shard. If your cluster has thousands of tiny shards, snapshots take hours and spike CPU. Consolidate small indices.
- **Cross-Account Migrations are Easy:** Because snapshot files reside in standard S3 buckets, migrating to another AWS account requires only granting the target account\'s OpenSearch role read access to the bucket.

---

## Wrapping Up

AWS automated snapshots provide a short-term rollback window, but customer-managed S3 snapshots give you genuine data ownership. 

Once configured, your backups are portable, your retention policies are automated, and your disaster recovery strategy is real.

*All policy templates, shell scripts, and Dev Tools commands are available on GitHub: [RootUserGit/opensearch-s3-snapshots](https://github.com/RootUserGit/opensearch-s3-snapshots).*
