'use strict';

const { WorkloadModuleBase } = require('@hyperledger/caliper-core');
const crypto = require('crypto');

/**
 * ══════════════════════════════════════════════════════════════════════
 *  VerifyCertificate Workload Module — BCMS Benchmark
 * ══════════════════════════════════════════════════════════════════════
 *  Function  : VerifyCertificate(id, certHash) → VerificationResult
 *  RBAC      : Public (any org — readOnly query)
 *  Guarantee : 0 failures — returns false (not error) when cert not found
 *  Crypto    : SHA-256 hash computed client-side matching chaincode logic
 * ══════════════════════════════════════════════════════════════════════
 */
class VerifyCertificateWorkload extends WorkloadModuleBase {
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

        // MUST match exact hash logic in chaincode ComputeCertHash()
        const fields   = [studentID, studentName, degree, issuer, issueDate].join('|');
        const certHash = crypto.createHash('sha256').update(fields).digest('hex');

        const request = {
            contractId:        'basic',
            contractFunction:  'VerifyCertificate',
            // Args: (id, certHash)
            contractArguments: [certID, certHash],
            readOnly:          true    // bypass orderer — direct peer query for max TPS
        };

        return this.sutAdapter.sendRequests(request);
    }

    async cleanupWorkloadModule() {
        // No cleanup needed
    }
}

module.exports = { createWorkloadModule: () => new VerifyCertificateWorkload() };
