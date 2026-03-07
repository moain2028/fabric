'use strict';

const { WorkloadModuleBase } = require('@hyperledger/caliper-core');
const crypto = require('crypto');

/**
 * ══════════════════════════════════════════════════════════════════════
 *  VerifyCertificate Workload Module — BCMS ABAC Benchmark v5.0
 * ══════════════════════════════════════════════════════════════════════
 *  Function  : VerifyCertificate(id, certHash) → VerificationResult
 *  ABAC      : Public read — any role (or no role attribute) accepted
 *  Guarantee : 0 failures — returns false (not error) when cert not found
 *  readOnly  : true → direct peer query, bypasses orderer for max TPS
 * ══════════════════════════════════════════════════════════════════════
 */

const DEGREE   = 'Bachelor of Computer Science';
const ISSUER   = 'Digital University';
const CONTRACT = 'basic';
const FUNCTION = 'VerifyCertificate';

class VerifyCertificateWorkload extends WorkloadModuleBase {
    constructor() {
        super();
        this.txIndex = 0;
        this.today   = '';
    }

    async initializeWorkloadModule(workerIndex, totalWorkers, roundIndex, roundArguments, sutAdapter, sutContext) {
        await super.initializeWorkloadModule(workerIndex, totalWorkers, roundIndex, roundArguments, sutAdapter, sutContext);
        this.txIndex = 0;
        this.today   = new Date().toISOString().split('T')[0];
    }

    async submitTransaction() {
        this.txIndex++;
        const w           = this.workerIndex || 0;
        const certID      = `CERT_${w}_${this.txIndex}`;
        const studentID   = `STU_${w}_${this.txIndex}`;
        const studentName = `Student_${w}_${this.txIndex}`;

        const hash = crypto.createHash('sha256');
        hash.update(studentID);
        hash.update('|');
        hash.update(studentName);
        hash.update('|');
        hash.update(DEGREE);
        hash.update('|');
        hash.update(ISSUER);
        hash.update('|');
        hash.update(this.today);
        const certHash = hash.digest('hex');

        return this.sutAdapter.sendRequests({
            contractId:        CONTRACT,
            contractFunction:  FUNCTION,
            contractArguments: [certID, certHash],
            readOnly:          true   // bypass orderer → direct peer → max TPS
        });
    }

    async cleanupWorkloadModule() {}
}

module.exports = { createWorkloadModule: () => new VerifyCertificateWorkload() };
