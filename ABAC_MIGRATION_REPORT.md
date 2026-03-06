# 🔐 ABAC Migration Report
## Blockchain Certificate Management System (BCMS)
### Hyperledger Fabric — من RBAC إلى ABAC

---

**التاريخ:** 2026-03-06  
**الفرع:** `feature/abac-implementation`  
**النموذج الجديد:** ABAC (Attribute-Based Access Control)  
**النموذج القديم:** RBAC (Role-Based Access Control via MSP ID)

---

## 📋 ملخص التغييرات

| المكوّن | الملف | التغيير |
|---------|-------|---------|
| العقد الذكي (Chaincode) | `asset-transfer-basic/chaincode-go/chaincode/smartcontract.go` | إزالة RBAC، تفعيل ABAC بالكامل |
| سكربت CA | `scripts/register-abac-users.sh` | **جديد** — تسجيل 3 مستخدمين بسمات ABAC |
| Gateway Node.js | `bcms-api/src/fabric/gateway.js` | تغيير من org-based إلى role-based |
| Routes Node.js | `bcms-api/src/routes/certificates.js` | تحديث استدعاءات getContract() |
| CA Utility | `test-application/javascript/CAUtil.js` | إضافة دوال ABAC |
| ABAC Enroll | `bcms-api/src/fabric/abacEnroll.js` | **جديد** — تسجيل شامل لمستخدمي ABAC |
| .env.example | `bcms-api/.env.example` | تحديث متغيرات البيئة |

---

## 🏗️ معمارية التحكم في الوصول

### RBAC القديم (محذوف)
```
المستخدم ──► [MSP ID = Org1MSP?] ──► تنفيذ / رفض
               └── Org2MSP يُسمح بـ RevokeCertificate
```

### ABAC الجديد (مطبّق)
```
المستخدم ──► [role في شهادة X.509] ──► تنفيذ / رفض
               ├── role=admin    → InitLedger, RevokeCertificate
               ├── role=issuer   → IssueCertificate, VerifyCertificate
               └── role=verifier → VerifyCertificate
```

---

## 🎯 توزيع الصلاحيات (ABAC Roles)

| الدالة | RBAC القديم | ABAC الجديد |
|--------|-------------|-------------|
| `InitLedger` | `Org1MSP` فقط | `role=admin` |
| `IssueCertificate` | `Org1MSP` فقط | `role=issuer` |
| `RevokeCertificate` | `Org1MSP` أو `Org2MSP` | `role=admin` |
| `VerifyCertificate` | أي منظمة | `role=verifier` أو `role=issuer` أو `role=admin` |
| `ReadCertificate` | عام | عام (بدون قيود) |
| `QueryAllCertificates` | عام | عام (بدون قيود) |

---

## 📂 الملفات المُعدَّلة بالتفصيل

### 1. `smartcontract.go` — العقد الذكي

#### التغييرات الجوهرية:

**حذف (RBAC):**
```go
// تم حذف هذه الدالة بالكامل
func getCallerMSP(ctx contractapi.TransactionContextInterface) (string, error) {
    mspID, err := ctx.GetClientIdentity().GetMSPID()
    ...
}

// تم حذف جميع تحققات MSP مثل:
if mspID != "Org1MSP" { return fmt.Errorf(...) }
if mspID != "Org1MSP" && mspID != "Org2MSP" { return fmt.Errorf(...) }
```

**إضافة/تفعيل (ABAC):**
```go
// دالة استخراج الدور من شهادة X.509
func getCallerRole(ctx contractapi.TransactionContextInterface) (string, error) {
    role, found, err := ctx.GetClientIdentity().GetAttributeValue("role")
    if err != nil { return "", fmt.Errorf("failed to read 'role' attribute: %v", err) }
    if !found    { return "", fmt.Errorf("'role' attribute not found in certificate") }
    return role, nil
}

// في InitLedger:
role, err := getCallerRole(ctx)
if role != "admin" { return fmt.Errorf("access denied: only admin can initialize ledger") }

// في IssueCertificate:
role, err := getCallerRole(ctx)
if role != "issuer" { return fmt.Errorf("access denied: only issuer can issue certificates") }

// في RevokeCertificate:
role, err := getCallerRole(ctx)
if role != "admin" { return fmt.Errorf("access denied: only admin can revoke certificates") }
// cert.RevokedBy = callerCN  ← اسم المستخدم بدلاً من MSP ID

// في VerifyCertificate:
authorizedRoles := map[string]bool{"verifier": true, "issuer": true, "admin": true}
if !authorizedRoles[role] { ... }
```

**تحسين `RevokedBy`:**
```go
// RBAC القديم:
cert.RevokedBy = mspID  // كان: "Org1MSP" أو "Org2MSP"

// ABAC الجديد:
cert.RevokedBy = callerCN  // يصبح: "admin-bcms" أو أي اسم مستخدم حقيقي
```

---

### 2. `scripts/register-abac-users.sh` — سكربت CA

```bash
# تسجيل Admin
fabric-ca-client register \
    --id.name "admin-bcms" \
    --id.attrs "role=admin:ecert" \   # ← :ecert ضروري!
    ...

# تسجيل Issuer
fabric-ca-client register \
    --id.name "issuer-bcms" \
    --id.attrs "role=issuer:ecert" \
    ...

# تسجيل Verifier
fabric-ca-client register \
    --id.name "verifier-bcms" \
    --id.attrs "role=verifier:ecert" \
    ...
```

> **⚠️ `:ecert` لماذا ضروري؟**
> بدون `:ecert`، السمة مخزّنة في CA لكن **لا تُطبع** داخل شهادة X.509.
> العقد الذكي يستخدم `ctx.GetClientIdentity().GetAttributeValue("role")`
> والذي يقرأ من الشهادة مباشرة — ليس من CA!

---

### 3. `bcms-api/src/fabric/gateway.js` — Gateway

```javascript
// RBAC القديم:
async function getContract(org = 'org1') { ... }
// الاستخدام: getContract('org1') أو getContract('org2')

// ABAC الجديد:
async function getContract(role = 'issuer') { ... }
// الاستخدام: getContract('admin') أو getContract('issuer') أو getContract('verifier')

const ABAC_USER_CONFIG = {
    admin:    { userId: 'admin-bcms',    certDir: '...', keyDir: '...' },
    issuer:   { userId: 'issuer-bcms',   certDir: '...', keyDir: '...' },
    verifier: { userId: 'verifier-bcms', certDir: '...', keyDir: '...' }
};
```

---

### 4. `bcms-api/src/routes/certificates.js` — Routes

```javascript
// RBAC القديم:
const contract = await getContract('org1');   // POST (issue)
const org = req.headers['x-org-msp'] === 'Org1MSP' ? 'org1' : 'org2';
const contract = await getContract(org);       // DELETE (revoke)

// ABAC الجديد:
const contract = await getContract('issuer');  // POST (issue)
const contract = await getContract('admin');   // DELETE (revoke)
const contract = await getContract('verifier'); // POST (verify) — أو issuer أو admin

// Header جديد: X-User-Role بدلاً من X-Org-MSP
const role = getRoleFromRequest(req, 'verifier');
```

---

### 5. `bcms-api/src/fabric/abacEnroll.js` — ملف تسجيل جديد

```javascript
// النقطة الأساسية: attrs مع ecert: true
const secret = await caClient.register({
    affiliation: affiliation,
    enrollmentID: userId,
    role: 'client',
    attrs: [
        {
            name: 'role',    // يطابق GetAttributeValue("role") في chaincode
            value: roleName, // 'admin' | 'issuer' | 'verifier'
            ecert: true      // ← يطبع السمة داخل شهادة X.509
        }
    ]
}, adminUser);
```

---

## 🚀 خطوات التنفيذ

### الخطوة 1: التأكد من وجود الفرع الصحيح
```bash
git checkout feature/abac-implementation
git status
```

### الخطوة 2: تشغيل شبكة Fabric
```bash
cd test-network
./network.sh up createChannel -ca -c mychannel
```

### الخطوة 3: نشر Chaincode المحدَّث
```bash
./network.sh deployCC -ccn basic \
    -ccp ../asset-transfer-basic/chaincode-go \
    -ccl go
```

### الخطوة 4: ⚠️ مسح المحافظ القديمة (ضروري!)
```bash
# مسح محافظ bcms-api
rm -rf bcms-api/src/fabric/wallet/

# مسح محافظ test-application
rm -rf test-application/javascript/wallet/

# مسح أي محافظ أخرى
find . -name "wallet" -type d -exec rm -rf {} + 2>/dev/null || true
```

> **🔴 تحذير:** إذا لم تمسح المحافظ القديمة، ستستمر الهويات القديمة (بدون سمة role)
> في الاتصال بالشبكة، وسيفشل التحقق من ABAC في العقد الذكي!

### الخطوة 5: تسجيل مستخدمي ABAC

#### الطريقة الأولى — سكربت Bash (fabric-ca-client CLI):
```bash
# تعيين المتغيرات
export FABRIC_CA_CLIENT_HOME=$HOME/fabric-ca-client
export CA_URL=https://localhost:7054
export CA_TLS_CERT=test-network/organizations/fabric-ca/org1/tls-cert.pem

# تشغيل السكربت
bash scripts/register-abac-users.sh
```

#### الطريقة الثانية — Node.js SDK:
```bash
cd bcms-api
npm install
node src/fabric/abacEnroll.js
```

### الخطوة 6: تشغيل API
```bash
cd bcms-api
cp .env.example .env
npm start
```

### الخطوة 7: اختبار ABAC

```bash
# ── اختبار IssueCertificate (يتطلب role=issuer) ──────────────────
curl -X POST http://localhost:3000/api/v1/certificates \
  -H "Content-Type: application/json" \
  -H "X-User-Role: issuer" \
  -d '{
    "id": "CERT100",
    "studentID": "STU100",
    "studentName": "Ahmed Ali",
    "degree": "Bachelor of Computer Science",
    "issuer": "King Fahd University",
    "issueDate": "2024-06-15"
  }'

# ── اختبار VerifyCertificate (يتطلب role=verifier/issuer/admin) ───
curl -X POST http://localhost:3000/api/v1/certificates/CERT100/verify \
  -H "Content-Type: application/json" \
  -H "X-User-Role: verifier" \
  -d '{"certHash": "..."}'

# ── اختبار RevokeCertificate (يتطلب role=admin) ──────────────────
curl -X DELETE http://localhost:3000/api/v1/certificates/CERT100 \
  -H "X-User-Role: admin"

# ── اختبار رفض الوصول (role خاطئ) ────────────────────────────────
# يجب أن يعيد: "access denied: role 'verifier' is not authorized"
curl -X POST http://localhost:3000/api/v1/certificates \
  -H "Content-Type: application/json" \
  -H "X-User-Role: verifier" \
  -d '{ "id": "CERT101", ... }'
```

---

## 🔍 التحقق من طبع السمات في الشهادة

### باستخدام OpenSSL:
```bash
# استخراج شهادة المستخدم
CERT=$(find wallet/ -name "*.id" | head -1)

# عرض ملحقات الشهادة (يجب أن تظهر سمة role)
openssl x509 -in <(cat $CERT | jq -r '.credentials.certificate') \
    -text -noout | grep -A5 "1.2.3.4.5.6.7.8.1"
```

### باستخدام fabric-ca-client:
```bash
fabric-ca-client identity list --id issuer-bcms
# يجب أن تظهر: role=issuer
```

---

## ⚠️ التحذيرات الهامة

### 1. مسح المحافظ القديمة
```
🔴 احذف جميع محافظ الهويات القديمة قبل الاختبار
   المسار: wallet/, bcms-api/src/fabric/wallet/
   السبب: الهويات القديمة لا تحتوي على سمة role
```

### 2. عدم مطابقة اسم السمة
```
🟡 تأكد من أن اسم السمة في التسجيل يطابق ما في العقد الذكي
   في التسجيل: attrs: [{ name: 'role', ... }]
   في العقد:   GetAttributeValue("role")
   يجب أن يكون: 'role' في كلا المكانين
```

### 3. نسيان :ecert
```
🔴 أخطر خطأ: تسجيل المستخدم بدون :ecert
   خاطئ:  --id.attrs "role=admin"
   صحيح:  --id.attrs "role=admin:ecert"
   
   في Node.js:
   خاطئ:  attrs: [{ name: 'role', value: 'admin' }]
   صحيح:  attrs: [{ name: 'role', value: 'admin', ecert: true }]
```

### 4. إعادة نشر Chaincode بعد التعديلات
```
🟡 بعد تعديل smartcontract.go يجب إعادة نشر الـ chaincode
   الأمر: ./network.sh deployCC -ccn basic -ccp ... -ccl go
```

---

## 🔄 مقارنة بين RBAC و ABAC

| المعيار | RBAC القديم | ABAC الجديد |
|---------|-------------|-------------|
| **آلية التحقق** | MSP ID (الشبكة) | سمة في شهادة X.509 |
| **المرونة** | محدودة (منظمات فقط) | عالية (أي سمة) |
| **الاستقلالية** | تعتمد على هيكل الشبكة | مستقلة عن هيكل الشبكة |
| **إضافة دور جديد** | يتطلب منظمة جديدة | إضافة سمة جديدة فقط |
| **RevokedBy** | `"Org1MSP"` | `"admin-bcms"` (اسم المستخدم) |
| **Header HTTP** | `X-Org-MSP` | `X-User-Role` |
| **عدد المستخدمين** | 2 منظمة | لا حد — حسب الأدوار |

---

## 📊 هيكل الملفات النهائي

```
webapp/
├── asset-transfer-basic/
│   └── chaincode-go/
│       └── chaincode/
│           └── smartcontract.go  ← ✅ ABAC فقط (RBAC محذوف)
│
├── bcms-api/
│   ├── .env.example             ← ✅ محدَّث لـ ABAC
│   ├── package.json             ← ✅ أمر enroll:abac مضاف
│   └── src/
│       └── fabric/
│           ├── gateway.js       ← ✅ role-based connections
│           ├── abacEnroll.js    ← 🆕 تسجيل مستخدمي ABAC
│           └── wallet/          ← 📁 هويات ABAC (تُنشأ بعد enroll)
│           routes/
│           └── certificates.js  ← ✅ ABAC getContract() calls
│
├── test-application/
│   └── javascript/
│       └── CAUtil.js            ← ✅ دوال ABAC مضافة
│
└── scripts/
    └── register-abac-users.sh   ← 🆕 سكربت تسجيل CA
```

---

## 🌿 إدارة الفروع

```bash
# الفرع الحالي (ABAC)
git branch
# * feature/abac-implementation

# الفرع الرئيسي (RBAC محفوظ)
git checkout fabric-RBAC
# العمل على النظام القديم لا يزال متاحاً

# العودة إلى ABAC
git checkout feature/abac-implementation

# عرض الفروع
git log --oneline --all --graph
```

### الفروع الموجودة:
- `fabric-RBAC` (main) ← النظام القديم محفوظ وسليم
- `feature/abac-implementation` ← النظام الجديد (ABAC)

---

*تم إنشاء هذا التقرير تلقائياً في: 2026-03-06*
