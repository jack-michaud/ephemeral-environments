#!/bin/bash
# Setup Cloudflare API token with minimal permissions for Ephemeral Environments
# This script guides you through creating a token with only required permissions

set -e

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

echo -e "${GREEN}=== Ephemeral Environments: Cloudflare Token Setup ===${NC}"
echo ""

# Prompt for account ID first
echo -e "${YELLOW}Enter your Cloudflare Account ID:${NC}"
echo -e "${BLUE}(Find it at: https://dash.cloudflare.com → select account → URL contains account ID)${NC}"
read CLOUDFLARE_ACCOUNT_ID
echo ""

if [ -z "$CLOUDFLARE_ACCOUNT_ID" ]; then
    echo -e "${RED}Error: Account ID is required${NC}"
    exit 1
fi

echo -e "${YELLOW}To create an API token with minimal permissions:${NC}"
echo ""
echo -e "${BLUE}1. Go to: https://dash.cloudflare.com/profile/api-tokens${NC}"
echo ""
echo -e "${BLUE}2. Click 'Create Token'${NC}"
echo ""
echo -e "${BLUE}3. Select 'Create Custom Token'${NC}"
echo ""
echo -e "${BLUE}4. Configure with these permissions:${NC}"
echo ""
echo "   Token Name: ephemeral-environments"
echo ""
echo "   Permissions (Account level):"
echo "   ┌─────────────────────────────────────────────────────────────┐"
echo "   │ Access: Organizations, Identity Providers, and Groups: Edit │"
echo "   │ Access: Apps and Policies: Edit                             │"
echo "   │ Cloudflare Tunnel: Edit                                     │"
echo "   └─────────────────────────────────────────────────────────────┘"
echo ""
echo "   Permissions (Zone level - for DNS records):"
echo "   ┌─────────────────────────────────────────────────────────────┐"
echo "   │ Zone: DNS: Edit                                             │"
echo "   └─────────────────────────────────────────────────────────────┘"
echo ""
echo "   Account Resources:"
echo "   ┌─────────────────────────────────────────────────────────────┐"
echo "   │ Include: Your Account                                       │"
echo "   └─────────────────────────────────────────────────────────────┘"
echo ""
echo "   Zone Resources:"
echo "   ┌─────────────────────────────────────────────────────────────┐"
echo "   │ Include: Specific Zone (your domain for tunnel DNS)         │"
echo "   └─────────────────────────────────────────────────────────────┘"
echo ""
echo -e "${BLUE}5. Click 'Continue to Summary' then 'Create Token'${NC}"
echo ""
echo -e "${BLUE}6. Copy the token (you won't see it again!)${NC}"
echo ""

# Prompt for token
echo -e "${YELLOW}Enter your new Cloudflare API token:${NC}"
read -s CLOUDFLARE_API_TOKEN
echo ""

# Validate token using account-level endpoint
echo -e "${GREEN}Validating token for account ${CLOUDFLARE_ACCOUNT_ID}...${NC}"
VERIFY=$(curl -s -X GET "https://api.cloudflare.com/client/v4/accounts/${CLOUDFLARE_ACCOUNT_ID}/tokens/verify" \
    -H "Authorization: Bearer $CLOUDFLARE_API_TOKEN" \
    -H "Content-Type: application/json")

if ! echo "$VERIFY" | grep -q '"success":true'; then
    echo -e "${RED}Error: Invalid token or account ID${NC}"
    echo "$VERIFY"
    exit 1
fi

echo -e "${GREEN}Token is valid!${NC}"

echo ""
echo -e "${GREEN}=== SUCCESS ===${NC}"
echo ""
echo -e "${YELLOW}Add these to your .env file:${NC}"
echo ""
echo "CLOUDFLARE_API_TOKEN=${CLOUDFLARE_API_TOKEN}"
echo "CLOUDFLARE_ACCOUNT_ID=${CLOUDFLARE_ACCOUNT_ID}"
echo ""
echo -e "${YELLOW}Permissions granted:${NC}"
echo "  - Cloudflare Tunnel: Create/delete tunnels"
echo "  - Access: Create/manage applications and policies"
echo "  - Zone DNS: Create/delete DNS records for tunnel hostnames"
echo ""
