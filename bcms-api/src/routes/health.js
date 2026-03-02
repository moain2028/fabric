/**
 * ============================================================================
 *  BCMS — Health Check Routes
 * ============================================================================
 */

'use strict';

const express = require('express');
const router = express.Router();

router.get('/', (req, res) => {
    res.json({
        status: 'healthy',
        service: 'BCMS REST API',
        version: '2.0.0',
        fabric: 'Hyperledger Fabric v2.5',
        timestamp: new Date().toISOString(),
        uptime: process.uptime()
    });
});

module.exports = router;
