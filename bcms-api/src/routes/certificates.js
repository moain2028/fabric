/**
 * ============================================================================
 *  BCMS — Certificate Routes (ABAC Version)
 *  REST API endpoints for certificate management
 *
 *  التغييرات من RBAC إلى ABAC:
 *  ────────────────────────────────────────────────────────────────────────
 *  RBAC القديم:
 *    - POST /certificates    → getContract('org1')  [Org1MSP فقط]
 *    - DELETE /certificates  → getContract('org2')  [بناءً على X-Org-MSP header]
 *    - GET /certificates     → getContract('org1')  [ثابت]
 *
 *  ABAC الجديد:
 *    - POST /certificates    → getContract('issuer')  [role=issuer]
 *    - DELETE /certificates  → getContract('admin')   [role=admin]
 *    - POST /verify          → getContract('verifier')| getContract('issuer')
 *    - GET /certificates     → getContract('issuer')  [عام]
 *  ────────────────────────────────────────────────────────────────────────
 *
 *  يدعم header مخصص: X-User-Role لتحديد الدور في الطلب
 * ============================================================================
 */

'use strict';

const express = require('express');
const router = express.Router();
const crypto = require('crypto');
const { body, param, validationResult } = require('express-validator');
const { getContract, getRoleFromRequest } = require('../fabric/gateway');

// ── Helper: Compute SHA-256 hash matching chaincode logic ─────────────────────
// H(C) = SHA256(studentID|studentName|degree|issuer|issueDate)
function computeCertHash(studentID, studentName, degree, issuer, issueDate) {
    const data = [studentID, studentName, degree, issuer, issueDate].join('|');
    return crypto.createHash('sha256').update(data).digest('hex');
}

// ── Helper: Handle validation errors ─────────────────────────────────────────
function handleValidation(req, res) {
    const errors = validationResult(req);
    if (!errors.isEmpty()) {
        res.status(400).json({
            success: false,
            errors: errors.array()
        });
        return true;
    }
    return false;
}

// ── Helper: Parse Fabric response ─────────────────────────────────────────────
function parseResponse(result) {
    if (!result || result.length === 0) return null;
    try {
        return JSON.parse(Buffer.from(result).toString());
    } catch {
        return Buffer.from(result).toString();
    }
}

// ─────────────────────────────────────────────────────────────────────────────
//  POST /api/v1/certificates — Issue a new certificate
//  ABAC: يُستخدم دور 'issuer' — يجب على المستخدم امتلاك role=issuer في شهادته
//
//  Header مطلوب: X-User-Role: issuer
//  (أو يستخدم الافتراضي 'issuer' تلقائياً)
// ─────────────────────────────────────────────────────────────────────────────
router.post('/',
    [
        body('id').notEmpty().withMessage('Certificate ID is required'),
        body('studentID').notEmpty().withMessage('Student ID is required'),
        body('studentName').notEmpty().withMessage('Student name is required'),
        body('degree').notEmpty().withMessage('Degree is required'),
        body('issuer').notEmpty().withMessage('Issuer is required'),
        body('issueDate').notEmpty().withMessage('Issue date is required')
    ],
    async (req, res) => {
        if (handleValidation(req, res)) return;

        const { id, studentID, studentName, degree, issuer, issueDate, signature } = req.body;

        try {
            // حساب SHA-256 hash مطابق لـ chaincode
            const certHash = computeCertHash(studentID, studentName, degree, issuer, issueDate);
            const sig = signature || `SIG_${id}_${certHash.substring(0, 16)}`;

            // ABAC: استخدام هوية المُصدِر (issuer) للعملية
            const contract = await getContract('issuer');
            const startTime = Date.now();

            await contract.submitTransaction(
                'IssueCertificate',
                id, studentID, studentName, degree, issuer, issueDate, certHash, sig
            );

            const duration = Date.now() - startTime;

            res.status(201).json({
                success: true,
                message: 'Certificate issued successfully',
                accessControl: { model: 'ABAC', role: 'issuer' },
                data: {
                    id, studentID, studentName, degree,
                    issuer, issueDate, certHash, signature: sig
                },
                performance: { duration_ms: duration },
                timestamp: new Date().toISOString()
            });
        } catch (err) {
            res.status(500).json({
                success: false,
                error: err.message,
                hint: 'Ensure issuer-bcms identity is enrolled with role=issuer:ecert',
                timestamp: new Date().toISOString()
            });
        }
    }
);

// ── GET /api/v1/certificates — Get all certificates ──────────────────────────
// لا تتطلب دوراً محدداً — متاحة للجميع
router.get('/', async (req, res) => {
    try {
        const contract = await getContract('issuer');
        const startTime = Date.now();

        const result = await contract.evaluateTransaction('QueryAllCertificates');
        const duration = Date.now() - startTime;

        const certificates = parseResponse(result) || [];

        res.json({
            success: true,
            count: certificates.length,
            data: certificates,
            performance: { duration_ms: duration },
            timestamp: new Date().toISOString()
        });
    } catch (err) {
        res.status(500).json({
            success: false,
            error: err.message,
            timestamp: new Date().toISOString()
        });
    }
});

// ── GET /api/v1/certificates/:id — Get single certificate ────────────────────
router.get('/:id',
    [param('id').notEmpty()],
    async (req, res) => {
        if (handleValidation(req, res)) return;

        try {
            const contract = await getContract('issuer');
            const result = await contract.evaluateTransaction('ReadCertificate', req.params.id);
            const cert = parseResponse(result);

            if (!cert) {
                return res.status(404).json({
                    success: false,
                    error: `Certificate ${req.params.id} not found`
                });
            }

            res.json({
                success: true,
                data: cert,
                timestamp: new Date().toISOString()
            });
        } catch (err) {
            if (err.message && err.message.includes('does not exist')) {
                return res.status(404).json({
                    success: false,
                    error: `Certificate ${req.params.id} not found`
                });
            }
            res.status(500).json({
                success: false,
                error: err.message,
                timestamp: new Date().toISOString()
            });
        }
    }
);

// ─────────────────────────────────────────────────────────────────────────────
//  POST /api/v1/certificates/:id/verify — Verify a certificate
//  ABAC: يُسمح لـ verifier أو issuer أو admin
//
//  Header اختياري: X-User-Role: verifier | issuer | admin
//  الافتراضي: 'verifier'
// ─────────────────────────────────────────────────────────────────────────────
router.post('/:id/verify',
    [
        param('id').notEmpty(),
        body('certHash').optional()
    ],
    async (req, res) => {
        if (handleValidation(req, res)) return;

        const { certHash, studentID, studentName, degree, issuer, issueDate } = req.body;

        try {
            let hashToVerify = certHash;
            if (!hashToVerify && studentID && studentName && degree && issuer && issueDate) {
                hashToVerify = computeCertHash(studentID, studentName, degree, issuer, issueDate);
            }
            if (!hashToVerify) {
                return res.status(400).json({
                    success: false,
                    error: 'Either certHash or all certificate fields must be provided'
                });
            }

            // ABAC: استخدام الدور من Header أو الافتراضي 'verifier'
            // الأدوار المسموح بها: verifier, issuer, admin
            const role = getRoleFromRequest(req, 'verifier');
            const validVerifyRoles = ['verifier', 'issuer', 'admin'];
            const verifyRole = validVerifyRoles.includes(role) ? role : 'verifier';

            const contract = await getContract(verifyRole);
            const startTime = Date.now();

            const result = await contract.evaluateTransaction(
                'VerifyCertificate',
                req.params.id,
                hashToVerify
            );
            const duration = Date.now() - startTime;

            const verificationResult = parseResponse(result);

            res.json({
                success: true,
                accessControl: { model: 'ABAC', role: verifyRole },
                data: verificationResult,
                performance: { duration_ms: duration },
                timestamp: new Date().toISOString()
            });
        } catch (err) {
            res.status(500).json({
                success: false,
                error: err.message,
                timestamp: new Date().toISOString()
            });
        }
    }
);

// ─────────────────────────────────────────────────────────────────────────────
//  DELETE /api/v1/certificates/:id — Revoke a certificate
//  ABAC: يتطلب role=admin — يجب استخدام هوية admin-bcms
//
//  Header مطلوب: X-User-Role: admin
//  ملاحظة: في ABAC لا نحتاج X-Org-MSP — نستخدم X-User-Role بدلاً منه
// ─────────────────────────────────────────────────────────────────────────────
router.delete('/:id',
    [param('id').notEmpty()],
    async (req, res) => {
        if (handleValidation(req, res)) return;

        try {
            // ABAC: استخدام هوية المسؤول (admin) للإلغاء
            // لا نحتاج X-Org-MSP header بعد الآن
            const contract = await getContract('admin');
            const startTime = Date.now();

            await contract.submitTransaction('RevokeCertificate', req.params.id);
            const duration = Date.now() - startTime;

            res.json({
                success: true,
                message: `Certificate ${req.params.id} revoked successfully`,
                accessControl: { model: 'ABAC', role: 'admin' },
                performance: { duration_ms: duration },
                timestamp: new Date().toISOString()
            });
        } catch (err) {
            res.status(500).json({
                success: false,
                error: err.message,
                hint: 'Ensure admin-bcms identity is enrolled with role=admin:ecert',
                timestamp: new Date().toISOString()
            });
        }
    }
);

// ── GET /api/v1/certificates/student/:studentID — Get by student ──────────────
router.get('/student/:studentID',
    [param('studentID').notEmpty()],
    async (req, res) => {
        if (handleValidation(req, res)) return;

        try {
            const contract = await getContract('issuer');
            const result = await contract.evaluateTransaction(
                'GetCertificatesByStudent',
                req.params.studentID
            );
            const certificates = parseResponse(result) || [];

            res.json({
                success: true,
                studentID: req.params.studentID,
                count: certificates.length,
                data: certificates,
                timestamp: new Date().toISOString()
            });
        } catch (err) {
            res.status(500).json({
                success: false,
                error: err.message,
                timestamp: new Date().toISOString()
            });
        }
    }
);

// ── GET /api/v1/certificates/issuer/:issuer — Get by issuer ──────────────────
router.get('/issuer/:issuer',
    [param('issuer').notEmpty()],
    async (req, res) => {
        if (handleValidation(req, res)) return;

        try {
            const contract = await getContract('issuer');
            const result = await contract.evaluateTransaction(
                'GetCertificatesByIssuer',
                req.params.issuer
            );
            const certificates = parseResponse(result) || [];

            res.json({
                success: true,
                issuer: req.params.issuer,
                count: certificates.length,
                data: certificates,
                timestamp: new Date().toISOString()
            });
        } catch (err) {
            res.status(500).json({
                success: false,
                error: err.message,
                timestamp: new Date().toISOString()
            });
        }
    }
);

// ── GET /api/v1/certificates/:id/history — Get certificate history ────────────
router.get('/:id/history',
    [param('id').notEmpty()],
    async (req, res) => {
        if (handleValidation(req, res)) return;

        try {
            const contract = await getContract('issuer');
            const result = await contract.evaluateTransaction(
                'GetCertificateHistory',
                req.params.id
            );
            const history = parseResponse(result) || [];

            res.json({
                success: true,
                certID: req.params.id,
                count: Array.isArray(history) ? history.length : 0,
                data: history,
                timestamp: new Date().toISOString()
            });
        } catch (err) {
            res.status(500).json({
                success: false,
                error: err.message,
                timestamp: new Date().toISOString()
            });
        }
    }
);

// ── POST /api/v1/certificates/hash/compute — Compute certificate hash ─────────
router.post('/hash/compute',
    [
        body('studentID').notEmpty(),
        body('studentName').notEmpty(),
        body('degree').notEmpty(),
        body('issuer').notEmpty(),
        body('issueDate').notEmpty()
    ],
    (req, res) => {
        if (handleValidation(req, res)) return;

        const { studentID, studentName, degree, issuer, issueDate } = req.body;
        const certHash = computeCertHash(studentID, studentName, degree, issuer, issueDate);

        res.json({
            success: true,
            data: {
                certHash,
                algorithm: 'SHA-256',
                input: `${studentID}|${studentName}|${degree}|${issuer}|${issueDate}`
            },
            timestamp: new Date().toISOString()
        });
    }
);

module.exports = router;
