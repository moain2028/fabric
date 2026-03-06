#!/bin/bash
set -e

# ============================================================
# setup_and_run_all.sh — Full End-to-End: Fabric Network + Caliper Benchmark
#
# FIXES APPLIED:
#   1. Always delete old report.html BEFORE running benchmark (exposes failures)
#   2. Dynamic private key detection (find *_sk, not hardcoded)
#   3. Dynamic certificate path detection (cert.pem vs User1@org-cert.pem)
#   4. Correct Caliper bind version: fabric:2.5 (not 2.2) to match network
#   5. Generate proper connection profiles with orderer + both peers
#   6. Use --caliper-fabric-gateway-enabled for Fabric 2.5 compatibility
#   7. Always re-install and re-bind Caliper (no stale node_modules)
#   8. Post-benchmark verification that report.html was actually generated
# ============================================================

# Auto-detect ROOT_DIR from script location
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$SCRIPT_DIR"

# Permission fix for CI environments
if [ "${CI:-}" = "true" ] || [ "${CI:-}" = "1" ] || [ -n "${GITHUB_ACTIONS:-}" ] || [ "${FIX_PERMISSIONS:-}" = "true" ]; then
  if [ -x "./scripts/fix-permissions.sh" ]; then
    echo "Running scripts/fix-permissions.sh to fix permissions (CI or FIX_PERMISSIONS set)..."
    ./scripts/fix-permissions.sh || true
  else
    echo "scripts/fix-permissions.sh not found or not executable. Skipping."
  fi
else
  echo "Not in CI and FIX_PERMISSIONS not set; skipping permission fix."
fi

# Clean up Docker containers and volumes
docker rm -f $(docker ps -aq) 2>/dev/null || true
docker volume prune -f 2>/dev/null || true

# Deep Clean: remove dev-* Docker images (chaincode containers)
echo ""
echo "Performing deep-clean for Docker images starting with dev-*..."
DEV_IMAGE_IDS=$(docker images --format '{{.Repository}} {{.ID}}' | awk '$1 ~ /^(dev-|dev-peer)/ {print $2}' || true)
if [ -n "$DEV_IMAGE_IDS" ]; then
  echo "Found dev images: $DEV_IMAGE_IDS"
  docker rmi -f $DEV_IMAGE_IDS || true
else
  echo "No dev-* images found."
fi

# ============================================================
# FIX #1: ALWAYS delete old report BEFORE benchmark
# This is THE critical fix — without this, old report persists
# when Caliper crashes silently, giving the illusion that
# "the same old report keeps showing up"
# ============================================================
echo ""
echo "=== FIX #1: Removing old report.html to expose failures ==="
rm -f caliper-workspace/report.html
rm -f caliper-workspace/report_custom.html
rm -f caliper-workspace/caliper.log
rm -rf caliper-workspace/networks/networkConfig.yaml
rm -rf caliper-workspace/networks/connection-org1.yaml
rm -rf caliper-workspace/networks/connection-org2.yaml

# Define colors
GREEN='\033[0;32m'
RED='\033[0;31m'
NC='\033[0m'

echo -e "${GREEN}Starting Full Project Setup (Fabric + Caliper)...${NC}"
echo "=================================================="
echo "Smart Contract Functions:"
echo "   1. IssueCertificate     (Org1 Only)   - Issue certificate"
echo "   2. VerifyCertificate    (Public Read) - Verify certificate"
echo "   3. QueryAllCertificates (Public Read) - Query all certificates"
echo "   4. RevokeCertificate    (Org2 Auth)   - Revoke certificate"
echo "   5. CertificateExists    (Helper)      - Check existence"
echo "=================================================="

# Step 1: Check/Download Fabric Binaries
echo -e "${GREEN}Step 1: Checking Fabric Binaries...${NC}"
if [ ! -d "bin" ]; then
  echo "Downloading Fabric tools..."
  curl -sSL https://bit.ly/2ysbOFE | bash -s -- 2.5.9 1.5.7
else
  echo "Fabric tools found."
fi

export PATH=${PWD}/bin:$PATH
export FABRIC_CFG_PATH=${PWD}/config/

# Step 2: Start Test Network
echo -e "${GREEN}Step 2: Starting Test Network...${NC}"
cd test-network
./network.sh down
docker volume prune -f 2>/dev/null || true
docker system prune -f 2>/dev/null || true
./network.sh up createChannel -c mychannel -ca -s couchdb

# Wait for CouchDB and Peers to stabilize
echo "Waiting 30 seconds for CouchDB and Peers to stabilize..."
sleep 30
cd ..

# Step 3: Deploy Smart Contract
echo -e "${GREEN}Step 3: Deploying Smart Contract...${NC}"
echo "   Functions: IssueCertificate | VerifyCertificate | QueryAllCertificates | RevokeCertificate | CertificateExists"
cd test-network
./network.sh deployCC -ccn basic -ccp ../asset-transfer-basic/chaincode-go -ccl go -ccep "OR('Org1MSP.peer','Org2MSP.peer')"
cd ..

# Additional wait after chaincode deployment
echo "Waiting 15 seconds for chaincode containers to stabilize..."
sleep 15

# Step 4: Run Caliper Benchmark
echo -e "${GREEN}Step 4: Running Caliper Benchmark...${NC}"
cd caliper-workspace

# ============================================================
# FIX #3: Always re-install and re-bind to correct version
# Old code only installed once and used wrong bind version
# ============================================================
echo "Installing Caliper dependencies (clean install)..."
rm -rf node_modules package-lock.json
npm install

echo "=== FIX #3: Binding Caliper to fabric:2.5 (matches network 2.5.9) ==="
npx caliper bind --caliper-bind-sut fabric:2.5 --caliper-bind-args=-g

# ============================================================
# FIX #2: Dynamic private key and certificate detection
# ============================================================
echo "Detecting Private Keys dynamically..."

# Org1 Key (dynamic find)
KEY_DIR1="../test-network/organizations/peerOrganizations/org1.example.com/users/User1@org1.example.com/msp/keystore"
PVT_KEY1=$(find "$KEY_DIR1" -name "*_sk" -type f 2>/dev/null | head -n 1)
if [ -z "$PVT_KEY1" ]; then
    echo -e "${RED}ERROR: Org1 private key not found!${NC}"
    exit 1
fi

# Org1 Certificate (try both naming conventions)
CERT_DIR1="../test-network/organizations/peerOrganizations/org1.example.com/users/User1@org1.example.com/msp/signcerts"
if [ -f "$CERT_DIR1/cert.pem" ]; then
    CERT_FILE1="$CERT_DIR1/cert.pem"
elif [ -f "$CERT_DIR1/User1@org1.example.com-cert.pem" ]; then
    CERT_FILE1="$CERT_DIR1/User1@org1.example.com-cert.pem"
else
    CERT_FILE1=$(find "$CERT_DIR1" -name "*.pem" -type f 2>/dev/null | head -n 1)
fi

# Org2 Key (dynamic find)
KEY_DIR2="../test-network/organizations/peerOrganizations/org2.example.com/users/User1@org2.example.com/msp/keystore"
PVT_KEY2=$(find "$KEY_DIR2" -name "*_sk" -type f 2>/dev/null | head -n 1)
if [ -z "$PVT_KEY2" ]; then
    echo -e "${RED}ERROR: Org2 private key not found!${NC}"
    exit 1
fi

# Org2 Certificate (try both naming conventions)
CERT_DIR2="../test-network/organizations/peerOrganizations/org2.example.com/users/User1@org2.example.com/msp/signcerts"
if [ -f "$CERT_DIR2/cert.pem" ]; then
    CERT_FILE2="$CERT_DIR2/cert.pem"
elif [ -f "$CERT_DIR2/User1@org2.example.com-cert.pem" ]; then
    CERT_FILE2="$CERT_DIR2/User1@org2.example.com-cert.pem"
else
    CERT_FILE2=$(find "$CERT_DIR2" -name "*.pem" -type f 2>/dev/null | head -n 1)
fi

echo "Org1 Key: $PVT_KEY1"
echo "Org1 Cert: $CERT_FILE1"
echo "Org2 Key: $PVT_KEY2"
echo "Org2 Cert: $CERT_FILE2"

# Resolve to absolute paths for reliability
PVT_KEY1=$(cd "$(dirname "$PVT_KEY1")" && echo "$(pwd)/$(basename "$PVT_KEY1")")
CERT_FILE1=$(cd "$(dirname "$CERT_FILE1")" && echo "$(pwd)/$(basename "$CERT_FILE1")")
PVT_KEY2=$(cd "$(dirname "$PVT_KEY2")" && echo "$(pwd)/$(basename "$PVT_KEY2")")
CERT_FILE2=$(cd "$(dirname "$CERT_FILE2")" && echo "$(pwd)/$(basename "$CERT_FILE2")")

# Get absolute paths for TLS certificates
ABS_ROOT="$(cd "$ROOT_DIR" && pwd)"
ORDERER_TLS="$ABS_ROOT/test-network/organizations/ordererOrganizations/example.com/orderers/orderer.example.com/msp/tlscacerts/tlsca.example.com-cert.pem"
PEER0_ORG1_TLS="$ABS_ROOT/test-network/organizations/peerOrganizations/org1.example.com/peers/peer0.org1.example.com/tls/ca.crt"
PEER0_ORG2_TLS="$ABS_ROOT/test-network/organizations/peerOrganizations/org2.example.com/peers/peer0.org2.example.com/tls/ca.crt"
CA_ORG1_CERT="$ABS_ROOT/test-network/organizations/peerOrganizations/org1.example.com/ca/ca.org1.example.com-cert.pem"
CA_ORG2_CERT="$ABS_ROOT/test-network/organizations/peerOrganizations/org2.example.com/ca/ca.org2.example.com-cert.pem"

# ============================================================
# FIX #4: Generate PROPER network config with absolute paths
# ============================================================
echo "=== FIX #4: Generating network config with absolute paths ==="
mkdir -p networks

cat << EOF > networks/networkConfig.yaml
name: Caliper-Fabric
version: "2.0.0"
caliper:
  blockchain: fabric

channels:
  - channelName: mychannel
    contracts:
      - id: basic

organizations:
  - mspid: Org1MSP
    identities:
      certificates:
        - name: 'User1@org1.example.com'
          clientPrivateKey:
            path: '$PVT_KEY1'
          clientSignedCert:
            path: '$CERT_FILE1'
    connectionProfile:
      path: 'networks/connection-org1.yaml'
      discover: false

  - mspid: Org2MSP
    identities:
      certificates:
        - name: 'User1@org2.example.com'
          clientPrivateKey:
            path: '$PVT_KEY2'
          clientSignedCert:
            path: '$CERT_FILE2'
    connectionProfile:
      path: 'networks/connection-org2.yaml'
      discover: false
EOF

# ============================================================
# FIX #5: Generate COMPLETE connection profiles with orderer
# The auto-generated connection-org1.yaml from test-network uses
# inline PEM certs and lacks orderer definitions needed by Caliper
# when discover:false. We generate our own with file paths.
# ============================================================
echo "=== FIX #5: Generating connection profiles with orderer definitions ==="

cat << EOF > networks/connection-org1.yaml
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
      path: $ORDERER_TLS

peers:
  peer0.org1.example.com:
    url: grpcs://localhost:7051
    grpcOptions:
      ssl-target-name-override: peer0.org1.example.com
      hostnameOverride: peer0.org1.example.com
    tlsCACerts:
      path: $PEER0_ORG1_TLS
  peer0.org2.example.com:
    url: grpcs://localhost:9051
    grpcOptions:
      ssl-target-name-override: peer0.org2.example.com
      hostnameOverride: peer0.org2.example.com
    tlsCACerts:
      path: $PEER0_ORG2_TLS

certificateAuthorities:
  ca.org1.example.com:
    url: https://localhost:7054
    caName: ca-org1
    tlsCACerts:
      path: $CA_ORG1_CERT
    httpOptions:
      verify: false
EOF

cat << EOF > networks/connection-org2.yaml
name: test-network-org2
version: 1.0.0
client:
  organization: Org2
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
  Org2:
    mspid: Org2MSP
    peers:
      - peer0.org2.example.com
    certificateAuthorities:
      - ca.org2.example.com

orderers:
  orderer.example.com:
    url: grpcs://localhost:7050
    grpcOptions:
      ssl-target-name-override: orderer.example.com
      hostnameOverride: orderer.example.com
    tlsCACerts:
      path: $ORDERER_TLS

peers:
  peer0.org1.example.com:
    url: grpcs://localhost:7051
    grpcOptions:
      ssl-target-name-override: peer0.org1.example.com
      hostnameOverride: peer0.org1.example.com
    tlsCACerts:
      path: $PEER0_ORG1_TLS
  peer0.org2.example.com:
    url: grpcs://localhost:9051
    grpcOptions:
      ssl-target-name-override: peer0.org2.example.com
      hostnameOverride: peer0.org2.example.com
    tlsCACerts:
      path: $PEER0_ORG2_TLS

certificateAuthorities:
  ca.org2.example.com:
    url: https://localhost:8054
    caName: ca-org2
    tlsCACerts:
      path: $CA_ORG2_CERT
    httpOptions:
      verify: false
EOF

echo "Connection profiles generated."

# ============================================================
# RUN BENCHMARK
# ============================================================
echo "Running Benchmark (4 rounds - Fail target = 0)..."
echo "   Round 1: IssueCertificate     @ 50 TPS  / 30s"
echo "   Round 2: VerifyCertificate    @ 100 TPS / 30s"
echo "   Round 3: QueryAllCertificates @ 50 TPS  / 30s"
echo "   Round 4: RevokeCertificate    @ 50 TPS  / 30s"
sudo chmod 666 /var/run/docker.sock
# FIX #6: Added --caliper-fabric-gateway-enabled for Fabric 2.5 compat
npx caliper launch manager \
    --caliper-workspace . \
    --caliper-networkconfig networks/networkConfig.yaml \
    --caliper-benchconfig benchmarks/benchConfig.yaml \
    --caliper-flow-only-test \
    --caliper-fabric-gateway-enabled

# ============================================================
# FIX #8: Verify report was actually generated
# ============================================================
if [ -f "report.html" ]; then
    REPORT_SIZE=$(stat -c%s "report.html" 2>/dev/null || stat -f%z "report.html" 2>/dev/null || echo "unknown")
    echo ""
    echo "=================================================="
    echo -e "${GREEN}DEFAULT CALIPER REPORT GENERATED${NC}"
    echo "  Report: $(pwd)/report.html ($REPORT_SIZE bytes)"
    echo "=================================================="

    # ============================================================
    # STEP 9: Run Custom Report Post-Processor (PhD-Level)
    # ============================================================
    echo ""
    echo "=================================================="
    echo -e "${GREEN}Running Custom Report Post-Processor...${NC}"
    echo "=================================================="

    if [ -f "generate_custom_report.js" ]; then
        node generate_custom_report.js report.html report_custom.html
        if [ -f "report_custom.html" ]; then
            CUSTOM_SIZE=$(stat -c%s "report_custom.html" 2>/dev/null || stat -f%z "report_custom.html" 2>/dev/null || echo "unknown")
            echo ""
            echo "=================================================="
            echo -e "${GREEN}BENCHMARK COMPLETE — ALL REPORTS GENERATED${NC}"
            echo "  Default Report: $(pwd)/report.html ($REPORT_SIZE bytes)"
            echo "  Custom Report:  $(pwd)/report_custom.html ($CUSTOM_SIZE bytes)"
            echo "  Generated: $(date '+%Y-%m-%d %H:%M:%S')"
            echo "=================================================="
        else
            echo -e "${RED}WARNING: Custom report generation failed.${NC}"
            echo "Default report still available: $(pwd)/report.html"
        fi
    else
        echo -e "${RED}WARNING: generate_custom_report.js not found in $(pwd)${NC}"
        echo "Default report: $(pwd)/report.html ($REPORT_SIZE bytes)"
    fi
else
    echo ""
    echo "=================================================="
    echo -e "${RED}ERROR: report.html was NOT generated!${NC}"
    echo "The benchmark failed. Check caliper.log for details."
    echo "Common causes:"
    echo "  - Network containers not running (check: docker ps)"
    echo "  - Chaincode not deployed or wrong version"
    echo "  - Certificate/key path mismatch"
    echo "  - Caliper bind version mismatch (should be fabric:2.5)"
    echo "=================================================="
    exit 1
fi
