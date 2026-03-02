/**
 * ============================================================================
 *  BCMS — Fabric Gateway Connection Manager
 *  Manages connection to Hyperledger Fabric network using Gateway API
 * ============================================================================
 */

'use strict';

const { connect, hash, signers } = require('@hyperledger/fabric-gateway');
const grpc = require('@grpc/grpc-js');
const crypto = require('crypto');
const fs = require('fs');
const path = require('path');

// ── Configuration ─────────────────────────────────────────────────────────────
const FABRIC_PATH = process.env.FABRIC_PATH ||
    path.resolve(__dirname, '../../../test-network');

const MSP_ID_ORG1 = 'Org1MSP';
const MSP_ID_ORG2 = 'Org2MSP';
const CHANNEL_NAME = process.env.CHANNEL_NAME || 'mychannel';
const CHAINCODE_NAME = process.env.CHAINCODE_NAME || 'basic';

// Peer addresses
const PEER_ENDPOINT_ORG1 = process.env.PEER_ENDPOINT_ORG1 || 'localhost:7051';
const PEER_ENDPOINT_ORG2 = process.env.PEER_ENDPOINT_ORG2 || 'localhost:9051';

// Org1 Identity paths
const PEER0_ORG1_TLS_PATH = path.join(
    FABRIC_PATH,
    'organizations/peerOrganizations/org1.example.com/peers/peer0.org1.example.com/tls/ca.crt'
);
const ORG1_CERT_DIR = path.join(
    FABRIC_PATH,
    'organizations/peerOrganizations/org1.example.com/users/User1@org1.example.com/msp/signcerts'
);
const ORG1_KEY_DIR = path.join(
    FABRIC_PATH,
    'organizations/peerOrganizations/org1.example.com/users/User1@org1.example.com/msp/keystore'
);

// Org2 Identity paths
const PEER0_ORG2_TLS_PATH = path.join(
    FABRIC_PATH,
    'organizations/peerOrganizations/org2.example.com/peers/peer0.org2.example.com/tls/ca.crt'
);
const ORG2_CERT_DIR = path.join(
    FABRIC_PATH,
    'organizations/peerOrganizations/org2.example.com/users/User1@org2.example.com/msp/signcerts'
);
const ORG2_KEY_DIR = path.join(
    FABRIC_PATH,
    'organizations/peerOrganizations/org2.example.com/users/User1@org2.example.com/msp/keystore'
);

// ── Connection Cache ──────────────────────────────────────────────────────────
const connections = {
    org1: null,
    org2: null
};

// ── Helper: Read first file in directory ─────────────────────────────────────
function readFirstFileInDir(dirPath) {
    const files = fs.readdirSync(dirPath);
    if (files.length === 0) throw new Error(`No files in directory: ${dirPath}`);
    return fs.readFileSync(path.join(dirPath, files[0]));
}

// ── Helper: Get private key from keystore ────────────────────────────────────
function getPrivateKey(keyDir) {
    const keyFiles = fs.readdirSync(keyDir).filter(f => f.endsWith('_sk') || f.endsWith('.key') || !f.includes('.'));
    if (keyFiles.length === 0) {
        // Try any file
        const allFiles = fs.readdirSync(keyDir);
        if (allFiles.length === 0) throw new Error(`No private key files in: ${keyDir}`);
        return fs.readFileSync(path.join(keyDir, allFiles[0]));
    }
    return fs.readFileSync(path.join(keyDir, keyFiles[0]));
}

// ── Create gRPC connection to a peer ─────────────────────────────────────────
function newGrpcConnection(peerEndpoint, tlsCertPath) {
    const tlsRootCert = fs.readFileSync(tlsCertPath);
    const tlsCredentials = grpc.credentials.createSsl(tlsRootCert);
    return new grpc.Client(peerEndpoint, tlsCredentials, {
        'grpc.ssl_target_name_override': peerEndpoint.split(':')[0]
    });
}

// ── Create Fabric Gateway connection ─────────────────────────────────────────
async function createConnection(org) {
    let peerEndpoint, tlsCertPath, certDir, keyDir, mspId;

    if (org === 'org1') {
        peerEndpoint = PEER_ENDPOINT_ORG1;
        tlsCertPath = PEER0_ORG1_TLS_PATH;
        certDir = ORG1_CERT_DIR;
        keyDir = ORG1_KEY_DIR;
        mspId = MSP_ID_ORG1;
    } else {
        peerEndpoint = PEER_ENDPOINT_ORG2;
        tlsCertPath = PEER0_ORG2_TLS_PATH;
        certDir = ORG2_CERT_DIR;
        keyDir = ORG2_KEY_DIR;
        mspId = MSP_ID_ORG2;
    }

    const client = newGrpcConnection(peerEndpoint, tlsCertPath);
    const credentials = {
        mspId,
        certificate: readFirstFileInDir(certDir),
        privateKey: getPrivateKey(keyDir)
    };

    const gateway = connect({
        client,
        identity: {
            mspId: credentials.mspId,
            credentials: credentials.certificate
        },
        signer: signers.newPrivateKeySigner(
            crypto.createPrivateKey(credentials.privateKey)
        ),
        hash: hash.sha256
    });

    const network = gateway.getNetwork(CHANNEL_NAME);
    const contract = network.getContract(CHAINCODE_NAME);

    return { gateway, network, contract, client };
}

// ── Get or create cached connection ──────────────────────────────────────────
async function getConnection(org = 'org1') {
    if (!connections[org]) {
        connections[org] = await createConnection(org);
    }
    return connections[org];
}

// ── Get contract for specific org ────────────────────────────────────────────
async function getContract(org = 'org1') {
    const conn = await getConnection(org);
    return conn.contract;
}

// ── Close all connections ─────────────────────────────────────────────────────
async function closeConnections() {
    for (const org of ['org1', 'org2']) {
        if (connections[org]) {
            connections[org].gateway.close();
            connections[org].client.close();
            connections[org] = null;
        }
    }
}

module.exports = { getContract, getConnection, closeConnections, CHANNEL_NAME, CHAINCODE_NAME };
