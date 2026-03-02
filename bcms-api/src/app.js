/**
 * ============================================================================
 *  BCMS REST API — Main Application Entry Point
 *  Blockchain Certificate Management System
 *  Research Paper: "Enhancing Trust and Transparency in Education Using
 *                   Blockchain: A Hyperledger Fabric-Based Framework"
 * ============================================================================
 */

'use strict';

require('dotenv').config();

const express = require('express');
const cors = require('cors');
const helmet = require('helmet');
const morgan = require('morgan');
const { createLogger, format, transports } = require('winston');

// ── Logger Setup ─────────────────────────────────────────────────────────────
const logger = createLogger({
    level: process.env.LOG_LEVEL || 'info',
    format: format.combine(
        format.timestamp(),
        format.errors({ stack: true }),
        format.json()
    ),
    transports: [
        new transports.Console({
            format: format.combine(
                format.colorize(),
                format.simple()
            )
        }),
        new transports.File({ filename: 'logs/error.log', level: 'error' }),
        new transports.File({ filename: 'logs/combined.log' })
    ]
});

// ── Prometheus Metrics ───────────────────────────────────────────────────────
const client = require('prom-client');
const collectDefaultMetrics = client.collectDefaultMetrics;
collectDefaultMetrics({ prefix: 'bcms_' });

const httpRequestDurationMs = new client.Histogram({
    name: 'bcms_http_request_duration_ms',
    help: 'Duration of HTTP requests in ms',
    labelNames: ['method', 'route', 'status_code'],
    buckets: [5, 10, 25, 50, 100, 250, 500, 1000, 2500, 5000]
});

const fabricTransactionCounter = new client.Counter({
    name: 'bcms_fabric_transactions_total',
    help: 'Total Fabric transactions submitted',
    labelNames: ['function', 'status']
});

const fabricLatency = new client.Histogram({
    name: 'bcms_fabric_transaction_duration_ms',
    help: 'Fabric transaction duration in ms',
    labelNames: ['function'],
    buckets: [10, 25, 50, 100, 250, 500, 1000, 2500]
});

// ── Express App Setup ────────────────────────────────────────────────────────
const app = express();

// Security headers
app.use(helmet());

// CORS
app.use(cors({
    origin: process.env.CORS_ORIGIN || '*',
    methods: ['GET', 'POST', 'PUT', 'DELETE'],
    allowedHeaders: ['Content-Type', 'Authorization', 'X-Org-MSP']
}));

// Body parsing
app.use(express.json({ limit: '10mb' }));
app.use(express.urlencoded({ extended: true }));

// HTTP request logging
app.use(morgan('combined', {
    stream: { write: msg => logger.info(msg.trim()) }
}));

// ── Request Duration Middleware ───────────────────────────────────────────────
app.use((req, res, next) => {
    const start = Date.now();
    res.on('finish', () => {
        const duration = Date.now() - start;
        const route = req.route ? req.route.path : req.path;
        httpRequestDurationMs
            .labels(req.method, route, res.statusCode.toString())
            .observe(duration);
    });
    next();
});

// ── Routes ───────────────────────────────────────────────────────────────────
const certificateRoutes = require('./routes/certificates');
const auditRoutes = require('./routes/audit');
const healthRoutes = require('./routes/health');

app.use('/api/v1/certificates', certificateRoutes);
app.use('/api/v1/audit', auditRoutes);
app.use('/api/v1/health', healthRoutes);

// ── Prometheus Metrics Endpoint ───────────────────────────────────────────────
app.get('/metrics', async (req, res) => {
    try {
        res.set('Content-Type', client.register.contentType);
        res.end(await client.register.metrics());
    } catch (err) {
        res.status(500).end(err.message);
    }
});

// ── Root endpoint ─────────────────────────────────────────────────────────────
app.get('/', (req, res) => {
    res.json({
        name: 'BCMS REST API',
        version: '2.0.0',
        description: 'Blockchain Certificate Management System — Hyperledger Fabric v2.5',
        paper: 'Enhancing Trust and Transparency in Education Using Blockchain',
        endpoints: {
            certificates: '/api/v1/certificates',
            audit: '/api/v1/audit',
            health: '/api/v1/health',
            metrics: '/metrics'
        }
    });
});

// ── 404 Handler ───────────────────────────────────────────────────────────────
app.use((req, res) => {
    res.status(404).json({
        success: false,
        error: 'Endpoint not found',
        path: req.path
    });
});

// ── Global Error Handler ──────────────────────────────────────────────────────
app.use((err, req, res, next) => {
    logger.error('Unhandled error:', err);
    res.status(err.status || 500).json({
        success: false,
        error: err.message || 'Internal server error',
        timestamp: new Date().toISOString()
    });
});

// ── Start Server ──────────────────────────────────────────────────────────────
const PORT = process.env.PORT || 3000;

const fs = require('fs');
if (!fs.existsSync('./logs')) {
    fs.mkdirSync('./logs', { recursive: true });
}

app.listen(PORT, '0.0.0.0', () => {
    logger.info(`BCMS REST API running on http://0.0.0.0:${PORT}`);
    logger.info(`Metrics available at http://0.0.0.0:${PORT}/metrics`);
    logger.info(`Health check at http://0.0.0.0:${PORT}/api/v1/health`);
});

module.exports = { app, fabricTransactionCounter, fabricLatency };
