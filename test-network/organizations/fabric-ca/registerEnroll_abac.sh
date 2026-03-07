#!/usr/bin/env bash
# ============================================================================
#  registerEnroll_abac.sh — ABAC Identity Registration & Enrollment
#  BCMS Certificate Management System — Hyperledger Fabric 2.5
#  Branch: feature/abac-optimized-auth
#
#  KEY DIFFERENCE FROM RBAC VERSION:
#  ─────────────────────────────────
#  All user identities are enrolled with an X.509 certificate that carries
#  the "role" attribute (--id.attrs "role=<value>:ecert").
#
#  The ":ecert" suffix instructs Fabric CA to embed the attribute into the
#  enrollment certificate, making it readable on-chain via:
#      ctx.GetClientIdentity().GetAttributeValue("role")
#
#  Roles registered:
#    admin    → org1admin, org2admin    → InitLedger + RevokeCertificate
#    issuer   → issuer1 (Org1)         → IssueCertificate
#    verifier → verifier1 (Org2)       → VerifyCertificate (+ query)
#
#  NOTE: Standard user1 / peer0 identities are also registered (no role attr)
#        so Caliper connection-profile identities continue to work.
# ============================================================================

# ─── Colour helpers ───────────────────────────────────────────────────────────
infoln()    { echo -e "\033[0;32m[INFO]\033[0m  $*" ; }
warnln()    { echo -e "\033[0;33m[WARN]\033[0m  $*" ; }
errorln()   { echo -e "\033[0;31m[ERROR]\033[0m $*" ; }
successln() { echo -e "\033[1;32m[ OK ]\033[0m  $*" ; }

# ─── Org1 ─────────────────────────────────────────────────────────────────────
function createOrg1() {
  infoln "========== Creating Org1 Identities (ABAC) =========="
  mkdir -p organizations/peerOrganizations/org1.example.com/

  export FABRIC_CA_CLIENT_HOME=${PWD}/organizations/peerOrganizations/org1.example.com/

  # ── Enroll CA admin ──────────────────────────────────────────────────
  infoln "Enrolling Org1 CA admin"
  set -x
  fabric-ca-client enroll \
    -u https://admin:adminpw@localhost:7054 \
    --caname ca-org1 \
    --tls.certfiles "${PWD}/organizations/fabric-ca/org1/ca-cert.pem"
  { set +x; } 2>/dev/null

  # ── config.yaml (NodeOUs) ─────────────────────────────────────────────
  cat > "${FABRIC_CA_CLIENT_HOME}/msp/config.yaml" <<EOF
NodeOUs:
  Enable: true
  ClientOUIdentifier:
    Certificate: cacerts/localhost-7054-ca-org1.pem
    OrganizationalUnitIdentifier: client
  PeerOUIdentifier:
    Certificate: cacerts/localhost-7054-ca-org1.pem
    OrganizationalUnitIdentifier: peer
  AdminOUIdentifier:
    Certificate: cacerts/localhost-7054-ca-org1.pem
    OrganizationalUnitIdentifier: admin
  OrdererOUIdentifier:
    Certificate: cacerts/localhost-7054-ca-org1.pem
    OrganizationalUnitIdentifier: orderer
EOF

  # ── Copy CA certs ─────────────────────────────────────────────────────
  mkdir -p "${FABRIC_CA_CLIENT_HOME}/msp/tlscacerts"
  cp "${PWD}/organizations/fabric-ca/org1/ca-cert.pem" \
     "${FABRIC_CA_CLIENT_HOME}/msp/tlscacerts/ca.crt"
  mkdir -p "${PWD}/organizations/peerOrganizations/org1.example.com/tlsca"
  cp "${PWD}/organizations/fabric-ca/org1/ca-cert.pem" \
     "${PWD}/organizations/peerOrganizations/org1.example.com/tlsca/tlsca.org1.example.com-cert.pem"
  mkdir -p "${PWD}/organizations/peerOrganizations/org1.example.com/ca"
  cp "${PWD}/organizations/fabric-ca/org1/ca-cert.pem" \
     "${PWD}/organizations/peerOrganizations/org1.example.com/ca/ca.org1.example.com-cert.pem"

  # ── Register peer0 ────────────────────────────────────────────────────
  infoln "Registering Org1 peer0"
  set -x
  fabric-ca-client register \
    --caname ca-org1 \
    --id.name peer0 \
    --id.secret peer0pw \
    --id.type peer \
    --tls.certfiles "${PWD}/organizations/fabric-ca/org1/ca-cert.pem"
  { set +x; } 2>/dev/null

  # ── Register User1 (no role — Caliper default invoker) ───────────────
  infoln "Registering Org1 User1 (Caliper invoker, no role attribute)"
  set -x
  fabric-ca-client register \
    --caname ca-org1 \
    --id.name user1 \
    --id.secret user1pw \
    --id.type client \
    --tls.certfiles "${PWD}/organizations/fabric-ca/org1/ca-cert.pem"
  { set +x; } 2>/dev/null

  # ── Register org1admin — role=admin:ecert ─────────────────────────────
  infoln "Registering Org1 admin  [ABAC: role=admin:ecert]"
  set -x
  fabric-ca-client register \
    --caname ca-org1 \
    --id.name org1admin \
    --id.secret org1adminpw \
    --id.type admin \
    --id.attrs "role=admin:ecert" \
    --tls.certfiles "${PWD}/organizations/fabric-ca/org1/ca-cert.pem"
  { set +x; } 2>/dev/null

  # ── Register issuer1 — role=issuer:ecert ─────────────────────────────
  infoln "Registering Org1 issuer1 [ABAC: role=issuer:ecert]"
  set -x
  fabric-ca-client register \
    --caname ca-org1 \
    --id.name issuer1 \
    --id.secret issuer1pw \
    --id.type client \
    --id.attrs "role=issuer:ecert" \
    --tls.certfiles "${PWD}/organizations/fabric-ca/org1/ca-cert.pem"
  { set +x; } 2>/dev/null

  # ── Enroll peer0 ──────────────────────────────────────────────────────
  infoln "Enrolling Org1 peer0 MSP"
  set -x
  fabric-ca-client enroll \
    -u https://peer0:peer0pw@localhost:7054 \
    --caname ca-org1 \
    -M "${PWD}/organizations/peerOrganizations/org1.example.com/peers/peer0.org1.example.com/msp" \
    --tls.certfiles "${PWD}/organizations/fabric-ca/org1/ca-cert.pem"
  { set +x; } 2>/dev/null
  cp "${FABRIC_CA_CLIENT_HOME}/msp/config.yaml" \
     "${PWD}/organizations/peerOrganizations/org1.example.com/peers/peer0.org1.example.com/msp/config.yaml"

  # ── Enroll peer0 TLS ──────────────────────────────────────────────────
  infoln "Enrolling Org1 peer0 TLS"
  set -x
  fabric-ca-client enroll \
    -u https://peer0:peer0pw@localhost:7054 \
    --caname ca-org1 \
    -M "${PWD}/organizations/peerOrganizations/org1.example.com/peers/peer0.org1.example.com/tls" \
    --enrollment.profile tls \
    --csr.hosts peer0.org1.example.com \
    --csr.hosts localhost \
    --tls.certfiles "${PWD}/organizations/fabric-ca/org1/ca-cert.pem"
  { set +x; } 2>/dev/null
  cp "${PWD}/organizations/peerOrganizations/org1.example.com/peers/peer0.org1.example.com/tls/tlscacerts/"* \
     "${PWD}/organizations/peerOrganizations/org1.example.com/peers/peer0.org1.example.com/tls/ca.crt"
  cp "${PWD}/organizations/peerOrganizations/org1.example.com/peers/peer0.org1.example.com/tls/signcerts/"* \
     "${PWD}/organizations/peerOrganizations/org1.example.com/peers/peer0.org1.example.com/tls/server.crt"
  cp "${PWD}/organizations/peerOrganizations/org1.example.com/peers/peer0.org1.example.com/tls/keystore/"* \
     "${PWD}/organizations/peerOrganizations/org1.example.com/peers/peer0.org1.example.com/tls/server.key"

  # ── Enroll User1 (Caliper invoker) ────────────────────────────────────
  infoln "Enrolling Org1 User1 MSP (Caliper invoker)"
  set -x
  fabric-ca-client enroll \
    -u https://user1:user1pw@localhost:7054 \
    --caname ca-org1 \
    -M "${PWD}/organizations/peerOrganizations/org1.example.com/users/User1@org1.example.com/msp" \
    --tls.certfiles "${PWD}/organizations/fabric-ca/org1/ca-cert.pem"
  { set +x; } 2>/dev/null
  cp "${FABRIC_CA_CLIENT_HOME}/msp/config.yaml" \
     "${PWD}/organizations/peerOrganizations/org1.example.com/users/User1@org1.example.com/msp/config.yaml"

  # ── Enroll org1admin (ABAC admin) ─────────────────────────────────────
  infoln "Enrolling Org1 org1admin [role=admin embedded in X.509]"
  set -x
  fabric-ca-client enroll \
    -u https://org1admin:org1adminpw@localhost:7054 \
    --caname ca-org1 \
    -M "${PWD}/organizations/peerOrganizations/org1.example.com/users/Admin@org1.example.com/msp" \
    --tls.certfiles "${PWD}/organizations/fabric-ca/org1/ca-cert.pem"
  { set +x; } 2>/dev/null
  cp "${FABRIC_CA_CLIENT_HOME}/msp/config.yaml" \
     "${PWD}/organizations/peerOrganizations/org1.example.com/users/Admin@org1.example.com/msp/config.yaml"

  # ── Enroll issuer1 (ABAC issuer) ──────────────────────────────────────
  infoln "Enrolling Org1 issuer1 [role=issuer embedded in X.509]"
  mkdir -p "${PWD}/organizations/peerOrganizations/org1.example.com/users/Issuer1@org1.example.com/msp"
  set -x
  fabric-ca-client enroll \
    -u https://issuer1:issuer1pw@localhost:7054 \
    --caname ca-org1 \
    -M "${PWD}/organizations/peerOrganizations/org1.example.com/users/Issuer1@org1.example.com/msp" \
    --tls.certfiles "${PWD}/organizations/fabric-ca/org1/ca-cert.pem"
  { set +x; } 2>/dev/null
  cp "${FABRIC_CA_CLIENT_HOME}/msp/config.yaml" \
     "${PWD}/organizations/peerOrganizations/org1.example.com/users/Issuer1@org1.example.com/msp/config.yaml"

  successln "Org1 ABAC identities created successfully."
}

# ─── Org2 ─────────────────────────────────────────────────────────────────────
function createOrg2() {
  infoln "========== Creating Org2 Identities (ABAC) =========="
  mkdir -p organizations/peerOrganizations/org2.example.com/

  export FABRIC_CA_CLIENT_HOME=${PWD}/organizations/peerOrganizations/org2.example.com/

  # ── Enroll CA admin ──────────────────────────────────────────────────
  infoln "Enrolling Org2 CA admin"
  set -x
  fabric-ca-client enroll \
    -u https://admin:adminpw@localhost:8054 \
    --caname ca-org2 \
    --tls.certfiles "${PWD}/organizations/fabric-ca/org2/ca-cert.pem"
  { set +x; } 2>/dev/null

  cat > "${FABRIC_CA_CLIENT_HOME}/msp/config.yaml" <<EOF
NodeOUs:
  Enable: true
  ClientOUIdentifier:
    Certificate: cacerts/localhost-8054-ca-org2.pem
    OrganizationalUnitIdentifier: client
  PeerOUIdentifier:
    Certificate: cacerts/localhost-8054-ca-org2.pem
    OrganizationalUnitIdentifier: peer
  AdminOUIdentifier:
    Certificate: cacerts/localhost-8054-ca-org2.pem
    OrganizationalUnitIdentifier: admin
  OrdererOUIdentifier:
    Certificate: cacerts/localhost-8054-ca-org2.pem
    OrganizationalUnitIdentifier: orderer
EOF

  mkdir -p "${FABRIC_CA_CLIENT_HOME}/msp/tlscacerts"
  cp "${PWD}/organizations/fabric-ca/org2/ca-cert.pem" \
     "${FABRIC_CA_CLIENT_HOME}/msp/tlscacerts/ca.crt"
  mkdir -p "${PWD}/organizations/peerOrganizations/org2.example.com/tlsca"
  cp "${PWD}/organizations/fabric-ca/org2/ca-cert.pem" \
     "${PWD}/organizations/peerOrganizations/org2.example.com/tlsca/tlsca.org2.example.com-cert.pem"
  mkdir -p "${PWD}/organizations/peerOrganizations/org2.example.com/ca"
  cp "${PWD}/organizations/fabric-ca/org2/ca-cert.pem" \
     "${PWD}/organizations/peerOrganizations/org2.example.com/ca/ca.org2.example.com-cert.pem"

  # ── Register peer0 ────────────────────────────────────────────────────
  infoln "Registering Org2 peer0"
  set -x
  fabric-ca-client register \
    --caname ca-org2 \
    --id.name peer0 \
    --id.secret peer0pw \
    --id.type peer \
    --tls.certfiles "${PWD}/organizations/fabric-ca/org2/ca-cert.pem"
  { set +x; } 2>/dev/null

  # ── Register User1 (Caliper invoker for RevokeCertificate round) ──────
  infoln "Registering Org2 User1 (Caliper invoker, no role attribute)"
  set -x
  fabric-ca-client register \
    --caname ca-org2 \
    --id.name user1 \
    --id.secret user1pw \
    --id.type client \
    --tls.certfiles "${PWD}/organizations/fabric-ca/org2/ca-cert.pem"
  { set +x; } 2>/dev/null

  # ── Register org2admin — role=admin:ecert ─────────────────────────────
  infoln "Registering Org2 admin  [ABAC: role=admin:ecert]"
  set -x
  fabric-ca-client register \
    --caname ca-org2 \
    --id.name org2admin \
    --id.secret org2adminpw \
    --id.type admin \
    --id.attrs "role=admin:ecert" \
    --tls.certfiles "${PWD}/organizations/fabric-ca/org2/ca-cert.pem"
  { set +x; } 2>/dev/null

  # ── Register verifier1 — role=verifier:ecert ──────────────────────────
  infoln "Registering Org2 verifier1 [ABAC: role=verifier:ecert]"
  set -x
  fabric-ca-client register \
    --caname ca-org2 \
    --id.name verifier1 \
    --id.secret verifier1pw \
    --id.type client \
    --id.attrs "role=verifier:ecert" \
    --tls.certfiles "${PWD}/organizations/fabric-ca/org2/ca-cert.pem"
  { set +x; } 2>/dev/null

  # ── Enroll peer0 ──────────────────────────────────────────────────────
  infoln "Enrolling Org2 peer0 MSP"
  set -x
  fabric-ca-client enroll \
    -u https://peer0:peer0pw@localhost:8054 \
    --caname ca-org2 \
    -M "${PWD}/organizations/peerOrganizations/org2.example.com/peers/peer0.org2.example.com/msp" \
    --tls.certfiles "${PWD}/organizations/fabric-ca/org2/ca-cert.pem"
  { set +x; } 2>/dev/null
  cp "${FABRIC_CA_CLIENT_HOME}/msp/config.yaml" \
     "${PWD}/organizations/peerOrganizations/org2.example.com/peers/peer0.org2.example.com/msp/config.yaml"

  # ── Enroll peer0 TLS ──────────────────────────────────────────────────
  infoln "Enrolling Org2 peer0 TLS"
  set -x
  fabric-ca-client enroll \
    -u https://peer0:peer0pw@localhost:8054 \
    --caname ca-org2 \
    -M "${PWD}/organizations/peerOrganizations/org2.example.com/peers/peer0.org2.example.com/tls" \
    --enrollment.profile tls \
    --csr.hosts peer0.org2.example.com \
    --csr.hosts localhost \
    --tls.certfiles "${PWD}/organizations/fabric-ca/org2/ca-cert.pem"
  { set +x; } 2>/dev/null
  cp "${PWD}/organizations/peerOrganizations/org2.example.com/peers/peer0.org2.example.com/tls/tlscacerts/"* \
     "${PWD}/organizations/peerOrganizations/org2.example.com/peers/peer0.org2.example.com/tls/ca.crt"
  cp "${PWD}/organizations/peerOrganizations/org2.example.com/peers/peer0.org2.example.com/tls/signcerts/"* \
     "${PWD}/organizations/peerOrganizations/org2.example.com/peers/peer0.org2.example.com/tls/server.crt"
  cp "${PWD}/organizations/peerOrganizations/org2.example.com/peers/peer0.org2.example.com/tls/keystore/"* \
     "${PWD}/organizations/peerOrganizations/org2.example.com/peers/peer0.org2.example.com/tls/server.key"

  # ── Enroll User1 (Caliper invoker) ────────────────────────────────────
  infoln "Enrolling Org2 User1 MSP (Caliper invoker)"
  set -x
  fabric-ca-client enroll \
    -u https://user1:user1pw@localhost:8054 \
    --caname ca-org2 \
    -M "${PWD}/organizations/peerOrganizations/org2.example.com/users/User1@org2.example.com/msp" \
    --tls.certfiles "${PWD}/organizations/fabric-ca/org2/ca-cert.pem"
  { set +x; } 2>/dev/null
  cp "${FABRIC_CA_CLIENT_HOME}/msp/config.yaml" \
     "${PWD}/organizations/peerOrganizations/org2.example.com/users/User1@org2.example.com/msp/config.yaml"

  # ── Enroll org2admin (ABAC admin) ─────────────────────────────────────
  infoln "Enrolling Org2 org2admin [role=admin embedded in X.509]"
  set -x
  fabric-ca-client enroll \
    -u https://org2admin:org2adminpw@localhost:8054 \
    --caname ca-org2 \
    -M "${PWD}/organizations/peerOrganizations/org2.example.com/users/Admin@org2.example.com/msp" \
    --tls.certfiles "${PWD}/organizations/fabric-ca/org2/ca-cert.pem"
  { set +x; } 2>/dev/null
  cp "${FABRIC_CA_CLIENT_HOME}/msp/config.yaml" \
     "${PWD}/organizations/peerOrganizations/org2.example.com/users/Admin@org2.example.com/msp/config.yaml"

  # ── Enroll verifier1 (ABAC verifier) ──────────────────────────────────
  infoln "Enrolling Org2 verifier1 [role=verifier embedded in X.509]"
  mkdir -p "${PWD}/organizations/peerOrganizations/org2.example.com/users/Verifier1@org2.example.com/msp"
  set -x
  fabric-ca-client enroll \
    -u https://verifier1:verifier1pw@localhost:8054 \
    --caname ca-org2 \
    -M "${PWD}/organizations/peerOrganizations/org2.example.com/users/Verifier1@org2.example.com/msp" \
    --tls.certfiles "${PWD}/organizations/fabric-ca/org2/ca-cert.pem"
  { set +x; } 2>/dev/null
  cp "${FABRIC_CA_CLIENT_HOME}/msp/config.yaml" \
     "${PWD}/organizations/peerOrganizations/org2.example.com/users/Verifier1@org2.example.com/msp/config.yaml"

  successln "Org2 ABAC identities created successfully."
}

# ─── Orderer Org ──────────────────────────────────────────────────────────────
function createOrderer() {
  infoln "========== Creating Orderer Identities =========="
  mkdir -p organizations/ordererOrganizations/example.com/

  export FABRIC_CA_CLIENT_HOME=${PWD}/organizations/ordererOrganizations/example.com/

  infoln "Enrolling Orderer CA admin"
  set -x
  fabric-ca-client enroll \
    -u https://admin:adminpw@localhost:9054 \
    --caname ca-orderer \
    --tls.certfiles "${PWD}/organizations/fabric-ca/ordererOrg/ca-cert.pem"
  { set +x; } 2>/dev/null

  cat > "${FABRIC_CA_CLIENT_HOME}/msp/config.yaml" <<EOF
NodeOUs:
  Enable: true
  ClientOUIdentifier:
    Certificate: cacerts/localhost-9054-ca-orderer.pem
    OrganizationalUnitIdentifier: client
  PeerOUIdentifier:
    Certificate: cacerts/localhost-9054-ca-orderer.pem
    OrganizationalUnitIdentifier: peer
  AdminOUIdentifier:
    Certificate: cacerts/localhost-9054-ca-orderer.pem
    OrganizationalUnitIdentifier: admin
  OrdererOUIdentifier:
    Certificate: cacerts/localhost-9054-ca-orderer.pem
    OrganizationalUnitIdentifier: orderer
EOF

  mkdir -p "${FABRIC_CA_CLIENT_HOME}/msp/tlscacerts"
  cp "${PWD}/organizations/fabric-ca/ordererOrg/ca-cert.pem" \
     "${FABRIC_CA_CLIENT_HOME}/msp/tlscacerts/tlsca.example.com-cert.pem"
  mkdir -p "${PWD}/organizations/ordererOrganizations/example.com/tlsca"
  cp "${PWD}/organizations/fabric-ca/ordererOrg/ca-cert.pem" \
     "${PWD}/organizations/ordererOrganizations/example.com/tlsca/tlsca.example.com-cert.pem"
  mkdir -p "${PWD}/organizations/ordererOrganizations/example.com/ca"
  cp "${PWD}/organizations/fabric-ca/ordererOrg/ca-cert.pem" \
     "${PWD}/organizations/ordererOrganizations/example.com/ca/ca.example.com-cert.pem"

  infoln "Registering orderer"
  set -x
  fabric-ca-client register \
    --caname ca-orderer \
    --id.name orderer \
    --id.secret ordererpw \
    --id.type orderer \
    --tls.certfiles "${PWD}/organizations/fabric-ca/ordererOrg/ca-cert.pem"
  { set +x; } 2>/dev/null

  infoln "Registering orderer admin"
  set -x
  fabric-ca-client register \
    --caname ca-orderer \
    --id.name ordererAdmin \
    --id.secret ordererAdminpw \
    --id.type admin \
    --tls.certfiles "${PWD}/organizations/fabric-ca/ordererOrg/ca-cert.pem"
  { set +x; } 2>/dev/null

  infoln "Enrolling orderer MSP"
  set -x
  fabric-ca-client enroll \
    -u https://orderer:ordererpw@localhost:9054 \
    --caname ca-orderer \
    -M "${PWD}/organizations/ordererOrganizations/example.com/orderers/orderer.example.com/msp" \
    --tls.certfiles "${PWD}/organizations/fabric-ca/ordererOrg/ca-cert.pem"
  { set +x; } 2>/dev/null
  cp "${FABRIC_CA_CLIENT_HOME}/msp/config.yaml" \
     "${PWD}/organizations/ordererOrganizations/example.com/orderers/orderer.example.com/msp/config.yaml"

  infoln "Enrolling orderer TLS"
  set -x
  fabric-ca-client enroll \
    -u https://orderer:ordererpw@localhost:9054 \
    --caname ca-orderer \
    -M "${PWD}/organizations/ordererOrganizations/example.com/orderers/orderer.example.com/tls" \
    --enrollment.profile tls \
    --csr.hosts orderer.example.com \
    --csr.hosts localhost \
    --tls.certfiles "${PWD}/organizations/fabric-ca/ordererOrg/ca-cert.pem"
  { set +x; } 2>/dev/null
  cp "${PWD}/organizations/ordererOrganizations/example.com/orderers/orderer.example.com/tls/tlscacerts/"* \
     "${PWD}/organizations/ordererOrganizations/example.com/orderers/orderer.example.com/tls/ca.crt"
  cp "${PWD}/organizations/ordererOrganizations/example.com/orderers/orderer.example.com/tls/signcerts/"* \
     "${PWD}/organizations/ordererOrganizations/example.com/orderers/orderer.example.com/tls/server.crt"
  cp "${PWD}/organizations/ordererOrganizations/example.com/orderers/orderer.example.com/tls/keystore/"* \
     "${PWD}/organizations/ordererOrganizations/example.com/orderers/orderer.example.com/tls/server.key"

  infoln "Enrolling orderer admin MSP"
  set -x
  fabric-ca-client enroll \
    -u https://ordererAdmin:ordererAdminpw@localhost:9054 \
    --caname ca-orderer \
    -M "${PWD}/organizations/ordererOrganizations/example.com/users/Admin@example.com/msp" \
    --tls.certfiles "${PWD}/organizations/fabric-ca/ordererOrg/ca-cert.pem"
  { set +x; } 2>/dev/null
  cp "${FABRIC_CA_CLIENT_HOME}/msp/config.yaml" \
     "${PWD}/organizations/ordererOrganizations/example.com/users/Admin@example.com/msp/config.yaml"

  successln "Orderer identities created successfully."
}
