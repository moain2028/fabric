# 🚀 EXECUTION GUIDE — BCMS Deployment & Testing
## Blockchain Certificate Management System
### End-to-End Deployment, Testing, and Benchmarking

---

## 📋 Table of Contents
1. [Prerequisites](#prerequisites)
2. [Quick Start](#quick-start)
3. [Step-by-Step Deployment](#step-by-step-deployment)
4. [Chaincode Testing](#chaincode-testing)
5. [REST API Usage](#rest-api-usage)
6. [Caliper Benchmarking](#caliper-benchmarking)
7. [Monitoring (Prometheus + Grafana)](#monitoring)
8. [Architecture Reference](#architecture-reference)
9. [Troubleshooting](#troubleshooting)

---

## 1. Prerequisites

### System Requirements
```
OS:       Ubuntu 20.04+ / macOS 12+ / Windows 11 (WSL2)
RAM:      8GB minimum (16GB recommended)
Disk:     20GB free space
CPU:      4 cores recommended
```

### Software Requirements
```bash
# Docker (v20.10+)
docker --version

# Docker Compose (v2.0+)
docker compose version

# Go (v1.21+)
go version

# Node.js (v18+)
node --version

# npm (v9+)
npm --version
```

### Hyperledger Fabric Binaries
```bash
# Download Fabric v2.5 binaries (if not already installed)
curl -sSL https://bit.ly/2ysbOFE | bash -s -- 2.5.0 1.5.5

# Add to PATH
export PATH=$HOME/fabric-samples/bin:$PATH

# Verify
peer version
# Expected: hyperledger/fabric-peer: 2.5.x
```

---

## 2. Quick Start

```bash
# Clone repository (if not already done)
git clone -b genspark_ai_developer https://github.com/moain2028/fabric_certificate_new.git
cd fabric_certificate_new

# Full automated deployment (takes ~5 minutes)
chmod +x deploy.sh
./deploy.sh

# After deployment completes, start the REST API
cd bcms-api && npm install && npm start &

# Run the Caliper benchmark
cd caliper-workspace && ./fix_and_run_caliper.sh
```

---

## 3. Step-by-Step Deployment

### Step 3.1: Start Hyperledger Fabric Network

```bash
cd test-network

# Start network with 2 orgs, CouchDB (for rich queries), and CA
./network.sh up createChannel -c mychannel -ca -s couchdb

# Verify containers are running
docker ps --filter "network=fabric_test"
# Expected containers:
#   peer0.org1.example.com    (port 7051)
#   peer0.org2.example.com    (port 9051)
#   orderer.example.com       (port 7050)
#   ca_org1                   (port 7054)
#   ca_org2                   (port 8054)
#   couchdb0                  (port 5984)
#   couchdb1                  (port 7984)

cd ..
```

### Step 3.2: Verify Go Chaincode Compilation

```bash
cd asset-transfer-basic/chaincode-go

# Verify the enhanced chaincode compiles
go build ./...
# Expected: No errors

# Optional: Run tests
go test ./chaincode/...

cd ../..
```

### Step 3.3: Deploy Chaincode

```bash
cd test-network

# Deploy with endorsement policy: any peer from Org1 OR Org2 can endorse
./network.sh deployCC \
    -ccn basic \
    -ccp ../asset-transfer-basic/chaincode-go \
    -ccl go \
    -c mychannel \
    -ccep "OR('Org1MSP.peer','Org2MSP.peer')"

# Expected output: Committed chaincode definition for chaincode 'basic' on channel 'mychannel'

cd ..
```

### Step 3.4: Initialize Ledger

```bash
cd test-network

# Set Org1 environment
source setOrgEnv.sh 1
export ORDERER_CA=$PWD/organizations/ordererOrganizations/example.com/orderers/orderer.example.com/msp/tlscacerts/tlsca.example.com-cert.pem
export PEER0_ORG1_CA=$PWD/organizations/peerOrganizations/org1.example.com/peers/peer0.org1.example.com/tls/ca.crt
export PEER0_ORG2_CA=$PWD/organizations/peerOrganizations/org2.example.com/peers/peer0.org2.example.com/tls/ca.crt

# Initialize ledger with 5 seed certificates
peer chaincode invoke \
    -o localhost:7050 \
    --ordererTLSHostnameOverride orderer.example.com \
    --tls --cafile "$ORDERER_CA" \
    -C mychannel -n basic \
    --peerAddresses localhost:7051 --tlsRootCertFiles "$PEER0_ORG1_CA" \
    --peerAddresses localhost:9051 --tlsRootCertFiles "$PEER0_ORG2_CA" \
    -c '{"function":"InitLedger","Args":[]}' \
    --waitForEvent

# Expected: [chaincodeCmd] chaincodeInvokeOrQuery -> INFO Chaincode invoke successful

cd ..
```

---

## 4. Chaincode Testing

### 4.1: Issue a Certificate (Org1 Only — RBAC)

```bash
cd test-network && source setOrgEnv.sh 1

peer chaincode invoke \
    -o localhost:7050 \
    --ordererTLSHostnameOverride orderer.example.com \
    --tls --cafile "$ORDERER_CA" \
    -C mychannel -n basic \
    --peerAddresses localhost:7051 --tlsRootCertFiles "$PEER0_ORG1_CA" \
    --peerAddresses localhost:9051 --tlsRootCertFiles "$PEER0_ORG2_CA" \
    -c '{
        "function":"IssueCertificate",
        "Args":[
            "CERT100",
            "STU100",
            "Ahmed Al-Rashid",
            "Bachelor of Computer Science",
            "Digital University",
            "2025-01-15",
            "",
            ""
        ]
    }' --waitForEvent
```

### 4.2: Verify a Certificate (Public — Any Org)

```bash
# First compute the hash (matches chaincode formula: SHA256(studentID|name|degree|issuer|date))
HASH=$(echo -n "STU100|Ahmed Al-Rashid|Bachelor of Computer Science|Digital University|2025-01-15" | sha256sum | cut -d' ' -f1)

peer chaincode query \
    -C mychannel -n basic \
    -c "{\"function\":\"VerifyCertificate\",\"Args\":[\"CERT100\",\"$HASH\"]}"

# Expected: {"certID":"CERT100","valid":true,"isRevoked":false,"hashMatch":true,...}
```

### 4.3: Read a Certificate

```bash
peer chaincode query \
    -C mychannel -n basic \
    -c '{"function":"ReadCertificate","Args":["CERT100"]}'
```

### 4.4: Query All Certificates

```bash
peer chaincode query \
    -C mychannel -n basic \
    -c '{"function":"QueryAllCertificates","Args":[]}'
```

### 4.5: Get Certificates by Student

```bash
peer chaincode query \
    -C mychannel -n basic \
    -c '{"function":"GetCertificatesByStudent","Args":["STU100"]}'
```

### 4.6: Get Certificate History

```bash
peer chaincode query \
    -C mychannel -n basic \
    -c '{"function":"GetCertificateHistory","Args":["CERT100"]}'
```

### 4.7: Get Audit Logs

```bash
peer chaincode query \
    -C mychannel -n basic \
    -c '{"function":"GetAuditLogs","Args":[]}'
```

### 4.8: Revoke a Certificate (Org2 RBAC)

```bash
# Switch to Org2
source setOrgEnv.sh 2

peer chaincode invoke \
    -o localhost:7050 \
    --ordererTLSHostnameOverride orderer.example.com \
    --tls --cafile "$ORDERER_CA" \
    -C mychannel -n basic \
    --peerAddresses localhost:7051 --tlsRootCertFiles "$PEER0_ORG1_CA" \
    --peerAddresses localhost:9051 --tlsRootCertFiles "$PEER0_ORG2_CA" \
    -c '{"function":"RevokeCertificate","Args":["CERT100"]}' \
    --waitForEvent
```

### 4.9: Test RBAC Rejection (Expected Failure)

```bash
# Switch to Org2 and try to issue (should be rejected)
source setOrgEnv.sh 2

peer chaincode invoke \
    -o localhost:7050 \
    --ordererTLSHostnameOverride orderer.example.com \
    --tls --cafile "$ORDERER_CA" \
    -C mychannel -n basic \
    --peerAddresses localhost:7051 --tlsRootCertFiles "$PEER0_ORG1_CA" \
    --peerAddresses localhost:9051 --tlsRootCertFiles "$PEER0_ORG2_CA" \
    -c '{"function":"IssueCertificate","Args":["CERT_FAIL","STU999","Hacker","Degree","Evil Org","2025-01-01","",""]}' \
    --waitForEvent

# Expected error: access denied: only Org1MSP can issue certificates
```

### 4.10: Compute SHA-256 Hash via Chaincode

```bash
peer chaincode query \
    -C mychannel -n basic \
    -c '{
        "function":"ComputeHash",
        "Args":["STU100","Ahmed Al-Rashid","Bachelor of Computer Science","Digital University","2025-01-15"]
    }'
# Returns the SHA-256 hash you can use for verification
```

---

## 5. REST API Usage

### 5.1: Start the API

```bash
cd bcms-api

# Copy environment config
cp .env.example .env

# Install dependencies
npm install

# Start the API server
npm start
# Server running on http://0.0.0.0:3000
```

### 5.2: Test Endpoints with curl

```bash
# Health check
curl http://localhost:3000/api/v1/health

# Issue certificate
curl -X POST http://localhost:3000/api/v1/certificates \
  -H "Content-Type: application/json" \
  -d '{
    "id": "CERT200",
    "studentID": "STU200",
    "studentName": "Fatima Hassan",
    "degree": "Master of Data Science",
    "issuer": "Technology University",
    "issueDate": "2025-03-01"
  }'

# Get all certificates
curl http://localhost:3000/api/v1/certificates

# Get single certificate
curl http://localhost:3000/api/v1/certificates/CERT200

# Verify certificate (auto-computes hash from fields)
curl -X POST http://localhost:3000/api/v1/certificates/CERT200/verify \
  -H "Content-Type: application/json" \
  -d '{
    "studentID": "STU200",
    "studentName": "Fatima Hassan",
    "degree": "Master of Data Science",
    "issuer": "Technology University",
    "issueDate": "2025-03-01"
  }'

# Get certificates by student
curl http://localhost:3000/api/v1/certificates/student/STU200

# Get certificate history
curl http://localhost:3000/api/v1/certificates/CERT200/history

# Get audit logs
curl http://localhost:3000/api/v1/audit

# Revoke certificate (using Org2)
curl -X DELETE http://localhost:3000/api/v1/certificates/CERT200 \
  -H "X-Org-MSP: Org2MSP"

# Compute SHA-256 hash
curl -X POST http://localhost:3000/api/v1/certificates/hash/compute \
  -H "Content-Type: application/json" \
  -d '{
    "studentID": "STU200",
    "studentName": "Fatima Hassan",
    "degree": "Master of Data Science",
    "issuer": "Technology University",
    "issueDate": "2025-03-01"
  }'

# Prometheus metrics
curl http://localhost:3000/metrics
```

---

## 6. Caliper Benchmarking

### 6.1: Prerequisites

```bash
# Ensure network is running
docker ps | grep fabric
# All peer/orderer/ca containers must be "Up"

# Ensure chaincode is deployed
cd test-network && source setOrgEnv.sh 1
peer chaincode list --installed
# Should show: basic

# Ensure ledger is initialized (at least some certificates exist)
peer chaincode query -C mychannel -n basic -c '{"function":"QueryAllCertificates","Args":[]}'
```

### 6.2: Run Full Benchmark (All 6 Rounds)

```bash
cd caliper-workspace

# Run the automated benchmark (installs deps, generates configs, runs all 6 rounds)
./fix_and_run_caliper.sh
```

### 6.3: What the Benchmark Tests

| Round | Function | TPS | Duration | Type |
|-------|----------|-----|----------|------|
| 1 | IssueCertificate | 50 | 30s | Write (Org1) |
| 2 | VerifyCertificate | 100 | 30s | Read (Public) |
| 3 | QueryAllCertificates | 50 | 30s | Rich Query |
| 4 | RevokeCertificate | 50 | 30s | Write (Org2) |
| 5 | GetCertificatesByStudent | 75 | 30s | Indexed Query |
| 6 | GetAuditLogs | 30 | 30s | Audit Query |

### 6.4: Expected Results (Matching Research Paper)

| Metric | Target | Based on Paper |
|--------|--------|----------------|
| IssueCertificate TPS | ~50 TPS (configured) / up to 250 TPS | Paper: 250 TPS |
| VerifyCertificate latency | <50ms (readOnly) | Paper: 118ms avg |
| Success Rate | 100% (0% failures) | Paper: 99.5% availability |
| RBAC enforcement | All write tx from correct MSP | Paper: RBAC design |

### 6.5: Report Files

After the benchmark completes:
```
caliper-workspace/
├── report.html           # Default Caliper HTML report
└── report_custom.html    # Custom PhD-level report
```

Open `report_custom.html` in a browser for the detailed analysis report.

### 6.6: Run Individual Rounds (Advanced)

```bash
# Run only specific rounds by editing benchConfig.yaml
# Comment out rounds you don't want to run
nano caliper-workspace/benchmarks/benchConfig.yaml

# Then run
npx caliper launch manager \
    --caliper-workspace ./caliper-workspace \
    --caliper-networkconfig caliper-workspace/networks/networkConfig.yaml \
    --caliper-benchconfig caliper-workspace/benchmarks/benchConfig.yaml \
    --caliper-flow-only-test \
    --caliper-fabric-gateway-enabled
```

---

## 7. Monitoring (Prometheus + Grafana)

### 7.1: Start Monitoring Stack

```bash
cd test-network/prometheus-grafana

# Start Prometheus + Grafana + cAdvisor
docker-compose up -d

# Verify services
docker-compose ps
```

### 7.2: Access Dashboards

| Service | URL | Credentials |
|---------|-----|-------------|
| Grafana | http://localhost:3001 | admin / admin |
| Prometheus | http://localhost:9090 | none |
| cAdvisor | http://localhost:8080 | none |

### 7.3: Key Prometheus Queries

```promql
# Fabric peer endorsement success rate
endorser_successful_proposals_total{job="peer0_org1"} 

# Orderer transaction throughput  
consensus_etcdraft_committed_block_number{job="orderer"}

# BCMS API request rate
rate(bcms_http_request_duration_ms_count[1m])

# BCMS API latency 95th percentile
histogram_quantile(0.95, bcms_http_request_duration_ms_bucket)

# Fabric transaction counter
bcms_fabric_transactions_total
```

### 7.4: Grafana Dashboard

Import the pre-configured dashboard:
1. Open Grafana → http://localhost:3001
2. Login: admin/admin
3. Dashboard: "HLF Performances" is already configured

---

## 8. Architecture Reference

### Network Topology

```
┌──────────────────────────────────────────────────────────────────┐
│                     BCMS NETWORK TOPOLOGY                         │
│                                                                    │
│  ┌──────────────────────────────────────────────────────────────┐│
│  │                    Application Layer                          ││
│  │  ┌─────────────────┐              ┌────────────────────────┐ ││
│  │  │   BCMS REST API  │              │  Caliper Benchmark     │ ││
│  │  │   (Node.js)      │              │  (6 rounds)            │ ││
│  │  │   :3000          │              │                        │ ││
│  │  └────────┬─────────┘              └──────────┬─────────────┘ ││
│  └───────────┼──────────────────────────────────┼───────────────┘│
│              │                                    │                │
│  ┌───────────▼────────────────────────────────────▼─────────────┐│
│  │                    Blockchain Layer                            ││
│  │                                                                ││
│  │  Org1 (Issuer)              Org2 (Verifier)                  ││
│  │  ┌─────────────────┐        ┌──────────────────┐             ││
│  │  │ peer0.org1:7051  │        │ peer0.org2:9051   │             ││
│  │  │ (CouchDB :5984)  │        │ (CouchDB :7984)   │             ││
│  │  │ CA: :7054        │        │ CA: :8054          │             ││
│  │  └────────┬─────────┘        └────────┬──────────┘             ││
│  │           │                            │                        ││
│  │  ┌────────▼────────────────────────────▼──────────────────┐   ││
│  │  │            Orderer (Raft Consensus): :7050              │   ││
│  │  │                 Channel: mychannel                       │   ││
│  │  │                 Chaincode: basic (Go)                   │   ││
│  │  └────────────────────────────────────────────────────────┘   ││
│  └────────────────────────────────────────────────────────────────┘│
│                                                                    │
│  Monitoring: Prometheus:9090 | Grafana:3001 | cAdvisor:8080       │
└──────────────────────────────────────────────────────────────────┘
```

### Certificate Issuance Sequence

```
Client (Org1)           REST API             Chaincode            Ledger
     │                      │                     │                  │
     │── POST /certificates──►                     │                  │
     │                      │──submitTransaction──►│                  │
     │                      │                     │─ RBAC check ─►   │
     │                      │                     │  (Org1MSP only)  │
     │                      │                     │─ ABAC check ─►   │
     │                      │                     │  (role=issuer)   │
     │                      │                     │─ Compute H(C) ►  │
     │                      │                     │  SHA256(fields)  │
     │                      │                     │─ PutState ──────►│
     │                      │                     │  (cert JSON)     │
     │                      │                     │─ PutState ──────►│
     │                      │                     │  (AUDIT_txID)    │
     │                      │◄──── success ────────│                  │
     │◄─── 201 Created ─────│                     │                  │
```

### Certificate Verification Sequence

```
Requester (Org2)        REST API             Chaincode            Ledger
     │                      │                     │                  │
     │─ POST /:id/verify ──►│                     │                  │
     │                      │─ evaluateTransaction►│                  │
     │                      │                     │─ GetState ──────►│
     │                      │                     │◄── cert JSON ────│
     │                      │                     │─ Check revoked  │
     │                      │                     │─ Compare H(C) ─►│
     │                      │                     │  stored vs given │
     │                      │                     │─ PutState AUDIT─►│
     │                      │◄── VerificationResult│                  │
     │◄── 200 {valid:true} ─│                     │                  │
```

---

## 9. Troubleshooting

### Problem: Caliper fails with "chaincode not found"

```bash
# Verify chaincode is installed
cd test-network && source setOrgEnv.sh 1
peer chaincode list --installed
# Should show: basic

# If not installed, redeploy
./network.sh deployCC -ccn basic -ccp ../asset-transfer-basic/chaincode-go -ccl go -c mychannel -ccep "OR('Org1MSP.peer','Org2MSP.peer')"
```

### Problem: Caliper fails with "certificate not found"

```bash
# Check if network is using CA
docker ps | grep ca
# If ca_org1 and ca_org2 are not running, restart with -ca flag:
./network.sh down
./network.sh up createChannel -c mychannel -ca -s couchdb
```

### Problem: "access denied: only Org1MSP can issue certificates"

```bash
# This is expected when testing RBAC — it means RBAC is working!
# To issue, use Org1 identity:
source setOrgEnv.sh 1  # Switch to Org1
```

### Problem: Hash mismatch in VerifyCertificate

```bash
# Verify hash formula: SHA256(studentID|studentName|degree|issuer|issueDate)
# Note: fields joined with | (pipe) separator, NOT any other character
echo -n "STU100|Ahmed Al-Rashid|Bachelor of Computer Science|Digital University|2025-01-15" | sha256sum
```

### Problem: Docker containers not starting

```bash
# Clean up completely
cd test-network
./network.sh down
docker system prune -f
docker volume prune -f
./network.sh up createChannel -c mychannel -ca -s couchdb
```

### Problem: Go chaincode fails to compile

```bash
cd asset-transfer-basic/chaincode-go
go mod tidy
go build ./...
# Check error messages for missing imports
```

### Problem: REST API can't connect to Fabric

```bash
# Check test-network is running
docker ps | grep fabric

# Check peer endpoint
export CORE_PEER_ADDRESS=localhost:7051
peer channel list
# Should list: mychannel

# Verify crypto material exists
ls test-network/organizations/peerOrganizations/org1.example.com/users/User1@org1.example.com/msp/keystore/
```

### Stop Everything

```bash
# Stop REST API (if running)
pkill -f "node src/app.js" 2>/dev/null

# Stop Fabric network
cd test-network && ./network.sh down

# Stop monitoring
cd test-network/prometheus-grafana && docker-compose down

# Clean Docker volumes
docker volume prune -f
```

---

## 📌 Important Notes

1. **Network must be running** before executing any chaincode commands or Caliper benchmarks
2. **Chaincode must be deployed** before running Caliper (check with `peer chaincode list`)
3. **Caliper requires** both Org1 and Org2 identities (for rounds 1 & 4)
4. **CouchDB is required** for rich queries (QueryAllCertificates, GetCertificatesByStudent, GetCertificatesByIssuer)
5. **The hash formula** must be consistent between client (JavaScript) and chaincode (Go): `SHA256(studentID|studentName|degree|issuer|issueDate)` with `|` separator
6. **All Caliper rounds** are designed for 0% failure rate through idempotency and null-safe returns

---

*Generated for: BCMS Research Paper Implementation*  
*Paper: "Enhancing Trust and Transparency in Education Using Blockchain: A Hyperledger Fabric-Based Framework"*  
*Authors: Panwar, Mallik et al. (2025)*
