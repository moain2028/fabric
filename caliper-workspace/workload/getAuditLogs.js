'use strict';

const { WorkloadModuleBase } = require('@hyperledger/caliper-core');

/**
 * ══════════════════════════════════════════════════════════════════════
 *  GetAuditLogs Workload Module — BCMS Benchmark
 * ══════════════════════════════════════════════════════════════════════
 *  Function  : GetAuditLogs() → []*AuditLog
 *  RBAC      : Public read (any org can query audit trail)
 *  Guarantee : 0 failures — returns empty slice (never nil)
 * ══════════════════════════════════════════════════════════════════════
 */
class GetAuditLogsWorkload extends WorkloadModuleBase {
    constructor() {
        super();
    }

    async initializeWorkloadModule(workerIndex, totalWorkers, roundIndex, roundArguments, sutAdapter, sutContext) {
        await super.initializeWorkloadModule(workerIndex, totalWorkers, roundIndex, roundArguments, sutAdapter, sutContext);
    }

    async submitTransaction() {
        const request = {
            contractId:        'basic',
            contractFunction:  'GetAuditLogs',
            contractArguments: [],
            readOnly:          true
        };

        return this.sutAdapter.sendRequests(request);
    }

    async cleanupWorkloadModule() {}
}

module.exports = { createWorkloadModule: () => new GetAuditLogsWorkload() };
