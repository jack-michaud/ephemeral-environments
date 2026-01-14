#!/bin/bash
# Setup GitHub App for Ephemeral Environments
# This script guides you through creating a GitHub App with minimal permissions

set -e

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

echo -e "${GREEN}=== Ephemeral Environments: GitHub App Setup ===${NC}"
echo ""

# Generate webhook secret
WEBHOOK_SECRET=$(openssl rand -hex 32)

echo -e "${YELLOW}Follow these steps to create your GitHub App:${NC}"
echo ""
echo -e "${BLUE}1. Go to: https://github.com/settings/apps/new${NC}"
echo "   (Or for an org: https://github.com/organizations/YOUR_ORG/settings/apps/new)"
echo ""
echo -e "${BLUE}2. Fill in the basic info:${NC}"
echo "   ┌─────────────────────────────────────────────────────────────┐"
echo "   │ GitHub App name: ephemeral-environments                     │"
echo "   │ Homepage URL: https://github.com/your-org/ephemeral-envs    │"
echo "   │ Description: Deploys ephemeral environments for PRs         │"
echo "   └─────────────────────────────────────────────────────────────┘"
echo ""
echo -e "${BLUE}3. Webhook configuration:${NC}"
echo "   ┌─────────────────────────────────────────────────────────────┐"
echo "   │ Webhook URL: (leave empty for now, update after deploying)  │"
echo "   │ Webhook secret: ${WEBHOOK_SECRET}                           │"
echo "   └─────────────────────────────────────────────────────────────┘"
echo ""
echo -e "${BLUE}4. Repository permissions (minimal):${NC}"
echo "   ┌─────────────────────────────────────────────────────────────┐"
echo "   │ Contents: Read-only          (to clone repos)               │"
echo "   │ Commit statuses: Read & write (to post status checks)       │"
echo "   │ Pull requests: Read & write   (to post comments)            │"
echo "   └─────────────────────────────────────────────────────────────┘"
echo ""
echo -e "${BLUE}5. Subscribe to events:${NC}"
echo "   ┌─────────────────────────────────────────────────────────────┐"
echo "   │ [x] Pull request                                            │"
echo "   └─────────────────────────────────────────────────────────────┘"
echo ""
echo -e "${BLUE}6. Where can this GitHub App be installed?${NC}"
echo "   ┌─────────────────────────────────────────────────────────────┐"
echo "   │ (*) Only on this account                                    │"
echo "   │    (or 'Any account' if you want others to install)         │"
echo "   └─────────────────────────────────────────────────────────────┘"
echo ""
echo -e "${BLUE}7. Click 'Create GitHub App'${NC}"
echo ""
echo -e "${BLUE}8. After creation, note the App ID shown at the top${NC}"
echo ""
echo -e "${BLUE}9. Scroll down to 'Private keys' and click 'Generate a private key'${NC}"
echo "   Save the .pem file as ./github-app.pem"
echo ""
echo -e "${BLUE}10. Go to 'Install App' in the sidebar and install on your repos${NC}"
echo ""

# Wait for user
echo ""
read -p "Press Enter when you've completed the steps above..."
echo ""

# Prompt for App ID
echo -e "${YELLOW}Enter your GitHub App ID:${NC}"
read GITHUB_APP_ID
echo ""

# Check for private key
if [ ! -f "./github-app.pem" ]; then
    echo -e "${YELLOW}Where did you save the private key? (default: ./github-app.pem)${NC}"
    read PRIVATE_KEY_PATH
    PRIVATE_KEY_PATH=${PRIVATE_KEY_PATH:-./github-app.pem}
else
    PRIVATE_KEY_PATH="./github-app.pem"
fi

if [ ! -f "$PRIVATE_KEY_PATH" ]; then
    echo -e "${RED}Warning: Private key file not found at ${PRIVATE_KEY_PATH}${NC}"
    echo "Make sure to save the .pem file before deploying."
fi

echo ""
echo -e "${GREEN}=== SUCCESS ===${NC}"
echo ""
echo -e "${YELLOW}Add these to your .env file:${NC}"
echo ""
echo "GITHUB_APP_ID=${GITHUB_APP_ID}"
echo "GITHUB_APP_PRIVATE_KEY_PATH=${PRIVATE_KEY_PATH}"
echo "GITHUB_WEBHOOK_SECRET=${WEBHOOK_SECRET}"
echo ""
echo -e "${YELLOW}Permissions granted:${NC}"
echo "  - Contents: Read (clone repositories)"
echo "  - Commit statuses: Write (post status checks)"
echo "  - Pull requests: Write (post comments)"
echo ""
echo -e "${YELLOW}Next steps:${NC}"
echo "  1. Save the private key as ./github-app.pem"
echo "  2. After deploying, update the webhook URL in GitHub App settings"
echo "  3. Install the app on repositories you want to use"
echo ""
