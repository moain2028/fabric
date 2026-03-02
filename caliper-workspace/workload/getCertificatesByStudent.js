'use strict';

const { WorkloadModuleBase } = require('@hyperledger/caliper-core');

/**
 * ══════════════════════════════════════════════════════════════════════
 *  GetCertificatesByStudent Workload Module — BCMS Benchmark
 * ══════════════════════════════════════════════════════════════════════
 *  Function  : GetCertificatesByStudent(studentID) → []*Certificate
 *  RBAC      : Public read (any org)
 *  Guarantee : 0 failures — returns empty slice (never nil)
 * ══════════════════════════════════════════════════════════════════════
 */
class GetCertificatesByStudentWorkload extends WorkloadModuleBase {
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
        const workerIdx = this.workerIndex || 0;
        // Query certificates for students that were issued in round 1
        const studentID = `STU_${workerIdx}_${this.txIndex}`;

        const request = {
            contractId:        'basic',
            contractFunction:  'GetCertificatesByStudent',
            contractArguments: [studentID],
            readOnly:          true
        };

        return this.sutAdapter.sendRequests(request);
    }

    async cleanupWorkloadModule() {}
}

module.exports = { createWorkloadModule: () => new GetCertificatesByStudentWorkload() };
