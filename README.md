# AWS Control Scripts for RodNGun

## Overview
This repository contains AWS infrastructure management and data operation scripts for the RodNGun hunting and fishing regulation platform.

## Contents

### Infrastructure Management
- `check_eks_status.sh` - Check EKS cluster status
- `pause_eks_cluster.sh` - Pause EKS cluster to save costs
- `restore_eks_cluster.sh` - Restore paused EKS cluster
- `rodngun-cloud` - Main cloud infrastructure management CLI

### Database Operations
- `database/` - Database migration and management scripts
- `create_local_mongodb_backup.sh` - Create local MongoDB backups
- `mongodb_backup.sh` - MongoDB backup automation

### Container Management
- `containers/` - Container and Docker-related scripts

### Cost Management
- `cost/` - AWS cost analysis and optimization scripts

### Lightsail
- `lightsail/` - AWS Lightsail management scripts

### Common Utilities
- `common/` - Shared utilities and helper scripts

## Prerequisites

- AWS CLI configured with appropriate credentials
- kubectl for EKS operations
- MongoDB tools for database operations
- Bash shell environment

## Configuration

Create a `.env` file with your AWS and database configuration as needed.

## Usage

### EKS Cluster Management

Check cluster status:
```bash
./check_eks_status.sh
```

Pause cluster (save costs when not in use):
```bash
./pause_eks_cluster.sh
```

Restore cluster:
```bash
./restore_eks_cluster.sh
```

### Cloud Infrastructure

Use the rodngun-cloud CLI:
```bash
./rodngun-cloud --help
```

## Security Notes

- Never commit `.env` files with actual credentials
- Use AWS IAM roles when possible
- Rotate credentials regularly
- Review scripts before execution in production

## License

Copyright © 2024 RodNGun. All rights reserved.