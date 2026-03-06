/*
 * ============================================================================
 *  BCMS — CA Utility (ABAC Version)
 *  تسجيل وإصدار شهادات المستخدمين بسمات ABAC
 *
 *  هذا الملف هو نسخة ABAC من test-application/javascript/CAUtil.js
 *  يدعم:
 *   1. تسجيل Admin عادي (بدون role attribute)
 *   2. تسجيل مستخدمين ABAC مع سمة role مضمّنة في الشهادة (ecert=true)
 * ============================================================================
 *
 * SPDX-License-Identifier: Apache-2.0
 */

'use strict';

const adminUserId = 'admin';
const adminUserPasswd = 'adminpw';

/**
 * buildCAClient — إنشاء كائن CA Client من ملف إعدادات الشبكة
 */
exports.buildCAClient = (FabricCAServices, ccp, caHostName) => {
    const caInfo = ccp.certificateAuthorities[caHostName];
    const caTLSCACerts = caInfo.tlsCACerts.pem;
    const caClient = new FabricCAServices(
        caInfo.url,
        { trustedRoots: caTLSCACerts, verify: false },
        caInfo.caName
    );
    console.log(`[CA] Built CA Client: ${caInfo.caName}`);
    return caClient;
};

/**
 * enrollAdmin — تسجيل دخول مسؤول الـ CA
 */
exports.enrollAdmin = async (caClient, wallet, orgMspId) => {
    try {
        const identity = await wallet.get(adminUserId);
        if (identity) {
            console.log('[Admin] Identity already exists in wallet — skipping');
            return;
        }

        const enrollment = await caClient.enroll({
            enrollmentID: adminUserId,
            enrollmentSecret: adminUserPasswd
        });

        const x509Identity = {
            credentials: {
                certificate: enrollment.certificate,
                privateKey: enrollment.key.toBytes(),
            },
            mspId: orgMspId,
            type: 'X.509',
        };

        await wallet.put(adminUserId, x509Identity);
        console.log('[Admin] Successfully enrolled admin and stored in wallet');
    } catch (error) {
        console.error(`[Admin] Failed to enroll admin: ${error}`);
    }
};

// ─────────────────────────────────────────────────────────────────────────────
//  registerAndEnrollUser (الدالة الأصلية — بدون ABAC)
//  مُحتفظ بها للتوافقية مع الكود القديم
// ─────────────────────────────────────────────────────────────────────────────
exports.registerAndEnrollUser = async (caClient, wallet, orgMspId, userId, affiliation) => {
    try {
        const userIdentity = await wallet.get(userId);
        if (userIdentity) {
            console.log(`[User] Identity '${userId}' already exists — skipping`);
            return;
        }

        const adminIdentity = await wallet.get(adminUserId);
        if (!adminIdentity) {
            console.log('[User] Admin identity not found — enroll admin first');
            return;
        }

        const provider = wallet.getProviderRegistry().getProvider(adminIdentity.type);
        const adminUser = await provider.getUserContext(adminIdentity, adminUserId);

        const secret = await caClient.register({
            affiliation: affiliation,
            enrollmentID: userId,
            role: 'client'
            // ملاحظة: لا attrs هنا — هذه الدالة بدون ABAC
        }, adminUser);

        const enrollment = await caClient.enroll({
            enrollmentID: userId,
            enrollmentSecret: secret
        });

        const x509Identity = {
            credentials: {
                certificate: enrollment.certificate,
                privateKey: enrollment.key.toBytes(),
            },
            mspId: orgMspId,
            type: 'X.509',
        };

        await wallet.put(userId, x509Identity);
        console.log(`[User] Successfully enrolled '${userId}' (no ABAC role)`);
    } catch (error) {
        console.error(`[User] Failed to register: ${error}`);
    }
};

// ─────────────────────────────────────────────────────────────────────────────
//  registerAndEnrollABACUser — تسجيل مستخدم مع سمة role مطبوعة في الشهادة
//
//  هذه الدالة هي قلب نظام ABAC في Node.js SDK
//
//  المعامل الحاسم: attrs مع ecert: true
//  ─────────────────────────────────────────────────────────────────────────
//  attrs: [{ name: 'role', value: roleName, ecert: true }]
//
//  ecert: true ← يجعل السمة مطبوعة داخل شهادة X.509 عند استدعاء enroll()
//              ← بدونه، السمة موجودة في CA لكن العقد الذكي لا يراها!
// ─────────────────────────────────────────────────────────────────────────────
exports.registerAndEnrollABACUser = async (
    caClient,
    wallet,
    orgMspId,
    userId,
    affiliation,
    roleName    // 'admin' | 'issuer' | 'verifier'
) => {
    try {
        // ── التحقق من عدم وجود الهوية مسبقاً ──────────────────────────────
        const userIdentity = await wallet.get(userId);
        if (userIdentity) {
            console.log(`[ABAC] Identity '${userId}' already exists in wallet`);
            return;
        }

        // ── التحقق من وجود هوية المسؤول ────────────────────────────────────
        const adminIdentity = await wallet.get(adminUserId);
        if (!adminIdentity) {
            console.log('[ABAC] Admin identity not found — run enrollAdmin() first');
            return;
        }

        const provider = wallet.getProviderRegistry().getProvider(adminIdentity.type);
        const adminUser = await provider.getUserContext(adminIdentity, adminUserId);

        // ── ▼ التسجيل مع سمة role (ABAC) ▼ ─────────────────────────────────
        console.log(`[ABAC] Registering '${userId}' with role='${roleName}'...`);

        const secret = await caClient.register(
            {
                affiliation: affiliation,
                enrollmentID: userId,
                role: 'client',

                // ═══════════════════════════════════════════════════════════
                //  attrs — مصفوفة السمات الأساسية لنظام ABAC
                //
                //  كل سمة تحتوي على:
                //    name  : اسم السمة (يجب مطابقة ما يقرأه العقد الذكي)
                //    value : قيمة السمة
                //    ecert : true ← يطبع السمة في شهادة X.509
                //
                //  في العقد الذكي:
                //    role, found, err := ctx.GetClientIdentity().GetAttributeValue("role")
                //    // role = 'admin' | 'issuer' | 'verifier'
                // ═══════════════════════════════════════════════════════════
                attrs: [
                    {
                        name: 'role',       // يطابق "role" في GetAttributeValue("role")
                        value: roleName,    // 'admin' | 'issuer' | 'verifier'
                        ecert: true         // ← لا تنسَ هذا!
                    }
                    // يمكن إضافة سمات إضافية:
                    // { name: 'department', value: 'university-registrar', ecert: true }
                ]
                // ═══════════════════════════════════════════════════════════
            },
            adminUser
        );
        // ▲ ────────────────────────────────────────────────────────────────

        // ── استخراج الشهادة (Enroll) ────────────────────────────────────────
        console.log(`[ABAC] Enrolling '${userId}'...`);

        const enrollment = await caClient.enroll({
            enrollmentID: userId,
            enrollmentSecret: secret
        });

        // ── تخزين في المحفظة ────────────────────────────────────────────────
        const x509Identity = {
            credentials: {
                certificate: enrollment.certificate,
                privateKey: enrollment.key.toBytes(),
            },
            mspId: orgMspId,
            type: 'X.509',
        };

        await wallet.put(userId, x509Identity);
        console.log(`[ABAC] ✓ '${userId}' enrolled with role='${roleName}' (ecert=true)`);
        console.log(`[ABAC]   Certificate stored in wallet`);

    } catch (error) {
        console.error(`[ABAC] Failed to register '${userId}': ${error}`);
        throw error;
    }
};

// ─────────────────────────────────────────────────────────────────────────────
//  enrollAllABACUsers — تسجيل جميع المستخدمين المطلوبين لنظام ABAC
//  دالة مساعدة لتسجيل Admin, Issuer, Verifier دفعة واحدة
// ─────────────────────────────────────────────────────────────────────────────
exports.enrollAllABACUsers = async (caClient, wallet, orgMspId, affiliation = 'org1.department1') => {
    const users = [
        { userId: 'admin-bcms',    role: 'admin',    description: 'BCMS Admin' },
        { userId: 'issuer-bcms',   role: 'issuer',   description: 'BCMS Issuer' },
        { userId: 'verifier-bcms', role: 'verifier', description: 'BCMS Verifier' }
    ];

    console.log('[ABAC] Enrolling all ABAC users...');
    for (const user of users) {
        console.log(`\n[ABAC] Processing: ${user.description} (${user.userId})`);
        await exports.registerAndEnrollABACUser(
            caClient, wallet, orgMspId,
            user.userId, affiliation, user.role
        );
    }
    console.log('\n[ABAC] All ABAC users enrolled successfully');
};
