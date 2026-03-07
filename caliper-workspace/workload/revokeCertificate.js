'use strict';

const { WorkloadModuleBase } = require('@hyperledger/caliper-core');

/**
 * ══════════════════════════════════════════════════════════════════════
 *  RevokeCertificate Workload Module — BCMS ABAC Benchmark v5.0
 * ══════════════════════════════════════════════════════════════════════
 *  Function  : RevokeCertificate(id) → error
 *  ABAC      : role=admin or role=issuer required in X.509 ecert
 *  NOTE      : User1@org2 is used as invoker (standard, no role attr)
 *              For a full ABAC test with Verifier1@org2 use that identity.
 *              Zero-failure: nil when cert not found or already revoked.
 * ══════════════════════════════════════════════════════════════════════
 */

const CONTRACT = 'basic';
const FUNCTION = 'RevokeCertificate';

class RevokeCertificateWorkload extends WorkloadModuleBase {
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
        const w      = this.workerIndex || 0;
        const certID = `CERT_${w}_${this.txIndex}`;

        return this.sutAdapter.sendRequests({
            contractId:        CONTRACT,
            contractFunction:  FUNCTION,
            contractArguments: [certID],
            readOnly:          false
        });
    }

    async cleanupWorkloadModule() {}
}

module.exports = { createWorkloadModule: () => new RevokeCertificateWorkload() };
