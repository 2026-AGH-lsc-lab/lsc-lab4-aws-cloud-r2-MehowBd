#!/bin/bash
# Shared configuration for all deployment scripts

export AWS_REGION=us-east-1
export ACCOUNT_ID="${ACCOUNT_ID:-637423171855}"
if [ "$ACCOUNT_ID" = "YOUR_ACCOUNT_ID" ]; then
    echo "ERROR: Set ACCOUNT_ID before running. Either:"
    echo "  export ACCOUNT_ID=\$(aws sts get-caller-identity --query Account --output text)"
    echo "  or edit deploy/00-config.sh directly."
    exit 1
fi
export LAB_ROLE_ARN="arn:aws:iam::${ACCOUNT_ID}:role/LabRole"

# ECR
export ECR_REPO_NAME=lsc-knn-app
export ECR_URI="${ACCOUNT_ID}.dkr.ecr.${AWS_REGION}.amazonaws.com/${ECR_REPO_NAME}"

# Lambda
export LAMBDA_ZIP_NAME=lsc-knn-zip
export LAMBDA_CONTAINER_NAME=lsc-knn-container
export LAMBDA_MEMORY=512
export LAMBDA_TIMEOUT=30

# ECS / Fargate
export ECS_CLUSTER_NAME=lsc-knn-cluster
export ECS_SERVICE_NAME=lsc-knn-service
export ECS_TASK_FAMILY=lsc-knn-task
export ECS_CONTAINER_NAME=knn-app

# ALB
export ALB_NAME=lsc-knn-alb
export TG_NAME=lsc-knn-tg

# EC2
export APP_SG_NAME=lsc-knn-app-sg
export WS_SG_NAME=lsc-knn-ws-sg
# KEY_NAME defaults to 'vockey' (pre-created by Learner Lab); overridden in 06-workstation.sh
export KEY_NAME=lsc-knn-key

# Paths
export PROJECT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
export WORKLOAD_DIR="${PROJECT_DIR}/workload"
export DEPLOY_DIR="${PROJECT_DIR}/deploy"
export KEY_FILE="${DEPLOY_DIR}/${KEY_NAME}.pem"

echo "Config loaded: ACCOUNT_ID=${ACCOUNT_ID}, REGION=${AWS_REGION}"
