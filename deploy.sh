#!/bin/bash
# ============================================================================
#  BCMS — Complete Network Deployment Script
#  Blockchain Certificate Management System
#  Research Paper: "Enhancing Trust and Transparency in Education Using
#                   Blockchain: A Hyperledger Fabric-Based Framework"
#
#  This script performs end-to-end setup:
#    1. Environment validation (Docker, Go, Node.js, Fabric binaries)
#    2. Hyperledger Fabric v2.5 network startup (2 orgs, 2 peers, Raft orderer)
#    3. Channel creation (mychannel)
#    4. Chaincode packaging, installation, approval, and commit
#    5. Chaincode initialization (InitLedger)
#    6. REST API setup
#    7. Caliper benchmark preparation
#    8. Prometheus + Grafana monitoring setup
#
#  Usage:
#    chmod +x deploy.sh
#    ./deploy.sh [--skip-network] [--skip-chaincode] [--only-bench]
#
#  Options:
#    --skip-network    Skip network startup (network already running)
#    --skip-chaincode  Skip chaincode deployment (chaincode already deployed)
#    --only-bench      Only run Caliper benchmark (network must be running)
# ============================================================================

set -euo pipefail

# ── Color Output ─────────────────────────────────────────────────────────────
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
BOLD='\033[1m'
NC='\033[0m' # No Color

# ── Script Location ───────────────────────────────────────────────────────────
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$SCRIPT_DIR"
TEST_NETWORK_DIR="$ROOT_DIR/test-network"
CHAINCODE_DIR="$ROOT_DIR/asset-transfer-basic/chaincode-go"
CALIPER_DIR="$ROOT_DIR/caliper-workspace"
API_DIR="$ROOT_DIR/bcms-api"

# ── Parse Arguments ───────────────────────────────────────────────────────────
SKIP_NETWORK=false
SKIP_CHAINCODE=false
ONLY_BENCH=false

for arg in "$@"; do
    case $arg in
        --skip-network)   SKIP_NETWORK=true ;;
        --skip-chaincode) SKIP_CHAINCODE=true ;;
        --only-bench)     ONLY_BENCH=true; SKIP_NETWORK=true; SKIP_CHAINCODE=true ;;
        --help)
            echo "Usage: $0 [--skip-network] [--skip-chaincode] [--only-bench]"
            exit 0
            ;;
    esac
done

# ── Banner ────────────────────────────────────────────────────────────────────
echo -e "${BOLD}${BLUE}"
echo "╔══════════════════════════════════════════════════════════════════════════╗"
echo "║       BCMS — Blockchain Certificate Management System                    ║"
echo "║       Hyperledger Fabric v2.5 — Full Deployment Script                  ║"
echo "║       Research Paper Implementation                                      ║"
echo "╚══════════════════════════════════════════════════════════════════════════╝"
echo -e "${NC}"

log_info()    { echo -e "${GREEN}[INFO]${NC}  $1"; }
log_warn()    { echo -e "${YELLOW}[WARN]${NC}  $1"; }
log_error()   { echo -e "${RED}[ERROR]${NC} $1"; }
log_step()    { echo -e "\n${CYAN}${BOLD}══ STEP: $1 ══${NC}"; }

# ── Step 1: Environment Validation ───────────────────────────────────────────
log_step "Environment Validation"

check_command() {
    if ! command -v "$1" &>/dev/null; then
        log_error "Required command not found: $1"
        log_error "Please install $1 and try again."
        exit 1
    fi
    log_info "✓ Found: $1 ($(command -v $1))"
}

check_command docker
check_command docker-compose || check_command "docker compose"
check_command node
check_command npm
check_command go

# Check Docker is running
if ! docker info &>/dev/null; then
    log_error "Docker daemon is not running. Please start Docker."
    exit 1
fi
log_info "✓ Docker daemon is running"

# Check fabric binaries exist in test-network
FABRIC_BIN_PATH="$HOME/fabric-samples/bin"
if [ -d "$FABRIC_BIN_PATH" ]; then
    export PATH="$FABRIC_BIN_PATH:$PATH"
    log_info "✓ Fabric binaries found at $FABRIC_BIN_PATH"
elif command -v peer &>/dev/null; then
    log_info "✓ Fabric binaries found in PATH"
else
    log_warn "Fabric binaries not found in PATH or ~/fabric-samples/bin"
    log_warn "The network.sh script may use its own binaries"
fi

log_info "Environment validation passed!"

# ── Step 2: Network Startup ───────────────────────────────────────────────────
if [ "$SKIP_NETWORK" = false ]; then
    log_step "Starting Hyperledger Fabric v2.5 Network"

    if [ ! -d "$TEST_NETWORK_DIR" ]; then
        log_error "test-network directory not found at: $TEST_NETWORK_DIR"
        exit 1
    fi

    cd "$TEST_NETWORK_DIR"

    # Stop any existing network
    log_info "Stopping any existing network..."
    ./network.sh down 2>/dev/null || true
    docker volume prune -f 2>/dev/null || true

    # Start network with CA and CouchDB for rich queries
    log_info "Starting network with 2 orgs, CouchDB, and CA..."
    ./network.sh up createChannel -c mychannel -ca -s couchdb

    log_info "✓ Fabric network started successfully"
    log_info "  - Org1 peer: peer0.org1.example.com:7051"
    log_info "  - Org2 peer: peer0.org2.example.com:9051"
    log_info "  - Orderer:   orderer.example.com:7050"
    log_info "  - Channel:   mychannel"
    log_info "  - CA Org1:   ca.org1.example.com:7054"
    log_info "  - CA Org2:   ca.org2.example.com:8054"

    # Wait for network to stabilize
    log_info "Waiting 10s for network stabilization..."
    sleep 10

    cd "$ROOT_DIR"
fi

# ── Step 3: Chaincode Deployment ──────────────────────────────────────────────
if [ "$SKIP_CHAINCODE" = false ]; then
    log_step "Deploying BCMS Chaincode"

    cd "$TEST_NETWORK_DIR"

    # Verify Go chaincode compiles
    log_info "Verifying Go chaincode compilation..."
    cd "$CHAINCODE_DIR"
    if go build ./...; then
        log_info "✓ Go chaincode compiles successfully"
    else
        log_error "Chaincode compilation failed!"
        exit 1
    fi
    cd "$TEST_NETWORK_DIR"

    # Deploy chaincode with endorsement policy
    log_info "Deploying chaincode 'basic' on mychannel..."
    log_info "Endorsement policy: OR('Org1MSP.peer','Org2MSP.peer')"

    ./network.sh deployCC \
        -ccn basic \
        -ccp ../asset-transfer-basic/chaincode-go \
        -ccl go \
        -c mychannel \
        -ccep "OR('Org1MSP.peer','Org2MSP.peer')"

    log_info "✓ Chaincode 'basic' deployed successfully"

    # Initialize ledger with sample data
    log_info "Initializing ledger with seed data..."

    # Set environment for Org1
    export CORE_PEER_TLS_ENABLED=true
    export CORE_PEER_LOCALMSPID="Org1MSP"
    export CORE_PEER_TLS_ROOTCERT_FILE="$TEST_NETWORK_DIR/organizations/peerOrganizations/org1.example.com/peers/peer0.org1.example.com/tls/ca.crt"
    export CORE_PEER_MSPCONFIGPATH="$TEST_NETWORK_DIR/organizations/peerOrganizations/org1.example.com/users/Admin@org1.example.com/msp"
    export CORE_PEER_ADDRESS=localhost:7051

    export ORDERER_CA="$TEST_NETWORK_DIR/organizations/ordererOrganizations/example.com/orderers/orderer.example.com/msp/tlscacerts/tlsca.example.com-cert.pem"

    peer chaincode invoke \
        -o localhost:7050 \
        --ordererTLSHostnameOverride orderer.example.com \
        --tls \
        --cafile "$ORDERER_CA" \
        -C mychannel \
        -n basic \
        --peerAddresses localhost:7051 \
        --tlsRootCertFiles "$TEST_NETWORK_DIR/organizations/peerOrganizations/org1.example.com/peers/peer0.org1.example.com/tls/ca.crt" \
        --peerAddresses localhost:9051 \
        --tlsRootCertFiles "$TEST_NETWORK_DIR/organizations/peerOrganizations/org2.example.com/peers/peer0.org2.example.com/tls/ca.crt" \
        -c '{"function":"InitLedger","Args":[]}' \
        --waitForEvent

    log_info "✓ Ledger initialized with seed data"

    cd "$ROOT_DIR"
fi

# ── Step 4: REST API Setup ────────────────────────────────────────────────────
log_step "Setting Up REST API"

if [ -d "$API_DIR" ]; then
    cd "$API_DIR"

    if [ ! -f ".env" ]; then
        cp .env.example .env 2>/dev/null || cat > .env << 'ENV_EOF'
PORT=3000
LOG_LEVEL=info
CORS_ORIGIN=*
FABRIC_PATH=../test-network
CHANNEL_NAME=mychannel
CHAINCODE_NAME=basic
PEER_ENDPOINT_ORG1=localhost:7051
PEER_ENDPOINT_ORG2=localhost:9051
ENV_EOF
        log_info "Created .env configuration"
    fi

    log_info "Installing REST API dependencies..."
    npm install --silent 2>/dev/null || npm install

    log_info "✓ REST API dependencies installed"
    log_info "  Start with: cd bcms-api && npm start"
    log_info "  API base:   http://localhost:3000/api/v1"

    cd "$ROOT_DIR"
fi

# ── Step 5: Caliper Benchmark Setup ──────────────────────────────────────────
log_step "Setting Up Caliper Benchmarks"

if [ -d "$CALIPER_DIR" ]; then
    cd "$CALIPER_DIR"

    log_info "Installing Caliper dependencies..."
    npm install --silent 2>/dev/null || npm install

    log_info "Binding Caliper to Fabric v2.5..."
    npx caliper bind --caliper-bind-sut fabric:2.5 --caliper-bind-args=-g 2>&1 | tail -5

    log_info "✓ Caliper benchmark setup complete"
    log_info "  Run with: cd caliper-workspace && ./fix_and_run_caliper.sh"

    cd "$ROOT_DIR"
fi

# ── Step 6: Monitoring Setup ──────────────────────────────────────────────────
log_step "Checking Monitoring Setup"

PROMETHEUS_DIR="$TEST_NETWORK_DIR/prometheus-grafana"
if [ -d "$PROMETHEUS_DIR" ]; then
    log_info "Prometheus/Grafana configuration found at: $PROMETHEUS_DIR"
    log_info "  Start monitoring: cd test-network/prometheus-grafana && docker-compose up -d"
    log_info "  Grafana dashboard: http://localhost:3001 (admin/admin)"
    log_info "  Prometheus:        http://localhost:9090"
else
    log_warn "Prometheus/Grafana directory not found. Creating basic config..."
    mkdir -p "$TEST_NETWORK_DIR/prometheus-grafana"
    # Config will be created by setup_monitoring.sh
fi

# ── Step 7: Run Benchmark (if --only-bench or requested) ─────────────────────
if [ "$ONLY_BENCH" = true ]; then
    log_step "Running Caliper Benchmark"
    cd "$CALIPER_DIR"
    ./fix_and_run_caliper.sh
    cd "$ROOT_DIR"
fi

# ── Summary ───────────────────────────────────────────────────────────────────
echo ""
echo -e "${BOLD}${GREEN}"
echo "╔══════════════════════════════════════════════════════════════════════════╗"
echo "║                    DEPLOYMENT COMPLETE                                   ║"
echo "╚══════════════════════════════════════════════════════════════════════════╝"
echo -e "${NC}"

echo -e "${BOLD}Network Status:${NC}"
docker ps --filter "network=fabric_test" --format "  {{.Names}}: {{.Status}}" 2>/dev/null || true

echo ""
echo -e "${BOLD}Quick Commands:${NC}"
echo "  Test chaincode (Org1 — IssueCertificate):"
echo "    cd test-network && source setOrgEnv.sh 1"
echo "    peer chaincode invoke -o localhost:7050 --ordererTLSHostnameOverride orderer.example.com --tls --cafile \$ORDERER_CA -C mychannel -n basic -c '{\"function\":\"IssueCertificate\",\"Args\":[\"CERT100\",\"STU100\",\"Test Student\",\"BSc Computer Science\",\"Test University\",\"2025-01-01\",\"\",\"\"]}'"
echo ""
echo "  Test chaincode (Org2 — RevokeCertificate):"
echo "    cd test-network && source setOrgEnv.sh 2"
echo "    peer chaincode invoke -o localhost:7050 ... -c '{\"function\":\"RevokeCertificate\",\"Args\":[\"CERT100\"]}'"
echo ""
echo "  Start REST API:"
echo "    cd bcms-api && npm start"
echo "    curl http://localhost:3000/api/v1/health"
echo ""
echo "  Run Caliper Benchmark:"
echo "    cd caliper-workspace && ./fix_and_run_caliper.sh"
echo ""
echo "  Stop network:"
echo "    cd test-network && ./network.sh down"
echo ""

log_info "For detailed instructions, see: EXECUTION_GUIDE.md"
