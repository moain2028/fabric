/**
 * ============================================================================
 *  BCMS — Audit Log Routes
 *  REST API endpoints for querying the immutable audit trail
 * ============================================================================
 */

'use strict';

const express = require('express');
const router = express.Router();
const { getContract } = require('../fabric/gateway');

function parseResponse(result) {
    if (!result || result.length === 0) return [];
    try {
        return JSON.parse(Buffer.from(result).toString());
    } catch {
        return [];
    }
}

// ── GET /api/v1/audit — Get all audit logs ────────────────────────────────────
router.get('/', async (req, res) => {
    try {
        const contract = await getContract('org1');
        const startTime = Date.now();

        const result = await contract.evaluateTransaction('GetAuditLogs');
        const duration = Date.now() - startTime;

        const logs = parseResponse(result);

        // Optional filtering by function name
        const { fn, result: filterResult, from, to } = req.query;
        let filtered = logs;

        if (fn) {
            filtered = filtered.filter(l => l.Function === fn);
        }
        if (filterResult) {
            filtered = filtered.filter(l => l.Result === filterResult.toUpperCase());
        }
        if (from) {
            filtered = filtered.filter(l => new Date(l.Timestamp) >= new Date(from));
        }
        if (to) {
            filtered = filtered.filter(l => new Date(l.Timestamp) <= new Date(to));
        }

        res.json({
            success: true,
            count: filtered.length,
            data: filtered,
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

module.exports = router;
