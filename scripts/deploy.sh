#!/bin/bash
# Deployment helper script for local Terraform operations

set -e

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

# Default values
ENVIRONMENT=""
ACTION=""

usage() {
    echo "Usage: $0 -e <environment> -a <action>"
    echo ""
    echo "Options:"
    echo "  -e    Environment (dev|prod)"
    echo "  -a    Action (init|plan|apply|destroy)"
    echo "  -h    Show this help message"
    echo ""
    echo "Examples:"
    echo "  $0 -e dev -a plan"
    echo "  $0 -e prod -a apply"
    exit 1
}

while getopts "e:a:h" opt; do
    case $opt in
        e) ENVIRONMENT=$OPTARG ;;
        a) ACTION=$OPTARG ;;
        h) usage ;;
        *) usage ;;
    esac
done

if [ -z "$ENVIRONMENT" ] || [ -z "$ACTION" ]; then
    echo -e "${RED}Error: Missing required arguments${NC}"
    usage
fi

if [ "$ENVIRONMENT" != "dev" ] && [ "$ENVIRONMENT" != "prod" ]; then
    echo -e "${RED}Error: Environment must be 'dev' or 'prod'${NC}"
    exit 1
fi

if [ "$ACTION" != "init" ] && [ "$ACTION" != "plan" ] && [ "$ACTION" != "apply" ] && [ "$ACTION" != "destroy" ]; then
    echo -e "${RED}Error: Action must be 'init', 'plan', 'apply', or 'destroy'${NC}"
    exit 1
fi

TF_DIR="terraform/environments/${ENVIRONMENT}"

if [ ! -d "$TF_DIR" ]; then
    echo -e "${RED}Error: Directory $TF_DIR does not exist${NC}"
    exit 1
fi

echo -e "${GREEN}Terraform ${ACTION} for ${ENVIRONMENT} environment${NC}"
echo ""

cd "$TF_DIR"

case $ACTION in
    init)
        echo -e "${YELLOW}Initializing Terraform...${NC}"
        terraform init
        ;;
    plan)
        echo -e "${YELLOW}Planning Terraform changes...${NC}"
        terraform plan
        ;;
    apply)
        echo -e "${YELLOW}Applying Terraform changes...${NC}"
        terraform plan -out=tfplan
        echo ""
        echo -e "${YELLOW}Review the plan above. Press Enter to apply or Ctrl+C to cancel${NC}"
        read
        terraform apply tfplan
        rm tfplan
        echo ""
        echo -e "${GREEN}Deployment completed!${NC}"
        terraform output
        ;;
    destroy)
        if [ "$ENVIRONMENT" == "prod" ]; then
            echo -e "${RED}WARNING: You are about to destroy PRODUCTION infrastructure!${NC}"
            echo -e "${RED}Type 'destroy-prod' to confirm:${NC}"
            read CONFIRM
            if [ "$CONFIRM" != "destroy-prod" ]; then
                echo -e "${YELLOW}Destroy cancelled${NC}"
                exit 0
            fi
        fi
        echo -e "${YELLOW}Destroying Terraform infrastructure...${NC}"
        terraform destroy
        ;;
esac

echo ""
echo -e "${GREEN}Done!${NC}"
