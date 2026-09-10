# OpenSearch Dev Tools Cheatsheet

A collection of everyday Dev Tools API commands for cluster health inspection, shard management, index templates, manual snapshot operations, and restore testing.

---

## 1. Cluster Health & Resource Allocation

### Check Overall Cluster Health
```json
GET _cluster/health?pretty
```

### Inspect Shard Distribution Across Nodes
```json
GET _cat/shards?v
```

### Check Disk & Shard Allocation per Node
```json
GET _cat/allocation?v
```

### View All Cluster Indices & Sizes
```json
GET _cat/indices?v&s=index
```

### View Cluster Settings
```json
GET _cluster/settings?pretty
```

### Update Maximum Shards per Node (Persistent)
Useful when your cluster scales or you manage multiple time-series indices:
```json
PUT _cluster/settings
{
  "persistent": {
    "cluster.max_shards_per_node": 3000
  }
}
```

---

## 2. Index Templates & Shard Configuration

### Inspect Existing Index Templates
```json
GET _index_template
```

### Define Template for Application Logs
```json
PUT _index_template/application-logs-template
{
  "index_patterns": ["application-logs-*"],
  "template": {
    "settings": {
      "number_of_shards": 1,
      "number_of_replicas": 1
    }
  }
}
```

### Define Template for Service Logs
```json
PUT _index_template/service-logs-template
{
  "index_patterns": ["service-logs-*"],
  "template": {
    "settings": {
      "number_of_shards": 1,
      "number_of_replicas": 1
    }
  }
}
```

---

## 3. Snapshot Repositories & Execution

### List All Registered Snapshot Repositories
```json
GET _snapshot
```

### Inspect Specific Repository Settings & Status
```json
GET _snapshot/daily-snapshots
```

### View All Snapshots Inside a Repository
```json
GET _snapshot/daily-snapshots/_all
```

### Trigger On-Demand Manual Snapshot
```json
PUT _snapshot/daily-snapshots/manual-test-snapshot
{
  "indices": "application-logs-*,service-logs-*",
  "ignore_unavailable": true,
  "include_global_state": false
}
```

### Delete a Specific Snapshot
```json
DELETE _snapshot/daily-snapshots/manual-test-snapshot
```

### Safe Restore (Renaming Indices to Avoid Collision)
```json
POST _snapshot/daily-snapshots/manual-test-snapshot/_restore
{
  "indices": "application-logs-2026.09.10",
  "rename_pattern": "(.+)",
  "rename_replacement": "$1_restored",
  "include_global_state": false
}
```

---

## 4. Snapshot Management (SM) Policy Status

### List Active SM Policies
```json
GET _plugins/_sm/policies
```

### Get Detailed Status of Daily Policy
```json
GET _plugins/_sm/policies/daily-snapshot-policy
```
