/**
 * ============================================================================
 *  BCMS — Fabric Gateway Connection Manager (ABAC Version)
 *  إدارة اتصال Hyperledger Fabric مع دعم نظام ABAC
 *
 *  التغييرات من RBAC إلى ABAC:
 *  ────────────────────────────────────────────────────────────────────────
 *  RBAC القديم:
 *    - الاتصال يتم بناءً على المنظمة (org1 / org2)
 *    - هوية Org1 تستخدم لـ IssueCertificate
 *    - هوية Org2 تستخدم لـ RevokeCertificate
 *
 *  ABAC الجديد:
 *    - الاتصال يتم بناءً على دور المستخدم (role)
 *    - هوية admin-bcms   تستخدم لـ InitLedger, RevokeCertificate
 *    - هوية issuer-bcms  تستخدم لـ IssueCertificate, VerifyCertificate
 *    - هوية verifier-bcms تستخدم لـ VerifyCertificate
 *  ────────────────────────────────────────────────────────────────────────
 *
 *  ملاحظة: يجب تشغيل abacEnroll.js أولاً لإنشاء المحافظ (Wallets)
 * ============================================================================
 */

'use strict';

const { connect, hash, signers } = require('@hyperledger/fabric-gateway');
const grpc = require('@grpc/grpc-js');
const crypto = require('crypto');
const fs = require('fs');
const path = require('path');

// ── إعدادات الشبكة ────────────────────────────────────────────────────────────
const FABRIC_PATH = process.env.FABRIC_PATH ||
    path.resolve(__dirname, '../../../test-network');

const CHANNEL_NAME = process.env.CHANNEL_NAME || 'mychannel';
const CHAINCODE_NAME = process.env.CHAINCODE_NAME || 'basic';

// ── إعدادات Peer ─────────────────────────────────────────────────────────────
const PEER_ENDPOINT = process.env.PEER_ENDPOINT || 'localhost:7051';

const PEER0_TLS_PATH = path.join(
    FABRIC_PATH,
    'organizations/peerOrganizations/org1.example.com/peers/peer0.org1.example.com/tls/ca.crt'
);

// ── مسار المحفظة (Wallet) لهويات ABAC ───────────────────────────────────────
const WALLET_PATH = process.env.WALLET_PATH ||
    path.join(__dirname, 'wallet');

// ── مسارات MSP للمستخدمين (بديل المحفظة إذا كانت الهويات في نظام الملفات) ──
const ORG1_MSP_PATH = path.join(
    FABRIC_PATH,
    'organizations/peerOrganizations/org1.example.com'
);

// ── معرّف MSP ────────────────────────────────────────────────────────────────
const ORG_MSP_ID = 'Org1MSP';

// ── تعريف مستخدمي ABAC ───────────────────────────────────────────────────────
/**
 * roleToUserMap — تحويل الدور إلى مسار هوية المستخدم
 *
 * يدعم مصدرين للهوية:
 *   1. wallet: المحفظة المُنشأة بـ abacEnroll.js (Node.js SDK)
 *   2. msp:    مسار MSP المباشر من نظام الملفات
 */
const ABAC_USER_CONFIG = {
    admin: {
        userId: 'admin-bcms',
        certDir: path.join(ORG1_MSP_PATH, 'users/admin-bcms/msp/signcerts'),
        keyDir:  path.join(ORG1_MSP_PATH, 'users/admin-bcms/msp/keystore'),
        description: 'Admin — InitLedger, RevokeCertificate'
    },
    issuer: {
        userId: 'issuer-bcms',
        certDir: path.join(ORG1_MSP_PATH, 'users/issuer-bcms/msp/signcerts'),
        keyDir:  path.join(ORG1_MSP_PATH, 'users/issuer-bcms/msp/keystore'),
        description: 'Issuer — IssueCertificate, VerifyCertificate'
    },
    verifier: {
        userId: 'verifier-bcms',
        certDir: path.join(ORG1_MSP_PATH, 'users/verifier-bcms/msp/signcerts'),
        keyDir:  path.join(ORG1_MSP_PATH, 'users/verifier-bcms/msp/keystore'),
        description: 'Verifier — VerifyCertificate'
    }
};

// ── Connection Cache ──────────────────────────────────────────────────────────
/**
 * الكاش الآن مُفهرَس بالدور (role) بدلاً من المنظمة (org)
 * { admin: {...}, issuer: {...}, verifier: {...} }
 */
const connections = {};

// ─── Helper Functions ────────────────────────────────────────────────────────

function readFirstFileInDir(dirPath) {
    if (!fs.existsSync(dirPath)) {
        throw new Error(`Directory not found: ${dirPath}`);
    }
    const files = fs.readdirSync(dirPath);
    if (files.length === 0) {
        throw new Error(`No files in directory: ${dirPath}`);
    }
    return fs.readFileSync(path.join(dirPath, files[0]));
}

function getPrivateKey(keyDir) {
    if (!fs.existsSync(keyDir)) {
        throw new Error(`Key directory not found: ${keyDir}`);
    }
    const keyFiles = fs.readdirSync(keyDir).filter(
        f => f.endsWith('_sk') || f.endsWith('.key') || !f.includes('.')
    );
    const allFiles = fs.readdirSync(keyDir);
    const keyFile = keyFiles.length > 0 ? keyFiles[0] : allFiles[0];
    if (!keyFile) {
        throw new Error(`No private key files in: ${keyDir}`);
    }
    return fs.readFileSync(path.join(keyDir, keyFile));
}

function newGrpcConnection(peerEndpoint, tlsCertPath) {
    const tlsRootCert = fs.readFileSync(tlsCertPath);
    const tlsCredentials = grpc.credentials.createSsl(tlsRootCert);
    return new grpc.Client(peerEndpoint, tlsCredentials, {
        'grpc.ssl_target_name_override': peerEndpoint.split(':')[0]
    });
}

// ── إنشاء اتصال Gateway لمستخدم ABAC محدد ───────────────────────────────────
/**
 * createABACConnection — ينشئ اتصال Fabric Gateway لمستخدم بدور معيّن
 *
 * @param {string} role - 'admin' | 'issuer' | 'verifier'
 * @returns {Object} { gateway, network, contract, client }
 */
async function createABACConnection(role) {
    const userConfig = ABAC_USER_CONFIG[role];
    if (!userConfig) {
        throw new Error(
            `Unknown role: '${role}'. Valid roles: admin, issuer, verifier`
        );
    }

    console.log(`[Gateway] Creating connection for role='${role}' (${userConfig.userId})`);

    // ── قراءة بيانات الهوية من MSP ──────────────────────────────────────────
    let certificate, privateKey;

    // محاولة قراءة من wallet أولاً، ثم MSP directory
    const walletCertPath = path.join(WALLET_PATH, `${userConfig.userId}`);
    if (fs.existsSync(walletCertPath)) {
        // قراءة من محفظة Node.js SDK
        const walletData = JSON.parse(fs.readFileSync(walletCertPath, 'utf8'));
        certificate = Buffer.from(walletData.credentials.certificate);
        privateKey = Buffer.from(walletData.credentials.privateKey);
    } else {
        // قراءة من MSP directory مباشرة
        certificate = readFirstFileInDir(userConfig.certDir);
        privateKey = getPrivateKey(userConfig.keyDir);
    }

    // ── إنشاء gRPC Connection ────────────────────────────────────────────────
    const grpcClient = newGrpcConnection(PEER_ENDPOINT, PEER0_TLS_PATH);

    // ── إنشاء Gateway ────────────────────────────────────────────────────────
    const gateway = connect({
        client: grpcClient,
        identity: {
            mspId: ORG_MSP_ID,
            credentials: certificate
        },
        signer: signers.newPrivateKeySigner(
            crypto.createPrivateKey(privateKey)
        ),
        hash: hash.sha256
    });

    const network = gateway.getNetwork(CHANNEL_NAME);
    const contract = network.getContract(CHAINCODE_NAME);

    return { gateway, network, contract, client: grpcClient, role, userId: userConfig.userId };
}

// ── استرداد أو إنشاء اتصال مؤقت (Cached) ───────────────────────────────────
/**
 * getConnection — يسترد اتصالاً مخزّناً أو ينشئ اتصالاً جديداً
 *
 * @param {string} role - 'admin' | 'issuer' | 'verifier'
 * @returns {Object} الاتصال المخزَّن أو الجديد
 */
async function getConnection(role = 'issuer') {
    if (!connections[role]) {
        connections[role] = await createABACConnection(role);
    }
    return connections[role];
}

// ── استرداد عقد Fabric لدور معيّن ───────────────────────────────────────────
/**
 * getContract — يسترد كائن Contract لاستدعاء دوال Chaincode
 *
 * @param {string} role - 'admin' | 'issuer' | 'verifier'
 * @returns {Object} Fabric Contract
 *
 * مثال الاستخدام في routes/certificates.js:
 *   const contract = await getContract('issuer');   // لـ IssueCertificate
 *   const contract = await getContract('admin');    // لـ RevokeCertificate
 *   const contract = await getContract('verifier'); // لـ VerifyCertificate
 */
async function getContract(role = 'issuer') {
    const conn = await getConnection(role);
    return conn.contract;
}

// ── إغلاق جميع الاتصالات ─────────────────────────────────────────────────────
async function closeConnections() {
    for (const role of Object.keys(connections)) {
        if (connections[role]) {
            connections[role].gateway.close();
            connections[role].client.close();
            connections[role] = null;
        }
    }
    console.log('[Gateway] All connections closed');
}

// ── دالة مساعدة: تحديد الدور من HTTP Header ─────────────────────────────────
/**
 * getRoleFromRequest — يستخرج الدور من طلب HTTP
 *
 * يقرأ header مخصص: X-User-Role
 * القيم المقبولة: 'admin', 'issuer', 'verifier'
 *
 * @param {Object} req - Express request object
 * @param {string} defaultRole - الدور الافتراضي إذا لم يُحدَّد
 * @returns {string} الدور
 */
function getRoleFromRequest(req, defaultRole = 'verifier') {
    const role = req.headers['x-user-role'] || defaultRole;
    const validRoles = ['admin', 'issuer', 'verifier'];
    if (!validRoles.includes(role)) {
        return defaultRole;
    }
    return role;
}

module.exports = {
    getContract,
    getConnection,
    closeConnections,
    getRoleFromRequest,
    CHANNEL_NAME,
    CHAINCODE_NAME,
    ABAC_USER_CONFIG,
    ORG_MSP_ID
};
