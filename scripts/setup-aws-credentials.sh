#!/bin/bash
# Setup AWS credentials with minimal permissions for Ephemeral Environments
# This script creates an IAM user with only the permissions needed

set -e

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

echo -e "${GREEN}=== Ephemeral Environments: AWS Credentials Setup ===${NC}"
echo ""

# Check if AWS CLI is installed
if ! command -v aws &> /dev/null; then
    echo -e "${RED}Error: AWS CLI is not installed.${NC}"
    echo "Install it with: brew install awscli"
    exit 1
fi

# Check if user is authenticated
if ! aws sts get-caller-identity &> /dev/null; then
    echo -e "${RED}Error: Not authenticated with AWS.${NC}"
    echo "Run: aws configure"
    exit 1
fi

echo -e "${YELLOW}This script will create:${NC}"
echo "  - IAM user: ephemeral-environments"
echo "  - IAM policy with minimal permissions"
echo "  - Access key for the user"
echo ""
read -p "Continue? (y/n) " -n 1 -r
echo ""
if [[ ! $REPLY =~ ^[Yy]$ ]]; then
    exit 0
fi

# Get AWS account ID
AWS_ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)
AWS_REGION=${AWS_REGION:-us-east-1}

echo ""
echo -e "${GREEN}Creating IAM policy...${NC}"

# Create the policy document
POLICY_DOC=$(cat <<EOF
{
    "Version": "2012-10-17",
    "Statement": [
        {
            "Sid": "EC2Management",
            "Effect": "Allow",
            "Action": [
                "ec2:RunInstances",
                "ec2:TerminateInstances",
                "ec2:StopInstances",
                "ec2:StartInstances",
                "ec2:DescribeInstances",
                "ec2:DescribeInstanceStatus",
                "ec2:CreateTags",
                "ec2:DescribeTags",
                "ec2:DescribeImages",
                "ec2:DescribeSecurityGroups",
                "ec2:DescribeSubnets",
                "ec2:DescribeVpcs"
            ],
            "Resource": "*",
            "Condition": {
                "StringEquals": {
                    "aws:RequestedRegion": "${AWS_REGION}"
                }
            }
        },
        {
            "Sid": "SSMCommands",
            "Effect": "Allow",
            "Action": [
                "ssm:SendCommand",
                "ssm:GetCommandInvocation",
                "ssm:ListCommands",
                "ssm:ListCommandInvocations"
            ],
            "Resource": "*"
        },
        {
            "Sid": "DynamoDBAccess",
            "Effect": "Allow",
            "Action": [
                "dynamodb:PutItem",
                "dynamodb:GetItem",
                "dynamodb:UpdateItem",
                "dynamodb:DeleteItem",
                "dynamodb:Query",
                "dynamodb:Scan"
            ],
            "Resource": [
                "arn:aws:dynamodb:${AWS_REGION}:${AWS_ACCOUNT_ID}:table/ephemeral-environments",
                "arn:aws:dynamodb:${AWS_REGION}:${AWS_ACCOUNT_ID}:table/ephemeral-builds"
            ]
        },
        {
            "Sid": "SQSAccess",
            "Effect": "Allow",
            "Action": [
                "sqs:SendMessage",
                "sqs:ReceiveMessage",
                "sqs:DeleteMessage",
                "sqs:GetQueueAttributes",
                "sqs:GetQueueUrl"
            ],
            "Resource": "arn:aws:sqs:${AWS_REGION}:${AWS_ACCOUNT_ID}:ephemeral-*"
        },
        {
            "Sid": "IAMPassRole",
            "Effect": "Allow",
            "Action": "iam:PassRole",
            "Resource": "arn:aws:iam::${AWS_ACCOUNT_ID}:role/ephemeral-*"
        },
        {
            "Sid": "CloudWatchLogs",
            "Effect": "Allow",
            "Action": [
                "logs:CreateLogGroup",
                "logs:CreateLogStream",
                "logs:PutLogEvents",
                "logs:DescribeLogGroups",
                "logs:DescribeLogStreams",
                "logs:FilterLogEvents",
                "logs:GetLogEvents"
            ],
            "Resource": [
                "arn:aws:logs:${AWS_REGION}:${AWS_ACCOUNT_ID}:log-group:/ephemeral-environments/*",
                "arn:aws:logs:${AWS_REGION}:${AWS_ACCOUNT_ID}:log-group:/aws/lambda/ephemeral-env-*",
                "arn:aws:logs:${AWS_REGION}:${AWS_ACCOUNT_ID}:log-group:/aws/lambda/ephemeral-env-*:*"
            ]
        }
    ]
}
EOF
)

# Create or update the policy
POLICY_ARN="arn:aws:iam::${AWS_ACCOUNT_ID}:policy/EphemeralEnvironmentsPolicy"

if aws iam get-policy --policy-arn "$POLICY_ARN" &> /dev/null; then
    echo "Policy already exists, creating new version..."
    # Delete oldest version if we have 5 versions (AWS limit)
    VERSIONS=$(aws iam list-policy-versions --policy-arn "$POLICY_ARN" --query 'Versions[?IsDefaultVersion==`false`].VersionId' --output text)
    VERSION_COUNT=$(echo "$VERSIONS" | wc -w)
    if [ "$VERSION_COUNT" -ge 4 ]; then
        OLDEST=$(echo "$VERSIONS" | awk '{print $NF}')
        aws iam delete-policy-version --policy-arn "$POLICY_ARN" --version-id "$OLDEST"
    fi
    aws iam create-policy-version --policy-arn "$POLICY_ARN" --policy-document "$POLICY_DOC" --set-as-default > /dev/null
else
    aws iam create-policy --policy-name EphemeralEnvironmentsPolicy --policy-document "$POLICY_DOC" > /dev/null
fi

echo -e "${GREEN}Creating IAM user...${NC}"

# Create user if doesn't exist
if ! aws iam get-user --user-name ephemeral-environments &> /dev/null; then
    aws iam create-user --user-name ephemeral-environments > /dev/null
fi

# Attach policy to user
aws iam attach-user-policy --user-name ephemeral-environments --policy-arn "$POLICY_ARN"

# Delete old access keys
OLD_KEYS=$(aws iam list-access-keys --user-name ephemeral-environments --query 'AccessKeyMetadata[].AccessKeyId' --output text)
for KEY in $OLD_KEYS; do
    aws iam delete-access-key --user-name ephemeral-environments --access-key-id "$KEY"
done

# Create new access key
echo -e "${GREEN}Creating access key...${NC}"
CREDENTIALS=$(aws iam create-access-key --user-name ephemeral-environments --query 'AccessKey.[AccessKeyId,SecretAccessKey]' --output text)
ACCESS_KEY_ID=$(echo "$CREDENTIALS" | awk '{print $1}')
SECRET_ACCESS_KEY=$(echo "$CREDENTIALS" | awk '{print $2}')

echo ""
echo -e "${GREEN}=== SUCCESS ===${NC}"
echo ""
echo -e "${YELLOW}Add these to your .env file:${NC}"
echo ""
echo "AWS_ACCESS_KEY_ID=${ACCESS_KEY_ID}"
echo "AWS_SECRET_ACCESS_KEY=${SECRET_ACCESS_KEY}"
echo "AWS_REGION=${AWS_REGION}"
echo ""
echo -e "${YELLOW}Permissions granted:${NC}"
echo "  - EC2: Run, stop, terminate instances (${AWS_REGION} only)"
echo "  - SSM: Send commands to instances"
echo "  - DynamoDB: Read/write to ephemeral-* tables"
echo "  - SQS: Send/receive from ephemeral-* queues"
echo "  - CloudWatch Logs: Write logs"
echo ""
