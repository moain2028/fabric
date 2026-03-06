/**
 * ============================================================================
 *  BCMS — ABAC User Registration & Enrollment Utility
 *  نظام ABAC: تسجيل المستخدمين بسمات الأدوار عبر Node.js SDK
 *
 *  هذا الملف يوضح كيفية تسجيل المستخدمين مع سمة role مضمّنة في الشهادة.
 *  يجب استبدال هذا الملف بـ test-application/javascript/CAUtil.js
 *  أو إضافته كملف منفصل: bcms-api/src/fabric/abacEnroll.js
 *
 *  الاستخدام:
 *    node abacEnroll.js
 *
 *  المتطلبات:
 *    npm install fabric-ca-client fabric-network
 * ============================================================================
 */

'use strict';

const FabricCAServices = require('fabric-ca-client');
const { Wallets } = require('fabric-network');
const fs = require('fs');
const path = require('path');

// ── إعدادات الشبكة ────────────────────────────────────────────────────────────
const FABRIC_PATH = process.env.FABRIC_PATH ||
    path.resolve(__dirname, '../../../test-network');

const CCP_PATH = path.join(
    FABRIC_PATH,
    'organizations/peerOrganizations/org1.example.com/connection-org1.json'
);

const WALLET_PATH = path.join(__dirname, 'wallet');
const CA_HOST_NAME = 'ca.org1.example.com';
const ORG_MSP_ID = 'Org1MSP';
const ADMIN_USER_ID = 'admin';
const ADMIN_USER_PASSWD = 'adminpw';

// ── تعريف المستخدمين المطلوب إنشاؤهم ────────────────────────────────────────
/**
 * كل مستخدم يحتوي على:
 *   - userId     : اسم الهوية في المحفظة (Wallet)
 *   - enrollmentID : اسم التسجيل في CA
 *   - secret     : كلمة المرور في CA
 *   - role       : قيمة سمة الدور (admin / issuer / verifier)
 *   - affiliation : انتماء المستخدم في CA
 */
const ABAC_USERS = [
    {
        userId: 'admin-bcms',
        enrollmentID: 'admin-bcms',
        secret: 'admin-bcms-pw',
        role: 'admin',
        affiliation: 'org1.department1',
        description: 'BCMS Admin — InitLedger, RevokeCertificate'
    },
    {
        userId: 'issuer-bcms',
        enrollmentID: 'issuer-bcms',
        secret: 'issuer-bcms-pw',
        role: 'issuer',
        affiliation: 'org1.department1',
        description: 'BCMS Issuer — IssueCertificate, VerifyCertificate'
    },
    {
        userId: 'verifier-bcms',
        enrollmentID: 'verifier-bcms',
        secret: 'verifier-bcms-pw',
        role: 'verifier',
        affiliation: 'org1.department1',
        description: 'BCMS Verifier — VerifyCertificate'
    }
];

// ─────────────────────────────────────────────────────────────────────────────
//  الدالة الرئيسية: buildCAClient
//  تُنشئ كائن FabricCAServices من ملف إعدادات الشبكة (CCP)
// ─────────────────────────────────────────────────────────────────────────────
function buildCAClient(FabricCAServices, ccp, caHostName) {
    const caInfo = ccp.certificateAuthorities[caHostName];
    if (!caInfo) {
        throw new Error(`CA host '${caHostName}' not found in connection profile`);
    }
    const caTLSCACerts = caInfo.tlsCACerts.pem;
    const caClient = new FabricCAServices(
        caInfo.url,
        { trustedRoots: caTLSCACerts, verify: false },
        caInfo.caName
    );
    console.log(`[CA] Built CA Client: ${caInfo.caName}`);
    return caClient;
}

// ─────────────────────────────────────────────────────────────────────────────
//  enrollAdmin — تسجيل دخول المسؤول الرئيسي للـ CA
// ─────────────────────────────────────────────────────────────────────────────
async function enrollAdmin(caClient, wallet) {
    const identity = await wallet.get(ADMIN_USER_ID);
    if (identity) {
        console.log(`[Admin] Identity '${ADMIN_USER_ID}' already exists in wallet — skipping`);
        return;
    }

    const enrollment = await caClient.enroll({
        enrollmentID: ADMIN_USER_ID,
        enrollmentSecret: ADMIN_USER_PASSWD
    });

    const x509Identity = {
        credentials: {
            certificate: enrollment.certificate,
            privateKey: enrollment.key.toBytes(),
        },
        mspId: ORG_MSP_ID,
        type: 'X.509',
    };

    await wallet.put(ADMIN_USER_ID, x509Identity);
    console.log(`[Admin] Successfully enrolled '${ADMIN_USER_ID}' and stored in wallet`);
}

// ─────────────────────────────────────────────────────────────────────────────
//  registerAndEnrollABACUser — تسجيل وإصدار شهادة لمستخدم بسمة ABAC
//
//  النقطة الحاسمة: مصفوفة attrs مع ecert: true
//  ─────────────────────────────────────────────────────────────────────────
//  attrs: [{ name: 'role', value: 'issuer', ecert: true }]
//
//  ecert: true  ← يضمن طبع السمة داخل شهادة X.509 عند التسجيل (Enroll)
//               ← بدون هذا الخيار، السمة موجودة في CA لكن ليست في الشهادة
//               ← العقد الذكي (chaincode) لن يتمكن من قراءتها!
// ─────────────────────────────────────────────────────────────────────────────
async function registerAndEnrollABACUser(caClient, wallet, userConfig) {
    const { userId, enrollmentID, secret, role, affiliation, description } = userConfig;

    // ── التحقق من عدم وجود الهوية مسبقاً ──────────────────────────────────
    const existingIdentity = await wallet.get(userId);
    if (existingIdentity) {
        console.log(`[SKIP] Identity '${userId}' already exists in wallet`);
        console.log(`       Role: ${role} | ${description}`);
        return;
    }

    // ── التحقق من وجود هوية المسؤول ────────────────────────────────────────
    const adminIdentity = await wallet.get(ADMIN_USER_ID);
    if (!adminIdentity) {
        throw new Error(
            `Admin identity not found in wallet. Run enrollAdmin() first.`
        );
    }

    const provider = wallet.getProviderRegistry().getProvider(adminIdentity.type);
    const adminUser = await provider.getUserContext(adminIdentity, ADMIN_USER_ID);

    // ── تسجيل المستخدم في CA مع سمة role ──────────────────────────────────
    console.log(`\n[REGISTER] Registering '${userId}' with role='${role}'...`);

    const registeredSecret = await caClient.register(
        {
            affiliation: affiliation,
            enrollmentID: enrollmentID,
            role: 'client',

            // ── ▼ السمات (Attributes) — هذا هو المفتاح الأساسي لـ ABAC ▼ ──────
            attrs: [
                {
                    name: 'role',       // اسم السمة — يجب أن يطابق ما يقرأه العقد الذكي
                    value: role,        // قيمة السمة: 'admin' | 'issuer' | 'verifier'
                    ecert: true         // ← الأهم: طبع السمة داخل شهادة X.509
                    //
                    // ecert: true يعني:
                    //   عند استدعاء caClient.enroll()، سيتم تضمين هذه السمة
                    //   في ملحق (Extension) داخل شهادة X.509 المُولَّدة.
                    //   يمكن للعقد الذكي قراءتها عبر:
                    //   ctx.GetClientIdentity().GetAttributeValue("role")
                }
                // يمكن إضافة سمات إضافية هنا:
                // { name: 'department', value: 'registrar', ecert: true }
                // { name: 'university', value: 'KFU', ecert: true }
            ]
            // ──────────────────────────────────────────────────────────────────
        },
        adminUser
    );

    // ── استخراج الشهادة (Enroll) ────────────────────────────────────────────
    console.log(`[ENROLL]   Enrolling '${userId}'...`);

    const enrollment = await caClient.enroll({
        enrollmentID: enrollmentID,
        enrollmentSecret: registeredSecret
        // ملاحظة: لا حاجة لتحديد attrs هنا — السمة ستُضمَّن تلقائياً
        // لأن ecert=true تم تحديدها في مرحلة register
    });

    // ── تخزين الهوية في المحفظة (Wallet) ────────────────────────────────────
    const x509Identity = {
        credentials: {
            certificate: enrollment.certificate,
            privateKey: enrollment.key.toBytes(),
        },
        mspId: ORG_MSP_ID,
        type: 'X.509',
    };

    await wallet.put(userId, x509Identity);

    console.log(`[OK]       '${userId}' registered & enrolled successfully`);
    console.log(`           Role: ${role} | ${description}`);
    console.log(`           Certificate stored in wallet: ${WALLET_PATH}`);
}

// ─────────────────────────────────────────────────────────────────────────────
//  getWalletIdentityForUser — استرداد هوية مستخدم من المحفظة للاستخدام في Gateway
// ─────────────────────────────────────────────────────────────────────────────
async function getWalletIdentityForUser(userId) {
    const wallet = await Wallets.newFileSystemWallet(WALLET_PATH);
    const identity = await wallet.get(userId);
    if (!identity) {
        throw new Error(`Identity '${userId}' not found in wallet. Run enrollment first.`);
    }
    return identity;
}

// ─────────────────────────────────────────────────────────────────────────────
//  Main — الدالة الرئيسية لتشغيل التسجيل
// ─────────────────────────────────────────────────────────────────────────────
async function main() {
    console.log('='.repeat(60));
    console.log('  BCMS — ABAC Identity Enrollment');
    console.log('='.repeat(60));

    // ── ⚠️ تحذير: مسح المحفظة القديمة ──────────────────────────────────────
    console.log('\n[WARNING] If upgrading from RBAC to ABAC:');
    console.log('          Delete the old wallet before proceeding!');
    console.log(`          rm -rf ${WALLET_PATH}`);
    console.log('');

    // ── تحميل ملف إعدادات الشبكة ────────────────────────────────────────────
    if (!fs.existsSync(CCP_PATH)) {
        throw new Error(
            `Connection profile not found: ${CCP_PATH}\n` +
            `Make sure the test-network is running.`
        );
    }

    const ccpContent = fs.readFileSync(CCP_PATH, 'utf8');
    const ccp = JSON.parse(ccpContent);
    console.log(`[CCP] Loaded connection profile from ${CCP_PATH}`);

    // ── إنشاء CA Client ──────────────────────────────────────────────────────
    const caClient = buildCAClient(FabricCAServices, ccp, CA_HOST_NAME);

    // ── إنشاء المحفظة ────────────────────────────────────────────────────────
    if (!fs.existsSync(WALLET_PATH)) {
        fs.mkdirSync(WALLET_PATH, { recursive: true });
    }
    const wallet = await Wallets.newFileSystemWallet(WALLET_PATH);
    console.log(`[Wallet] File system wallet at: ${WALLET_PATH}`);

    // ── تسجيل دخول المسؤول ──────────────────────────────────────────────────
    await enrollAdmin(caClient, wallet);

    // ── تسجيل جميع مستخدمي ABAC ─────────────────────────────────────────────
    console.log('\n[INFO] Registering ABAC users...');
    for (const userConfig of ABAC_USERS) {
        try {
            await registerAndEnrollABACUser(caClient, wallet, userConfig);
        } catch (err) {
            console.error(`[ERROR] Failed to register '${userConfig.userId}': ${err.message}`);
        }
    }

    console.log('\n' + '='.repeat(60));
    console.log('  Enrollment Summary:');
    console.log('='.repeat(60));
    for (const userConfig of ABAC_USERS) {
        const identity = await wallet.get(userConfig.userId);
        const status = identity ? '✓ Ready' : '✗ Failed';
        console.log(`  ${status}  ${userConfig.userId.padEnd(20)} role=${userConfig.role}`);
    }
    console.log('='.repeat(60));
    console.log('\n[DONE] ABAC enrollment complete.\n');
}

// ── تصدير الدوال للاستخدام من ملفات أخرى ────────────────────────────────────
module.exports = {
    buildCAClient,
    enrollAdmin,
    registerAndEnrollABACUser,
    getWalletIdentityForUser,
    ABAC_USERS,
    WALLET_PATH,
    ORG_MSP_ID
};

// ── تشغيل الدالة الرئيسية إذا تم استدعاء الملف مباشرة ─────────────────────
if (require.main === module) {
    main().catch(err => {
        console.error('[FATAL]', err);
        process.exit(1);
    });
}
