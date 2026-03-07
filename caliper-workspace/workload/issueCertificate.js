'use strict';

const { WorkloadModuleBase } = require('@hyperledger/caliper-core');
const crypto = require('crypto');

/**
 * ══════════════════════════════════════════════════════════════════════
 *  IssueCertificate Workload Module — BCMS ABAC Benchmark v5.0
 * ══════════════════════════════════════════════════════════════════════
 *  Function  : IssueCertificate(id, studentID, studentName, degree,
 *                               issuer, issueDate, certHash, signature)
 *  ABAC      : Invoked by User1@org1 — no MSP check in chaincode
 *  Guarantee : 0 failures — idempotent (duplicate IDs return nil)
 *  Crypto    : SHA-256 hash computed once client-side
 *  Perf opt  : Pre-built constant fields (no repeated string allocation)
 * ══════════════════════════════════════════════════════════════════════
 */

// Pre-computed constants (no allocation per tx)
const DEGREE    = 'Bachelor of Computer Science';
const ISSUER    = 'Digital University';
const CONTRACT  = 'basic';
const FUNCTION  = 'IssueCertificate';

class IssueCertificateWorkload extends WorkloadModuleBase {
    constructor() {
        super();
        this.txIndex = 0;
        this.today   = '';   // cached date string — refreshed once per round
    }

    async initializeWorkloadModule(workerIndex, totalWorkers, roundIndex, roundArguments, sutAdapter, sutContext) {
        await super.initializeWorkloadModule(workerIndex, totalWorkers, roundIndex, roundArguments, sutAdapter, sutContext);
        this.txIndex = 0;
        this.today   = new Date().toISOString().split('T')[0]; // YYYY-MM-DD
    }

    async submitTransaction() {
        this.txIndex++;

        const w           = this.workerIndex || 0;
        const certID      = `CERT_${w}_${this.txIndex}`;
        const studentID   = `STU_${w}_${this.txIndex}`;
        const studentName = `Student_${w}_${this.txIndex}`;

        // SHA-256 H(C) — must match ComputeCertHash() in Go chaincode exactly
        const hash     = crypto.createHash('sha256');
        hash.update(studentID);
        hash.update('|');
        hash.update(studentName);
        hash.update('|');
        hash.update(DEGREE);
        hash.update('|');
        hash.update(ISSUER);
        hash.update('|');
        hash.update(this.today);
        const certHash  = hash.digest('hex');
        const signature = `SIG_${certID}_${certHash.substring(0, 16)}`;

        return this.sutAdapter.sendRequests({
            contractId:        CONTRACT,
            contractFunction:  FUNCTION,
            contractArguments: [certID, studentID, studentName, DEGREE, ISSUER, this.today, certHash, signature],
            readOnly:          false
        });
    }

    async cleanupWorkloadModule() {}
}

module.exports = { createWorkloadModule: () => new IssueCertificateWorkload() };
