#!/bin/bash

################################################################################
# SObject Purge Framework - deploy the optional Data 360 module
################################################################################
# Deploys force-app (Core) and data360 (Data 360 module) to an org, replacing
# the org-specific placeholders of the data360 metadata at deployment time.
# The files of the repository keep their placeholders.
#
#   1. Reads the My Domain URL and the username of the target org
#   2. Reads the Data 360 tenant host from the Ingestion API connectors
#   3. Deploys force-app and data360 with these values
#   4. Assigns the PurgeData360 permission set
#
# Usage:
#   ./scripts/deploy-data360.sh [-o <org alias or username>] [--run-as <username>] [--data360-only]
#
#   -o, --target-org   Org to deploy to. Default: the default org of the Salesforce CLI.
#   --run-as           Run-as user of the client credentials flow. Default: the user of the target org.
#   --data360-only     Deploy only the data360 folder (force-app must already be deployed).
#
# Manual step after the deployment:
#   Enter the consumer key and secret of the "Purge Data 360" external client app
#   on the default principal of the "Purge Data 360" external credential.
################################################################################

set -euo pipefail

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

TARGET_ORG=""
RUN_AS=""
DATA360_ONLY=false

while [ $# -gt 0 ]; do
	case "$1" in
		-o|--target-org) TARGET_ORG="$2"; shift 2 ;;
		--run-as) RUN_AS="$2"; shift 2 ;;
		--data360-only) DATA360_ONLY=true; shift ;;
		-h|--help) sed -n '3,25p' "$0"; exit 0 ;;
		*) echo -e "${RED}Unknown option: $1${NC}"; exit 1 ;;
	esac
done

for tool in sf jq; do
	if ! command -v "$tool" &> /dev/null; then
		echo -e "${RED}Error: $tool is not installed${NC}"
		exit 1
	fi
done

ORG_FLAG=()
if [ -n "$TARGET_ORG" ]; then
	ORG_FLAG=(--target-org "$TARGET_ORG")
fi

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR/.."

echo -e "${BLUE}Reading the target org...${NC}"
if ! ORG_INFO=$(sf org display "${ORG_FLAG[@]}" --json 2>/dev/null); then
	echo -e "${RED}Error: could not read the target org. Log in with 'sf org login web' or pass -o <alias>.${NC}"
	exit 1
fi
MY_DOMAIN_URL=$(echo "$ORG_INFO" | jq -r '.result.instanceUrl')
USERNAME=$(echo "$ORG_INFO" | jq -r '.result.username')
API_VERSION=$(jq -r '.sourceApiVersion' sfdx-project.json)
if [ -z "$RUN_AS" ]; then
	RUN_AS="$USERNAME"
fi

echo -e "${BLUE}Reading the Data 360 tenant from the Ingestion API connectors...${NC}"
TENANT_HOST=$(sf api request rest "/services/data/v$API_VERSION/ssot/connections?connectorType=IngestApi&limit=1" "${ORG_FLAG[@]}" 2>/dev/null \
	| jq -r '.connections[0].tenantSpecificEndpoint // empty' 2>/dev/null || true)
if [ -z "$TENANT_HOST" ]; then
	echo -e "${RED}Error: no Ingestion API connector found. The purge only works for Ingestion API data streams: create the connector first.${NC}"
	exit 1
fi

echo -e "${GREEN}✓ My Domain URL:  $MY_DOMAIN_URL${NC}"
echo -e "${GREEN}✓ Tenant:         https://$TENANT_HOST${NC}"
echo -e "${GREEN}✓ Run-as user:    $RUN_AS${NC}"
echo ""

export PURGE_D360_MY_DOMAIN_URL="$MY_DOMAIN_URL"
export PURGE_D360_TENANT_URL="https://$TENANT_HOST"
export PURGE_D360_RUN_AS_USERNAME="$RUN_AS"

SOURCE_DIRS=(--source-dir data360)
if [ "$DATA360_ONLY" = false ]; then
	SOURCE_DIRS=(--source-dir force-app --source-dir data360)
fi

echo -e "${BLUE}Deploying ${SOURCE_DIRS[*]}...${NC}"
sf project deploy start "${SOURCE_DIRS[@]}" "${ORG_FLAG[@]}" --wait 20

echo -e "${BLUE}Assigning the PurgeData360 permission set...${NC}"
for user in $(printf '%s\n' "$USERNAME" "$RUN_AS" | sort -u); do
	if ! sf org assign permset --name PurgeData360 --on-behalf-of "$user" "${ORG_FLAG[@]}" > /dev/null 2>&1; then
		echo -e "${YELLOW}⚠️  Could not assign PurgeData360 to $user (it may already be assigned).${NC}"
	else
		echo -e "${GREEN}✓ PurgeData360 assigned to $user${NC}"
	fi
done

echo ""
echo -e "${GREEN}✅ Deployment complete${NC}"
echo ""
echo -e "${YELLOW}Manual step remaining:${NC}"
echo "  1. Setup → External Client App Manager → Purge Data 360 → Settings → OAuth Settings → Consumer Key and Secret"
echo "  2. Setup → Named Credentials → External Credentials → Purge Data 360 → Principals → default → Edit"
echo "     Enter the consumer key as Client ID and the consumer secret as Client Secret, then save."
