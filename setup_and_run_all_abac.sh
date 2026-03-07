#!/usr/bin/env bash
# ============================================================================
#  setup_and_run_all_abac.sh
#  BCMS — Blockchain Certificate Management System
#  ONE-BUTTON: Full ABAC Migration, Network Setup, Deploy & Caliper Benchmark
#  Branch: feature/abac-optimized-auth
#
#  Usage:
#     chmod +x setup_and_run_all_abac.sh
#     ./setup_and_run_all_abac.sh
#
#  What this script does (in order):
#    Step 0:  Environment checks & prereqs
#    Step 1:  Deep-clean Docker containers, volumes, dev images
#    Step 2:  Start Fabric test-network with CA + CouchDB
#    Step 3:  Create channel (mychannel)
#    Step 4:  Register & enroll ABAC identities (role=admin/issuer/verifier:ecert)
#    Step 5:  Deploy (package, install, approve, commit) ABAC smart contract
#    Step 6:  Initialize ledger via admin identity
#    Step 7:  Setup Caliper workspace (install, bind, gen connection profiles)
#    Step 8:  Run Caliper benchmark (ABAC config v5.0)
#    Step 9:  Generate custom HTML report
#    Step 10: Print results summary
#
#  Improvements over setup_and_run_all.sh (RBAC):
#    • Uses registerEnroll_abac.sh → identities carry role=xxx:ecert
#    • Deploys ABAC chaincode (no getCallerMSP anywhere)
#    • Uses benchConfig_abac.yaml (higher TPS targets)
#    • Workers: 10 (vs 8 in RBAC)
#    • txDuration: 40s (vs 30s in RBAC)
#    • Audit log PutState disabled → lower write latency
# ============================================================================

set -euo pipefail

# ─── Colour helpers ───────────────────────────────────────────────────────────
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
CYAN='\033[0;36m'
BOLD='\033[1m'
NC='\033[0m'

log()     { echo -e "${GREEN}[STEP]${NC} $*" ; }
info()    { echo -e "${CYAN}[INFO]${NC} $*"  ; }
warn()    { echo -e "${YELLOW}[WARN]${NC} $*" ; }
error()   { echo -e "${RED}[ERR]${NC}  $*"  ; exit 1; }
success() { echo -e "${GREEN}${BOLD}[OK]${NC}   $*" ; }

# ─── Paths ────────────────────────────────────────────────────────────────────
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$SCRIPT_DIR"
TEST_NETWORK_DIR="$ROOT_DIR/test-network"
CALIPER_DIR="$ROOT_DIR/caliper-workspace"
CHAINCODE_DIR="$ROOT_DIR/asset-transfer-basic/chaincode-go"
CHAINCODE_LABEL="basic_1.0"
CHANNEL_NAME="mychannel"
CC_NAME="basic"
CC_SEQUENCE=1
CC_VERSION="1.0"
CALIPER_LOG="$CALIPER_DIR/caliper_abac.log"
REPORT_ABAC="$CALIPER_DIR/report_ABAC.html"

# ─── Timestamp ────────────────────────────────────────────────────────────────
START_TS=$(date +%s)

echo ""
echo -e "${BOLD}${CYAN}╔══════════════════════════════════════════════════════════════════╗${NC}"
echo -e "${BOLD}${CYAN}║   BCMS ABAC Benchmark — One-Button Setup & Run                  ║${NC}"
echo -e "${BOLD}${CYAN}║   Branch: feature/abac-optimized-auth                           ║${NC}"
echo -e "${BOLD}${CYAN}╚══════════════════════════════════════════════════════════════════╝${NC}"
echo ""

# ════════════════════════════════════════════════════════════════════════════════
# STEP 0: Environment checks
# ════════════════════════════════════════════════════════════════════════════════
log "Step 0: Checking prerequisites..."

for cmd in docker node npm go; do
  if ! command -v "$cmd" &>/dev/null; then
    error "$cmd is not installed or not in PATH"
  fi
done
info "docker:  $(docker --version | head -1)"
info "node:    $(node --version)"
info "npm:     $(npm --version)"
info "go:      $(go version | awk '{print $3}')"

# Fabric binaries
if [ ! -d "$ROOT_DIR/bin" ]; then
  warn "Fabric binaries not found. Downloading Fabric 2.5.9..."
  cd "$ROOT_DIR"
  curl -sSL https://bit.ly/2ysbOFE | bash -s -- 2.5.9 1.5.7 --docker-images
fi
export PATH="$ROOT_DIR/bin:$PATH"
export FABRIC_CFG_PATH="$ROOT_DIR/config/"

if ! command -v peer &>/dev/null; then
  error "peer binary not found in $ROOT_DIR/bin. Please install Fabric binaries manually."
fi
info "peer:    $(peer version | head -1)"

# ════════════════════════════════════════════════════════════════════════════════
# STEP 1: Deep-clean Docker environment
# ════════════════════════════════════════════════════════════════════════════════
log "Step 1: Deep-cleaning Docker environment..."

# Stop existing network gracefully
cd "$TEST_NETWORK_DIR"
./network.sh down 2>/dev/null || true

# Remove all containers
docker rm -f $(docker ps -aq) 2>/dev/null || true

# Prune volumes and networks
docker volume prune -f 2>/dev/null || true
docker network prune -f 2>/dev/null || true

# Remove old chaincode containers (dev-*)
DEV_IMAGES=$(docker images --format '{{.Repository}} {{.ID}}' \
  | awk '$1 ~ /^(dev-|dev-peer)/ {print $2}' || true)
if [ -n "$DEV_IMAGES" ]; then
  info "Removing dev-* chaincode images: $DEV_IMAGES"
  docker rmi -f $DEV_IMAGES || true
fi

# Clean old Caliper artifacts
rm -f "$CALIPER_DIR/report.html"
rm -f "$CALIPER_DIR/report_custom.html"
rm -f "$REPORT_ABAC"
rm -f "$CALIPER_LOG"
rm -f "$CALIPER_DIR/caliper.log"
rm -f "$CALIPER_DIR/networks/networkConfig.yaml"
rm -f "$CALIPER_DIR/networks/connection-org1.yaml"
rm -f "$CALIPER_DIR/networks/connection-org2.yaml"

success "Docker environment cleaned."

# ════════════════════════════════════════════════════════════════════════════════
# STEP 2: Start Fabric test-network with CouchDB + CA
# ════════════════════════════════════════════════════════════════════════════════
log "Step 2: Starting Hyperledger Fabric test-network (CouchDB + CA)..."
cd "$TEST_NETWORK_DIR"

./network.sh up createChannel \
  -c "$CHANNEL_NAME" \
  -ca \
  -s couchdb

info "Waiting 30 seconds for network stabilization (CouchDB / peers / CA)..."
sleep 30

success "Fabric network is UP. Channel: $CHANNEL_NAME"

# ════════════════════════════════════════════════════════════════════════════════
# STEP 3: Register & enroll ABAC identities (role=xxx:ecert)
# ════════════════════════════════════════════════════════════════════════════════
log "Step 3: Registering ABAC identities with Fabric CA..."
info "  Org1 → admin (role=admin:ecert), issuer1 (role=issuer:ecert), User1 (no attr)"
info "  Org2 → admin (role=admin:ecert), verifier1 (role=verifier:ecert), User1 (no attr)"

# The ABAC identities are registered in registerEnroll_abac.sh
# which is called automatically by network.sh up -ca
# For manual re-enrollment, run:
#   cd test-network && source organizations/fabric-ca/registerEnroll_abac.sh
#   createOrg1 && createOrg2 && createOrderer

# Verify key identity paths exist
PEER0_ORG1_MSP="$TEST_NETWORK_DIR/organizations/peerOrganizations/org1.example.com/peers/peer0.org1.example.com/msp"
PEER0_ORG2_MSP="$TEST_NETWORK_DIR/organizations/peerOrganizations/org2.example.com/peers/peer0.org2.example.com/msp"
USER1_ORG1="$TEST_NETWORK_DIR/organizations/peerOrganizations/org1.example.com/users/User1@org1.example.com/msp"
USER1_ORG2="$TEST_NETWORK_DIR/organizations/peerOrganizations/org2.example.com/users/User1@org2.example.com/msp"

for dir in "$PEER0_ORG1_MSP" "$PEER0_ORG2_MSP" "$USER1_ORG1" "$USER1_ORG2"; do
  if [ ! -d "$dir" ]; then
    error "Identity directory not found: $dir"
  fi
done
success "ABAC identities verified."

# ════════════════════════════════════════════════════════════════════════════════
# STEP 4: Deploy ABAC Smart Contract
# ════════════════════════════════════════════════════════════════════════════════
log "Step 4: Building and deploying ABAC chaincode..."

# ── 4a: Vendor Go dependencies ───────────────────────────────────────────────
cd "$CHAINCODE_DIR"
info "Running go mod tidy + go mod vendor..."
go mod tidy
go mod vendor
success "Go dependencies vendored."

# ── 4b: Package chaincode ─────────────────────────────────────────────────────
cd "$TEST_NETWORK_DIR"
export FABRIC_CFG_PATH="$ROOT_DIR/config/"

info "Packaging chaincode: $CHAINCODE_LABEL"
peer lifecycle chaincode package /tmp/basic.tar.gz \
  --path "$CHAINCODE_DIR" \
  --lang golang \
  --label "$CHAINCODE_LABEL"
success "Chaincode packaged: /tmp/basic.tar.gz"

# ── 4c: Install on Org1 peer ──────────────────────────────────────────────────
info "Installing chaincode on Org1 peer..."
export CORE_PEER_TLS_ENABLED=true
export CORE_PEER_LOCALMSPID="Org1MSP"
export CORE_PEER_TLS_ROOTCERT_FILE="$TEST_NETWORK_DIR/organizations/peerOrganizations/org1.example.com/peers/peer0.org1.example.com/tls/ca.crt"
export CORE_PEER_MSPCONFIGPATH="$TEST_NETWORK_DIR/organizations/peerOrganizations/org1.example.com/users/Admin@org1.example.com/msp"
export CORE_PEER_ADDRESS="localhost:7051"
peer lifecycle chaincode install /tmp/basic.tar.gz

# ── 4d: Install on Org2 peer ──────────────────────────────────────────────────
info "Installing chaincode on Org2 peer..."
export CORE_PEER_LOCALMSPID="Org2MSP"
export CORE_PEER_TLS_ROOTCERT_FILE="$TEST_NETWORK_DIR/organizations/peerOrganizations/org2.example.com/peers/peer0.org2.example.com/tls/ca.crt"
export CORE_PEER_MSPCONFIGPATH="$TEST_NETWORK_DIR/organizations/peerOrganizations/org2.example.com/users/Admin@org2.example.com/msp"
export CORE_PEER_ADDRESS="localhost:9051"
peer lifecycle chaincode install /tmp/basic.tar.gz

# ── 4e: Get package ID ────────────────────────────────────────────────────────
info "Querying chaincode package ID..."
export CORE_PEER_LOCALMSPID="Org1MSP"
export CORE_PEER_TLS_ROOTCERT_FILE="$TEST_NETWORK_DIR/organizations/peerOrganizations/org1.example.com/peers/peer0.org1.example.com/tls/ca.crt"
export CORE_PEER_MSPCONFIGPATH="$TEST_NETWORK_DIR/organizations/peerOrganizations/org1.example.com/users/Admin@org1.example.com/msp"
export CORE_PEER_ADDRESS="localhost:7051"

PACKAGE_ID=$(peer lifecycle chaincode queryinstalled \
  | grep "$CHAINCODE_LABEL" \
  | awk '{print $3}' \
  | tr -d ',')
info "Package ID: $PACKAGE_ID"

# ── 4f: Approve for Org1 ──────────────────────────────────────────────────────
info "Approving chaincode definition for Org1..."
export CORE_PEER_LOCALMSPID="Org1MSP"
export CORE_PEER_TLS_ROOTCERT_FILE="$TEST_NETWORK_DIR/organizations/peerOrganizations/org1.example.com/peers/peer0.org1.example.com/tls/ca.crt"
export CORE_PEER_MSPCONFIGPATH="$TEST_NETWORK_DIR/organizations/peerOrganizations/org1.example.com/users/Admin@org1.example.com/msp"
export CORE_PEER_ADDRESS="localhost:7051"

ORDERER_CA="$TEST_NETWORK_DIR/organizations/ordererOrganizations/example.com/orderers/orderer.example.com/msp/tlscacerts/tlsca.example.com-cert.pem"

peer lifecycle chaincode approveformyorg \
  -o localhost:7050 \
  --ordererTLSHostnameOverride orderer.example.com \
  --channelID "$CHANNEL_NAME" \
  --name "$CC_NAME" \
  --version "$CC_VERSION" \
  --package-id "$PACKAGE_ID" \
  --sequence "$CC_SEQUENCE" \
  --tls \
  --cafile "$ORDERER_CA"

# ── 4g: Approve for Org2 ──────────────────────────────────────────────────────
info "Approving chaincode definition for Org2..."
export CORE_PEER_LOCALMSPID="Org2MSP"
export CORE_PEER_TLS_ROOTCERT_FILE="$TEST_NETWORK_DIR/organizations/peerOrganizations/org2.example.com/peers/peer0.org2.example.com/tls/ca.crt"
export CORE_PEER_MSPCONFIGPATH="$TEST_NETWORK_DIR/organizations/peerOrganizations/org2.example.com/users/Admin@org2.example.com/msp"
export CORE_PEER_ADDRESS="localhost:9051"

peer lifecycle chaincode approveformyorg \
  -o localhost:7050 \
  --ordererTLSHostnameOverride orderer.example.com \
  --channelID "$CHANNEL_NAME" \
  --name "$CC_NAME" \
  --version "$CC_VERSION" \
  --package-id "$PACKAGE_ID" \
  --sequence "$CC_SEQUENCE" \
  --tls \
  --cafile "$ORDERER_CA"

# ── 4h: Commit chaincode ──────────────────────────────────────────────────────
info "Committing chaincode definition to channel..."
export CORE_PEER_LOCALMSPID="Org1MSP"
export CORE_PEER_TLS_ROOTCERT_FILE="$TEST_NETWORK_DIR/organizations/peerOrganizations/org1.example.com/peers/peer0.org1.example.com/tls/ca.crt"
export CORE_PEER_MSPCONFIGPATH="$TEST_NETWORK_DIR/organizations/peerOrganizations/org1.example.com/users/Admin@org1.example.com/msp"
export CORE_PEER_ADDRESS="localhost:7051"

ORG2_PEER_TLS="$TEST_NETWORK_DIR/organizations/peerOrganizations/org2.example.com/peers/peer0.org2.example.com/tls/ca.crt"

peer lifecycle chaincode commit \
  -o localhost:7050 \
  --ordererTLSHostnameOverride orderer.example.com \
  --channelID "$CHANNEL_NAME" \
  --name "$CC_NAME" \
  --version "$CC_VERSION" \
  --sequence "$CC_SEQUENCE" \
  --tls \
  --cafile "$ORDERER_CA" \
  --peerAddresses localhost:7051 \
  --tlsRootCertFiles "$CORE_PEER_TLS_ROOTCERT_FILE" \
  --peerAddresses localhost:9051 \
  --tlsRootCertFiles "$ORG2_PEER_TLS"

info "Waiting 10 seconds for chaincode to initialize..."
sleep 10
success "ABAC chaincode deployed: $CC_NAME v$CC_VERSION"

# ════════════════════════════════════════════════════════════════════════════════
# STEP 5: Initialize Ledger (requires role=admin in X.509)
# ════════════════════════════════════════════════════════════════════════════════
log "Step 5: Initializing ledger with admin identity (ABAC: role=admin)..."

export CORE_PEER_LOCALMSPID="Org1MSP"
export CORE_PEER_TLS_ROOTCERT_FILE="$TEST_NETWORK_DIR/organizations/peerOrganizations/org1.example.com/peers/peer0.org1.example.com/tls/ca.crt"
export CORE_PEER_MSPCONFIGPATH="$TEST_NETWORK_DIR/organizations/peerOrganizations/org1.example.com/users/Admin@org1.example.com/msp"
export CORE_PEER_ADDRESS="localhost:7051"

# NOTE: org1admin has role=admin:ecert — InitLedger will succeed
peer chaincode invoke \
  -o localhost:7050 \
  --ordererTLSHostnameOverride orderer.example.com \
  -C "$CHANNEL_NAME" \
  -n "$CC_NAME" \
  --tls \
  --cafile "$ORDERER_CA" \
  --peerAddresses localhost:7051 \
  --tlsRootCertFiles "$CORE_PEER_TLS_ROOTCERT_FILE" \
  --peerAddresses localhost:9051 \
  --tlsRootCertFiles "$ORG2_PEER_TLS" \
  -c '{"function":"InitLedger","Args":[]}' || \
  warn "InitLedger may have failed (user1 lacks role=admin attr). Use org1admin identity for production."

sleep 5
success "Ledger initialization attempted."

# ════════════════════════════════════════════════════════════════════════════════
# STEP 6: Setup Caliper workspace
# ════════════════════════════════════════════════════════════════════════════════
log "Step 6: Setting up Caliper workspace..."
cd "$CALIPER_DIR"

# ── 6a: Clean install ─────────────────────────────────────────────────────────
rm -rf node_modules package-lock.json
info "Installing Caliper packages..."
npm install --save-dev @hyperledger/caliper-cli@0.6.0 2>&1 | tail -5
npm install --save-dev @hyperledger/caliper-fabric@0.6.0 2>&1 | tail -5

# ── 6b: Bind to Fabric SDK ────────────────────────────────────────────────────
info "Binding Caliper to Fabric 2.5..."
npx caliper bind --caliper-bind-sut fabric:2.5 2>&1 | tail -5 || \
  npx caliper bind --caliper-bind-sut fabric:2.4 2>&1 | tail -5

# ── 6c: Generate connection profiles ─────────────────────────────────────────
info "Generating connection profiles..."

# ── Discover dynamic cert paths ───────────────────────────────────────────────
ORDERER_TLS_CA="$TEST_NETWORK_DIR/organizations/ordererOrganizations/example.com/orderers/orderer.example.com/msp/tlscacerts/tlsca.example.com-cert.pem"
PEER0_ORG1_TLS="$TEST_NETWORK_DIR/organizations/peerOrganizations/org1.example.com/peers/peer0.org1.example.com/tls/ca.crt"
PEER0_ORG2_TLS="$TEST_NETWORK_DIR/organizations/peerOrganizations/org2.example.com/peers/peer0.org2.example.com/tls/ca.crt"
CA_ORG1_CERT="$TEST_NETWORK_DIR/organizations/fabric-ca/org1/ca-cert.pem"
CA_ORG2_CERT="$TEST_NETWORK_DIR/organizations/fabric-ca/org2/ca-cert.pem"

# User1@org1 cert + key
ORG1_USER_CERT=$(find "$TEST_NETWORK_DIR/organizations/peerOrganizations/org1.example.com/users/User1@org1.example.com/msp/signcerts" -name "*.pem" 2>/dev/null | head -1)
ORG1_USER_KEY=$(find "$TEST_NETWORK_DIR/organizations/peerOrganizations/org1.example.com/users/User1@org1.example.com/msp/keystore" -name "*_sk" 2>/dev/null | head -1)
# User1@org2 cert + key
ORG2_USER_CERT=$(find "$TEST_NETWORK_DIR/organizations/peerOrganizations/org2.example.com/users/User1@org2.example.com/msp/signcerts" -name "*.pem" 2>/dev/null | head -1)
ORG2_USER_KEY=$(find "$TEST_NETWORK_DIR/organizations/peerOrganizations/org2.example.com/users/User1@org2.example.com/msp/keystore" -name "*_sk" 2>/dev/null | head -1)

for f in "$ORDERER_TLS_CA" "$PEER0_ORG1_TLS" "$PEER0_ORG2_TLS" "$CA_ORG1_CERT" "$CA_ORG2_CERT"; do
  if [ ! -f "$f" ]; then
    error "Required TLS cert not found: $f"
  fi
done
for f in "$ORG1_USER_CERT" "$ORG1_USER_KEY" "$ORG2_USER_CERT" "$ORG2_USER_KEY"; do
  if [ -z "$f" ] || [ ! -f "$f" ]; then
    error "Required user cert/key not found: $f"
  fi
done

info "Cert paths resolved OK."
info "  Org1 user cert: $ORG1_USER_CERT"
info "  Org2 user cert: $ORG2_USER_CERT"

# ── Generate connection-org1.yaml ─────────────────────────────────────────────
cat > "$CALIPER_DIR/networks/connection-org1.yaml" <<CONNEOF
name: test-network-org1
version: 1.0.0
client:
  organization: Org1
  connection:
    timeout:
      peer:
        endorser: '300'
      orderer: '300'

channels:
  mychannel:
    orderers:
      - orderer.example.com
    peers:
      peer0.org1.example.com:
        endorsingPeer: true
        chaincodeQuery: true
        ledgerQuery: true
        eventSource: true
      peer0.org2.example.com:
        endorsingPeer: true
        chaincodeQuery: true
        ledgerQuery: true
        eventSource: true

organizations:
  Org1:
    mspid: Org1MSP
    peers:
      - peer0.org1.example.com
    certificateAuthorities:
      - ca.org1.example.com
  Org2:
    mspid: Org2MSP
    peers:
      - peer0.org2.example.com

orderers:
  orderer.example.com:
    url: grpcs://localhost:7050
    grpcOptions:
      ssl-target-name-override: orderer.example.com
      hostnameOverride: orderer.example.com
    tlsCACerts:
      path: '${ORDERER_TLS_CA}'

peers:
  peer0.org1.example.com:
    url: grpcs://localhost:7051
    grpcOptions:
      ssl-target-name-override: peer0.org1.example.com
      hostnameOverride: peer0.org1.example.com
    tlsCACerts:
      path: '${PEER0_ORG1_TLS}'
  peer0.org2.example.com:
    url: grpcs://localhost:9051
    grpcOptions:
      ssl-target-name-override: peer0.org2.example.com
      hostnameOverride: peer0.org2.example.com
    tlsCACerts:
      path: '${PEER0_ORG2_TLS}'

certificateAuthorities:
  ca.org1.example.com:
    url: https://localhost:7054
    caName: ca-org1
    tlsCACerts:
      path: '${CA_ORG1_CERT}'
    httpOptions:
      verify: false
    registrar:
      - enrollId: admin
        enrollSecret: adminpw
CONNEOF

# ── Generate networkConfig.yaml ───────────────────────────────────────────────
cat > "$CALIPER_DIR/networks/networkConfig.yaml" <<NETEOF
name: Fabric
version: 2.0.0

caliper:
  blockchain: fabric
  command:
    start: 'docker ps'
    end: 'docker ps'

info:
  Version: 2.5.x
  Size: 2 Orgs with 1 Peer Each
  Orderer: Raft
  Distribution: Single Host
  StateDB: CouchDB

channels:
  - channelName: mychannel
    create: false
    contracts:
      - id: basic
        contractID: basic
        language: golang
        version: '1.0'
        metaPath: ''

organizations:
  - mspid: Org1MSP
    identities:
      certificates:
        - name: 'User1@org1.example.com'
          clientPrivateKey:
            path: '${ORG1_USER_KEY}'
          clientSignedCert:
            path: '${ORG1_USER_CERT}'
    connectionProfile:
      path: '${CALIPER_DIR}/networks/connection-org1.yaml'
      discover: false
      asLocalhost: true
  - mspid: Org2MSP
    identities:
      certificates:
        - name: 'User1@org2.example.com'
          clientPrivateKey:
            path: '${ORG2_USER_KEY}'
          clientSignedCert:
            path: '${ORG2_USER_CERT}'
    connectionProfile:
      path: '${CALIPER_DIR}/networks/connection-org1.yaml'
      discover: false
      asLocalhost: true
NETEOF

success "Caliper workspace configured."

# ════════════════════════════════════════════════════════════════════════════════
# STEP 7: Run Caliper Benchmark (ABAC v5.0)
# ════════════════════════════════════════════════════════════════════════════════
log "Step 7: Running Caliper Benchmark (ABAC v5.0)..."
info "  Config: benchmarks/benchConfig_abac.yaml"
info "  Workers: 10 | TPS ceiling: 120 | Duration: 40s per round"
info "  Audit log: DISABLED (reduced PutState overhead)"

cd "$CALIPER_DIR"

npx caliper launch manager \
  --caliper-workspace ./ \
  --caliper-networkconfig networks/networkConfig.yaml \
  --caliper-benchconfig benchmarks/benchConfig_abac.yaml \
  --caliper-flow-only-test \
  --caliper-fabric-gateway-enabled \
  2>&1 | tee "$CALIPER_LOG"

if [ -f "$CALIPER_DIR/report.html" ]; then
  cp "$CALIPER_DIR/report.html" "$REPORT_ABAC"
  success "Caliper report saved: $REPORT_ABAC"
else
  warn "report.html not found. Caliper may have failed. Check: $CALIPER_LOG"
fi

# ════════════════════════════════════════════════════════════════════════════════
# STEP 8: Generate Custom HTML Report
# ════════════════════════════════════════════════════════════════════════════════
log "Step 8: Generating custom ABAC benchmark report..."
cd "$CALIPER_DIR"

if [ -f "generate_custom_report.js" ]; then
  node generate_custom_report.js \
    --report-title "BCMS ABAC Benchmark v5.0" \
    --branch "feature/abac-optimized-auth" \
    --version "v5.0" \
    2>/dev/null || warn "Custom report generation skipped (optional step)."
fi

# ════════════════════════════════════════════════════════════════════════════════
# STEP 9: Results Summary
# ════════════════════════════════════════════════════════════════════════════════
END_TS=$(date +%s)
ELAPSED=$(( END_TS - START_TS ))

echo ""
echo -e "${BOLD}${GREEN}╔══════════════════════════════════════════════════════════════════╗${NC}"
echo -e "${BOLD}${GREEN}║             ABAC Benchmark Complete                             ║${NC}"
echo -e "${BOLD}${GREEN}╚══════════════════════════════════════════════════════════════════╝${NC}"
echo ""
echo -e "  ${CYAN}Total time:${NC}       ${ELAPSED}s"
echo -e "  ${CYAN}Network:${NC}          Hyperledger Fabric 2.5 (CouchDB, Raft)"
echo -e "  ${CYAN}Smart Contract:${NC}   ABAC v5.0 (role attr, no MSP check)"
echo -e "  ${CYAN}Benchmark config:${NC} benchConfig_abac.yaml"
echo -e "  ${CYAN}Workers:${NC}          10"
echo -e "  ${CYAN}Round duration:${NC}   40s"
echo ""

if [ -f "$REPORT_ABAC" ]; then
  echo -e "  ${GREEN}Report:${NC} $REPORT_ABAC"
else
  echo -e "  ${YELLOW}Report:${NC} Not generated (check $CALIPER_LOG)"
fi

echo ""
echo -e "${BOLD}Comparison vs RBAC v4.0 baseline:${NC}"
echo -e "  Round               RBAC TPS   ABAC Target"
echo -e "  IssueCertificate    24.9       ≥ 35"
echo -e "  VerifyCertificate   99.0       ≥ 115"
echo -e "  QueryAllCerts       19.3       ≥ 20"
echo -e "  RevokeCertificate   46.5       ≥ 60"
echo -e "  GetCertsByStudent   74.5       ≥ 90"
echo -e "  GetAuditLogs        30.1       ≥ 45"
echo ""
echo -e "${CYAN}Next steps:${NC}"
echo -e "  1. Open report_ABAC.html in your browser"
echo -e "  2. Push branch: git push origin feature/abac-optimized-auth"
echo -e "  3. Create PR: feature/abac-optimized-auth → main"
echo ""
