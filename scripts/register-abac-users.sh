#!/bin/bash
# ============================================================================
#  BCMS — Fabric CA Identity Registration Scripts
#  نظام ABAC: تسجيل المستخدمين بسمات الأدوار (role attributes)
#
#  يتم تسجيل 3 أنواع من المستخدمين:
#    1. admin-bcms   → role=admin
#    2. issuer-bcms  → role=issuer
#    3. verifier-bcms → role=verifier
#
#  ملاحظة هامة: :ecert يضمن طبع السمة داخل شهادة X.509
#  حتى يتمكن العقد الذكي من قراءتها عبر GetAttributeValue()
# ============================================================================

set -e  # الخروج فوراً عند أي خطأ

# ─── إعدادات البيئة ──────────────────────────────────────────────────────────
FABRIC_CA_CLIENT_HOME=${FABRIC_CA_CLIENT_HOME:-"$HOME/fabric-ca-client"}
CA_URL=${CA_URL:-"https://localhost:7054"}
CA_TLS_CERT=${CA_TLS_CERT:-"$HOME/fabric-ca-server/tls-cert.pem"}
ORG_MSP=${ORG_MSP:-"Org1MSP"}

# ألوان للطباعة
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

echo -e "${BLUE}============================================================${NC}"
echo -e "${BLUE}  BCMS — Fabric CA Identity Registration (ABAC Mode)${NC}"
echo -e "${BLUE}============================================================${NC}"
echo ""

# ─── الخطوة 0: التحقق من وجود fabric-ca-client ───────────────────────────────
if ! command -v fabric-ca-client &> /dev/null; then
    echo -e "${RED}[ERROR] fabric-ca-client not found in PATH${NC}"
    echo "        Please install Hyperledger Fabric CA client first."
    exit 1
fi

# ─── الخطوة 1: تسجيل دخول المسؤول (Admin Enroll) ───────────────────────────
echo -e "${YELLOW}[STEP 1] Enrolling CA Admin...${NC}"
fabric-ca-client enroll \
    -u "https://admin:adminpw@${CA_URL#*://}" \
    --caname ca-org1 \
    --tls.certfiles "${CA_TLS_CERT}" \
    -M "${FABRIC_CA_CLIENT_HOME}/msp"

echo -e "${GREEN}[OK] CA Admin enrolled successfully${NC}"
echo ""

# ─── الخطوة 2: تسجيل مستخدم Admin (BCMS Admin) ──────────────────────────────
# ─────────────────────────────────────────────────────────────────────────────
#  --id.attrs "role=admin:ecert"
#    • role=admin  : قيمة السمة
#    • :ecert      : يضمن طبع السمة داخل شهادة X.509 عند التسجيل
#                    بدون :ecert لن يتمكن العقد الذكي من قراءة السمة!
# ─────────────────────────────────────────────────────────────────────────────
echo -e "${YELLOW}[STEP 2] Registering BCMS Admin User (role=admin)...${NC}"
fabric-ca-client register \
    --caname ca-org1 \
    --id.name "admin-bcms" \
    --id.secret "admin-bcms-pw" \
    --id.type client \
    --id.affiliation "org1.department1" \
    --id.attrs "role=admin:ecert" \
    --tls.certfiles "${CA_TLS_CERT}" \
    -M "${FABRIC_CA_CLIENT_HOME}/msp"

echo -e "${GREEN}[OK] admin-bcms registered with role=admin:ecert${NC}"
echo ""

# ─── الخطوة 3: تسجيل مستخدم Issuer ─────────────────────────────────────────
echo -e "${YELLOW}[STEP 3] Registering BCMS Issuer User (role=issuer)...${NC}"
fabric-ca-client register \
    --caname ca-org1 \
    --id.name "issuer-bcms" \
    --id.secret "issuer-bcms-pw" \
    --id.type client \
    --id.affiliation "org1.department1" \
    --id.attrs "role=issuer:ecert" \
    --tls.certfiles "${CA_TLS_CERT}" \
    -M "${FABRIC_CA_CLIENT_HOME}/msp"

echo -e "${GREEN}[OK] issuer-bcms registered with role=issuer:ecert${NC}"
echo ""

# ─── الخطوة 4: تسجيل مستخدم Verifier ───────────────────────────────────────
echo -e "${YELLOW}[STEP 4] Registering BCMS Verifier User (role=verifier)...${NC}"
fabric-ca-client register \
    --caname ca-org1 \
    --id.name "verifier-bcms" \
    --id.secret "verifier-bcms-pw" \
    --id.type client \
    --id.affiliation "org1.department1" \
    --id.attrs "role=verifier:ecert" \
    --tls.certfiles "${CA_TLS_CERT}" \
    -M "${FABRIC_CA_CLIENT_HOME}/msp"

echo -e "${GREEN}[OK] verifier-bcms registered with role=verifier:ecert${NC}"
echo ""

# ─── الخطوة 5: استخراج شهادات المستخدمين (Enroll) ────────────────────────────

echo -e "${YELLOW}[STEP 5] Enrolling BCMS Admin User...${NC}"
fabric-ca-client enroll \
    -u "https://admin-bcms:admin-bcms-pw@${CA_URL#*://}" \
    --caname ca-org1 \
    --tls.certfiles "${CA_TLS_CERT}" \
    -M "${FABRIC_CA_CLIENT_HOME}/users/admin-bcms/msp"
echo -e "${GREEN}[OK] admin-bcms enrolled${NC}"
echo ""

echo -e "${YELLOW}[STEP 6] Enrolling BCMS Issuer User...${NC}"
fabric-ca-client enroll \
    -u "https://issuer-bcms:issuer-bcms-pw@${CA_URL#*://}" \
    --caname ca-org1 \
    --tls.certfiles "${CA_TLS_CERT}" \
    -M "${FABRIC_CA_CLIENT_HOME}/users/issuer-bcms/msp"
echo -e "${GREEN}[OK] issuer-bcms enrolled${NC}"
echo ""

echo -e "${YELLOW}[STEP 7] Enrolling BCMS Verifier User...${NC}"
fabric-ca-client enroll \
    -u "https://verifier-bcms:verifier-bcms-pw@${CA_URL#*://}" \
    --caname ca-org1 \
    --tls.certfiles "${CA_TLS_CERT}" \
    -M "${FABRIC_CA_CLIENT_HOME}/users/verifier-bcms/msp"
echo -e "${GREEN}[OK] verifier-bcms enrolled${NC}"
echo ""

# ─── الخطوة 6: التحقق من وجود السمات في الشهادات ─────────────────────────────
echo -e "${YELLOW}[STEP 8] Verifying role attributes in certificates...${NC}"

for user in admin-bcms issuer-bcms verifier-bcms; do
    CERT_FILE=$(find "${FABRIC_CA_CLIENT_HOME}/users/${user}/msp/signcerts" -name "*.pem" 2>/dev/null | head -1)
    if [ -f "${CERT_FILE}" ]; then
        ROLE=$(openssl x509 -in "${CERT_FILE}" -text -noout 2>/dev/null | \
               grep -A1 "1.2.3.4.5.6.7.8.1" | tail -1 | \
               python3 -c "import sys,json; data=sys.stdin.read().strip(); print(json.loads(data).get('role','NOT FOUND'))" 2>/dev/null || \
               echo "use fabric-ca-client inspect to verify")
        echo -e "  ${user}: role attribute = ${GREEN}${ROLE}${NC}"
    else
        echo -e "  ${user}: ${YELLOW}certificate file not found (enroll first)${NC}"
    fi
done

echo ""
echo -e "${BLUE}============================================================${NC}"
echo -e "${GREEN}  ABAC User Registration Complete!${NC}"
echo -e "${BLUE}============================================================${NC}"
echo ""
echo "  Users created:"
echo "  ├── admin-bcms    (role=admin)    → InitLedger, RevokeCertificate"
echo "  ├── issuer-bcms   (role=issuer)   → IssueCertificate, VerifyCertificate"
echo "  └── verifier-bcms (role=verifier) → VerifyCertificate"
echo ""
echo -e "${YELLOW}  IMPORTANT: Delete old wallets before testing!${NC}"
echo "  rm -rf wallet/"
echo ""
