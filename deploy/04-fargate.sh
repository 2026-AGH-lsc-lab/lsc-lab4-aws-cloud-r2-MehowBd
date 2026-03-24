#!/bin/bash
set -euo pipefail
source "$(dirname "$0")/00-config.sh"

echo "=== Step 4: ECS Fargate with ALB ==="

# --- Get default VPC and subnets ---
echo "Finding default VPC..."
VPC_ID=$(aws ec2 describe-vpcs \
    --filters Name=isDefault,Values=true \
    --query 'Vpcs[0].VpcId' --output text --region "$AWS_REGION")
echo "VPC: ${VPC_ID}"

echo "Finding subnets (need 2+ AZs for ALB)..."
SUBNET_IDS=$(aws ec2 describe-subnets \
    --filters "Name=vpc-id,Values=${VPC_ID}" \
    --query 'Subnets[*].SubnetId' --output text --region "$AWS_REGION")
# Convert to array and take first 2
SUBNET_ARRAY=($SUBNET_IDS)
SUBNET_1="${SUBNET_ARRAY[0]}"
SUBNET_2="${SUBNET_ARRAY[1]}"
echo "Subnets: ${SUBNET_1}, ${SUBNET_2}"

# --- Security Groups ---
echo "Creating ALB security group..."
ALB_SG_ID=$(aws ec2 describe-security-groups \
    --filters "Name=group-name,Values=lsc-knn-alb-sg" "Name=vpc-id,Values=${VPC_ID}" \
    --query 'SecurityGroups[0].GroupId' --output text --region "$AWS_REGION" 2>/dev/null)

if [ "$ALB_SG_ID" = "None" ] || [ -z "$ALB_SG_ID" ]; then
    ALB_SG_ID=$(aws ec2 create-security-group \
        --group-name lsc-knn-alb-sg \
        --description "ALB for k-NN lab" \
        --vpc-id "$VPC_ID" \
        --query 'GroupId' --output text --region "$AWS_REGION")
    aws ec2 authorize-security-group-ingress \
        --group-id "$ALB_SG_ID" \
        --protocol tcp --port 80 --cidr 0.0.0.0/0 \
        --region "$AWS_REGION"
fi
echo "ALB SG: ${ALB_SG_ID}"

echo "Creating task security group..."
TASK_SG_ID=$(aws ec2 describe-security-groups \
    --filters "Name=group-name,Values=lsc-knn-task-sg" "Name=vpc-id,Values=${VPC_ID}" \
    --query 'SecurityGroups[0].GroupId' --output text --region "$AWS_REGION" 2>/dev/null)

if [ "$TASK_SG_ID" = "None" ] || [ -z "$TASK_SG_ID" ]; then
    TASK_SG_ID=$(aws ec2 create-security-group \
        --group-name lsc-knn-task-sg \
        --description "ECS task for k-NN lab" \
        --vpc-id "$VPC_ID" \
        --query 'GroupId' --output text --region "$AWS_REGION")
    aws ec2 authorize-security-group-ingress \
        --group-id "$TASK_SG_ID" \
        --protocol tcp --port 8080 --source-group "$ALB_SG_ID" \
        --region "$AWS_REGION"
fi
echo "Task SG: ${TASK_SG_ID}"

# --- ECS Cluster ---
echo "Creating ECS cluster..."
aws ecs create-cluster \
    --cluster-name "$ECS_CLUSTER_NAME" \
    --region "$AWS_REGION" --output text --query 'cluster.clusterArn' 2>/dev/null || true

# --- CloudWatch Log Group ---
echo "Creating log group..."
aws logs create-log-group \
    --log-group-name "/ecs/${ECS_TASK_FAMILY}" \
    --region "$AWS_REGION" 2>/dev/null || true

# --- Task Definition ---
echo "Registering task definition..."
TASK_DEF_JSON=$(cat <<EOJSON
{
    "family": "${ECS_TASK_FAMILY}",
    "networkMode": "awsvpc",
    "requiresCompatibilities": ["FARGATE"],
    "cpu": "512",
    "memory": "1024",
    "executionRoleArn": "${LAB_ROLE_ARN}",
    "taskRoleArn": "${LAB_ROLE_ARN}",
    "containerDefinitions": [
        {
            "name": "${ECS_CONTAINER_NAME}",
            "image": "${ECR_URI}:latest",
            "essential": true,
            "portMappings": [
                {
                    "containerPort": 8080,
                    "protocol": "tcp"
                }
            ],
            "environment": [
                {
                    "name": "MODE",
                    "value": "server"
                }
            ],
            "logConfiguration": {
                "logDriver": "awslogs",
                "options": {
                    "awslogs-group": "/ecs/${ECS_TASK_FAMILY}",
                    "awslogs-region": "${AWS_REGION}",
                    "awslogs-stream-prefix": "ecs"
                }
            },
            "healthCheck": {
                "command": ["CMD-SHELL", "curl -f http://localhost:8080/health || exit 1"],
                "interval": 10,
                "timeout": 5,
                "retries": 3,
                "startPeriod": 30
            }
        }
    ]
}
EOJSON
)

TMPFILE=$(mktemp /tmp/taskdef-XXXX.json)
echo "$TASK_DEF_JSON" > "$TMPFILE"
TASK_DEF_ARN=$(aws ecs register-task-definition \
    --cli-input-json "file://${TMPFILE}" \
    --region "$AWS_REGION" \
    --query 'taskDefinition.taskDefinitionArn' --output text)
rm -f "$TMPFILE"
echo "Task definition: ${TASK_DEF_ARN}"

# --- ALB ---
echo "Creating ALB..."
ALB_ARN=$(aws elbv2 describe-load-balancers \
    --names "$ALB_NAME" \
    --query 'LoadBalancers[0].LoadBalancerArn' --output text \
    --region "$AWS_REGION" 2>/dev/null || true)

if [ -z "$ALB_ARN" ] || [ "$ALB_ARN" = "None" ]; then
    ALB_ARN=$(aws elbv2 create-load-balancer \
        --name "$ALB_NAME" \
        --subnets "$SUBNET_1" "$SUBNET_2" \
        --security-groups "$ALB_SG_ID" \
        --scheme internet-facing \
        --type application \
        --region "$AWS_REGION" \
        --query 'LoadBalancers[0].LoadBalancerArn' --output text)
fi
echo "ALB ARN: ${ALB_ARN}"

ALB_DNS=$(aws elbv2 describe-load-balancers \
    --load-balancer-arns "$ALB_ARN" \
    --query 'LoadBalancers[0].DNSName' --output text --region "$AWS_REGION")
echo "ALB DNS: ${ALB_DNS}"

# --- Target Group ---
echo "Creating target group..."
TG_ARN=$(aws elbv2 describe-target-groups \
    --names "$TG_NAME" \
    --query 'TargetGroups[0].TargetGroupArn' --output text \
    --region "$AWS_REGION" 2>/dev/null || true)

if [ -z "$TG_ARN" ] || [ "$TG_ARN" = "None" ]; then
    TG_ARN=$(aws elbv2 create-target-group \
        --name "$TG_NAME" \
        --protocol HTTP \
        --port 8080 \
        --vpc-id "$VPC_ID" \
        --target-type ip \
        --health-check-path / \
        --health-check-interval-seconds 10 \
        --healthy-threshold-count 2 \
        --region "$AWS_REGION" \
        --query 'TargetGroups[0].TargetGroupArn' --output text)
fi
echo "Target Group: ${TG_ARN}"

# --- Listener ---
echo "Creating ALB listener..."
LISTENER_ARN=$(aws elbv2 describe-listeners \
    --load-balancer-arn "$ALB_ARN" \
    --query 'Listeners[0].ListenerArn' --output text \
    --region "$AWS_REGION" 2>/dev/null || true)

if [ -z "$LISTENER_ARN" ] || [ "$LISTENER_ARN" = "None" ]; then
    LISTENER_ARN=$(aws elbv2 create-listener \
        --load-balancer-arn "$ALB_ARN" \
        --protocol HTTP \
        --port 80 \
        --default-actions "Type=forward,TargetGroupArn=${TG_ARN}" \
        --region "$AWS_REGION" \
        --query 'Listeners[0].ListenerArn' --output text)
fi
echo "Listener: ${LISTENER_ARN}"

# --- ECS Service ---
echo "Creating ECS service..."
EXISTING_SERVICE=$(aws ecs describe-services \
    --cluster "$ECS_CLUSTER_NAME" \
    --services "$ECS_SERVICE_NAME" \
    --query 'services[?status!=`INACTIVE`].serviceName' --output text \
    --region "$AWS_REGION" 2>/dev/null || true)

SUBNET_LIST="${SUBNET_1},${SUBNET_2}"

if [ -z "$EXISTING_SERVICE" ]; then
    aws ecs create-service \
        --cluster "$ECS_CLUSTER_NAME" \
        --service-name "$ECS_SERVICE_NAME" \
        --task-definition "$ECS_TASK_FAMILY" \
        --desired-count 1 \
        --launch-type FARGATE \
        --network-configuration "awsvpcConfiguration={subnets=[${SUBNET_LIST}],securityGroups=[${TASK_SG_ID}],assignPublicIp=ENABLED}" \
        --load-balancers "targetGroupArn=${TG_ARN},containerName=${ECS_CONTAINER_NAME},containerPort=8080" \
        --region "$AWS_REGION" \
        --output text --query 'service.serviceArn'
else
    echo "Service already exists, updating..."
    aws ecs update-service \
        --cluster "$ECS_CLUSTER_NAME" \
        --service "$ECS_SERVICE_NAME" \
        --task-definition "$ECS_TASK_FAMILY" \
        --desired-count 1 \
        --region "$AWS_REGION" \
        --output text --query 'service.serviceArn'
fi

# --- Wait for service to stabilize ---
echo "Waiting for ECS service to stabilize (this may take 1-2 minutes)..."
aws ecs wait services-stable \
    --cluster "$ECS_CLUSTER_NAME" \
    --services "$ECS_SERVICE_NAME" \
    --region "$AWS_REGION"

echo "=== Fargate done. ALB URL: http://${ALB_DNS} ==="
