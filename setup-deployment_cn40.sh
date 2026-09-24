#!/bin/bash
###############################################################################
# CN40 DEPLOYMENT SCRIPT
#
# Fixed configuration for cn40 environment:
#   CF API:    https://api.cf.cn40.platform.sapcloud.cn
#   Org:       poc_env
#   Space:     hc96
#   Domain:    innolab.oncloud.top
#   HANA DB:   f58e5b09-2841-49cf-93a6-790629c1915c
#
# No AI Core service in this space — uses AICORE_SERVICE_KEY env var instead.
#
# Usage:
#   ./setup-deployment_cn40.sh            # Config files only
#   ./setup-deployment_cn40.sh --deploy   # Full deployment
###############################################################################

set -e

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
MTAEXT_OUTPUT="$SCRIPT_DIR/my-deployment.mtaext"
WEBAPP_CONFIG="$SCRIPT_DIR/app/webapp/config.js"
MTAR_FILE="$SCRIPT_DIR/mta_archives/genai-hana-rag_1.0.0.mtar"

# ── CN40 Fixed Values ────────────────────────────────────────────────────────
CF_API="https://api.cf.cn40.platform.sapcloud.cn"
CF_ORG="poc_env"
CF_SPACE="hc96"
DOMAIN="innolab.oncloud.top"
DATABASE_ID="f58e5b09-2841-49cf-93a6-790629c1915c"

# Namespace prefix used in CF app names and routes
# Default: poc-env-hc96  (matches what cf deploy generates automatically)
NAMESPACE="poc-env-hc96"

SRV_ROUTE="${NAMESPACE}-genai-hana-rag-srv.${DOMAIN}"
APP_ROUTE="${NAMESPACE}-genai-hana-rag-app.${DOMAIN}"
SRV_APP="genai-hana-rag-srv"

# ── AI Core credentials (eu10, shared) ───────────────────────────────────────
# No AI Core service exists in this space.
# Credentials are injected via AICORE_SERVICE_KEY environment variable.
# Fill in your AI Core credentials before running --deploy
# Get these from: cf env <eu10-srv-app> | grep -A 30 '"aicore"'
AICORE_SERVICE_KEY='{"clientid":"<YOUR_CLIENTID>","clientsecret":"<YOUR_CLIENTSECRET>","url":"<YOUR_AUTH_URL>","serviceurls":{"AI_API_URL":"<YOUR_AI_API_URL>"}}'
# ─────────────────────────────────────────────────────────────────────────────

print_header() {
    echo -e "${BLUE}"
    echo "╔══════════════════════════════════════════════════════════════════╗"
    echo "║          SAP CAP RAG - CN40 Deployment                           ║"
    echo "╚══════════════════════════════════════════════════════════════════╝"
    echo -e "${NC}"
}

generate_mtaext() {
    echo -e "${BLUE}Generating MTA extension file...${NC}"
    cat > "$MTAEXT_OUTPUT" << EOF
###############################################################################
# AUTO-GENERATED MTA Extension File for CN40
# Generated on: $(date)
#
# Deploy command:
#   cf deploy mta_archives/genai-hana-rag_1.0.0.mtar -e my-deployment.mtaext
###############################################################################

_schema-version: "3.1"
ID: genai-hana-rag
extends: genai-hana-rag

modules:
  - name: genai-hana-rag-srv
    parameters:
      routes:
        - route: ${SRV_ROUTE}

  - name: genai-hana-rag-app
    parameters:
      routes:
        - route: ${APP_ROUTE}

resources:
  - name: hana-hdi-rag
    parameters:
      config:
        database_id: ${DATABASE_ID}

  # No AI Core service in this space - disabled, using AICORE_SERVICE_KEY instead
  - name: aicore
    active: false
EOF
    echo -e "${GREEN}Created: $MTAEXT_OUTPUT${NC}"
}

update_webapp_config() {
    echo -e "${BLUE}Updating webapp config.js...${NC}"
    cat > "$WEBAPP_CONFIG" << EOF
window.RAG_CONFIG = {
    // API base URL - points to the srv app
    // Auto-generated for CN40
    // Generated on: $(date)
    apiBaseUrl: "https://${SRV_ROUTE}"
};
EOF
    echo -e "${GREEN}Updated: $WEBAPP_CONFIG${NC}"
}

build_app() {
    echo -e "${BLUE}Building application...${NC}"
    cd "$SCRIPT_DIR"
    mbt build
    echo -e "${GREEN}Build complete: $MTAR_FILE${NC}"
}

deploy_app() {
    echo -e "${BLUE}Switching to CN40 org/space...${NC}"
    cf target -o "$CF_ORG" -s "$CF_SPACE"
    echo -e "${BLUE}Deploying to CN40...${NC}"
    cf deploy "$MTAR_FILE" -e "$MTAEXT_OUTPUT"
    echo -e "${GREEN}Deployment complete${NC}"
}

set_aicore_env() {
    echo -e "${BLUE}Setting AICORE_SERVICE_KEY on ${SRV_APP}...${NC}"
    cf set-env "$SRV_APP" AICORE_SERVICE_KEY "$AICORE_SERVICE_KEY"
    cf restart "$SRV_APP"
    echo -e "${GREEN}AICORE_SERVICE_KEY set and app restarted${NC}"
}

print_summary() {
    echo ""
    echo -e "${GREEN}╔══════════════════════════════════════════════════════════════════╗${NC}"
    echo -e "${GREEN}║                    CN40 Configuration Ready                      ║${NC}"
    echo -e "${GREEN}╚══════════════════════════════════════════════════════════════════╝${NC}"
    echo ""
    echo -e "${YELLOW}Environment:${NC}"
    echo "  CF API:      $CF_API"
    echo "  Org/Space:   $CF_ORG / $CF_SPACE"
    echo "  Domain:      $DOMAIN"
    echo "  Database ID: $DATABASE_ID"
    echo ""
    echo -e "${YELLOW}URLs:${NC}"
    echo -e "  App: ${GREEN}https://${APP_ROUTE}${NC}"
    echo -e "  API: ${GREEN}https://${SRV_ROUTE}${NC}"
    echo ""
    echo -e "${YELLOW}Next steps (manual deploy):${NC}"
    echo -e "  ${BLUE}mbt build${NC}"
    echo -e "  ${BLUE}cf deploy mta_archives/genai-hana-rag_1.0.0.mtar -e my-deployment.mtaext${NC}"
    echo -e "  ${BLUE}cf set-env genai-hana-rag-srv AICORE_SERVICE_KEY '...'${NC}"
    echo -e "  ${BLUE}cf restart genai-hana-rag-srv${NC}"
    echo ""
}

print_deploy_complete() {
    echo ""
    echo -e "${GREEN}╔══════════════════════════════════════════════════════════════════╗${NC}"
    echo -e "${GREEN}║                    CN40 Deployment Complete!                     ║${NC}"
    echo -e "${GREEN}╚══════════════════════════════════════════════════════════════════╝${NC}"
    echo ""
    echo -e "${YELLOW}Your Application URLs:${NC}"
    echo -e "  App: ${GREEN}https://${APP_ROUTE}${NC}"
    echo -e "  API: ${GREEN}https://${SRV_ROUTE}${NC}"
    echo ""
}

main() {
    print_header

    local DO_DEPLOY=false
    if [[ "${1:-}" == "--deploy" ]] || [[ "${1:-}" == "-d" ]]; then
        DO_DEPLOY=true
    fi

    generate_mtaext
    update_webapp_config
    print_summary

    if [[ "$DO_DEPLOY" == true ]]; then
        build_app
        deploy_app
        set_aicore_env
        print_deploy_complete
    fi
}

main "$@"
