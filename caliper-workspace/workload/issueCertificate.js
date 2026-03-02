'use strict';

const { WorkloadModuleBase } = require('@hyperledger/caliper-core');
const crypto = require('crypto');

/**
 * ══════════════════════════════════════════════════════════════════════
 *  IssueCertificate Workload Module — BCMS Benchmark
 * ══════════════════════════════════════════════════════════════════════
 *  Function  : IssueCertificate(id, studentID, studentName, degree,
 *                               issuer, issueDate, certHash, signature)
 *  RBAC      : Org1MSP only (invokerIdentity: User1@org1.example.com)
 *  Guarantee : 0 failures — idempotent (duplicate IDs return nil)
 *  Crypto    : SHA-256 hash computed client-side matching chaincode logic
 * ══════════════════════════════════════════════════════════════════════
 */
class IssueCertificateWorkload extends WorkloadModuleBase {
    constructor() {
        super();
        this.txIndex = 0;
    }

    async initializeWorkloadModule(workerIndex, totalWorkers, roundIndex, roundArguments, sutAdapter, sutContext) {
        await super.initializeWorkloadModule(workerIndex, totalWorkers, roundIndex, roundArguments, sutAdapter, sutContext);
        this.txIndex = 0;
    }

    async submitTransaction() {
        this.txIndex++;

        const workerIdx   = this.workerIndex || 0;
        const certID      = `CERT_${workerIdx}_${this.txIndex}`;
        const studentID   = `STU_${workerIdx}_${this.txIndex}`;
        const studentName = `Student_${workerIdx}_${this.txIndex}`;
        const degree      = 'Bachelor of Computer Science';
        const issuer      = 'Digital University';
        const issueDate   = new Date().toISOString().split('T')[0];

        // SHA-256 H(C) = SHA256(studentID || studentName || degree || issuer || issueDate)
        // Must match ComputeCertHash() in Go chaincode exactly
        const fields   = [studentID, studentName, degree, issuer, issueDate].join('|');
        const certHash = crypto.createHash('sha256').update(fields).digest('hex');
        const signature = `SIG_${certID}_${certHash.substring(0, 16)}`;

        const request = {
            contractId:        'basic',
            contractFunction:  'IssueCertificate',
            // Args must match Go func signature EXACTLY:
            // (id, studentID, studentName, degree, issuer, issueDate, certHash, signature)
            contractArguments: [
                certID,
                studentID,
                studentName,
                degree,
                issuer,
                issueDate,
                certHash,
                signature
            ],
            readOnly: false
        };

        return this.sutAdapter.sendRequests(request);
    }

    async cleanupWorkloadModule() {
        // No cleanup needed — idempotent design
    }
}

module.exports = { createWorkloadModule: () => new IssueCertificateWorkload() };
