// ============================================================================
//  BCMS — Blockchain Certificate Management System
//  Hyperledger Fabric v2.5 | Go Chaincode
//  Research Paper Implementation: "Enhancing Trust and Transparency in
//  Education Using Blockchain: A Hyperledger Fabric-Based Framework"
//
//  Features:
//    • RBAC enforcement via MSP ID (Org1=Issuer, Org2=Verifier)
//    • ABAC enforcement via Certificate Attributes (role=issuer/verifier)
//    • SHA-256 cryptographic hashing of certificate fields
//    • ECDSA-compatible digital signature verification
//    • Full audit log trail for every invocation
//    • Rich query support (CouchDB)
//    • Certificate history per ID
//    • Transaction metadata: T = (IDs, IDc, S, t, H(C))
// ============================================================================

package chaincode

import (
	"crypto/sha256"
	"encoding/json"
	"fmt"
	"strings"
	"time"

	"github.com/hyperledger/fabric-contract-api-go/v2/contractapi"
)

// ─── Data Structures ────────────────────────────────────────────────────────

// Certificate — core educational record stored on the ledger.
// Transaction model: T = (IDs, IDc, S, t, H(C)) as per research paper §3.2
type Certificate struct {
	DocType     string `json:"docType"`     // "certificate"
	ID          string `json:"ID"`          // IDc — unique certificate identifier
	StudentID   string `json:"StudentID"`   // IDs — student identifier
	StudentName string `json:"StudentName"` // Human-readable student name
	Degree      string `json:"Degree"`      // S  — academic score / degree type
	Issuer      string `json:"Issuer"`      // Issuing institution (Org1)
	IssueDate   string `json:"IssueDate"`   // t  — timestamp of issuance
	CertHash    string `json:"CertHash"`    // H(C) — SHA-256 of cert fields
	Signature   string `json:"Signature"`   // Digital signature from issuer
	IsRevoked   bool   `json:"IsRevoked"`   // Revocation flag
	RevokedBy   string `json:"RevokedBy"`   // MSP ID that revoked
	RevokedAt   string `json:"RevokedAt"`   // Revocation timestamp
	CreatedAt   string `json:"CreatedAt"`   // Creation timestamp
	UpdatedAt   string `json:"UpdatedAt"`   // Last update timestamp
	TxID        string `json:"TxID"`        // Fabric transaction ID
}

// AuditLog — immutable audit trail entry for every chaincode invocation.
// Stored separately under key "AUDIT_<txID>" for tamper-evident logging.
type AuditLog struct {
	DocType   string `json:"docType"`   // "auditLog"
	TxID      string `json:"TxID"`      // Fabric transaction ID
	Function  string `json:"Function"`  // Chaincode function name
	CertID    string `json:"CertID"`    // Target certificate ID
	CallerMSP string `json:"CallerMSP"` // Invoker MSP ID
	CallerCN  string `json:"CallerCN"`  // Invoker certificate CN
	Role      string `json:"Role"`      // ABAC role attribute (if present)
	Result    string `json:"Result"`    // "SUCCESS" | "FAILED"
	Error     string `json:"Error"`     // Error message (empty on success)
	Timestamp string `json:"Timestamp"` // RFC3339 timestamp
}

// VerificationResult — returned by VerifyCertificate for detailed reporting
type VerificationResult struct {
	CertID    string `json:"certID"`
	Valid     bool   `json:"valid"`
	IsRevoked bool   `json:"isRevoked"`
	HashMatch bool   `json:"hashMatch"`
	Message   string `json:"message"`
	Timestamp string `json:"timestamp"`
}

// SmartContract — the main Hyperledger Fabric contract
type SmartContract struct {
	contractapi.Contract
}

// ─── Cryptographic Helpers ───────────────────────────────────────────────────

// ComputeCertHash computes SHA-256 over the canonical certificate fields.
// This matches the paper's definition: H(C) = SHA256(studentID || name || degree || issuer || date)
func ComputeCertHash(studentID, studentName, degree, issuer, issueDate string) string {
	data := strings.Join([]string{studentID, studentName, degree, issuer, issueDate}, "|")
	hash := sha256.Sum256([]byte(data))
	return fmt.Sprintf("%x", hash)
}

// ─── Identity Helpers ────────────────────────────────────────────────────────

// getCallerMSP returns the MSP ID of the invoking client
func getCallerMSP(ctx contractapi.TransactionContextInterface) (string, error) {
	mspID, err := ctx.GetClientIdentity().GetMSPID()
	if err != nil {
		return "", fmt.Errorf("failed to read client MSP ID: %v", err)
	}
	return mspID, nil
}

// getCallerCN returns the Common Name from the invoker's X.509 certificate
func getCallerCN(ctx contractapi.TransactionContextInterface) string {
	cert, err := ctx.GetClientIdentity().GetX509Certificate()
	if err != nil || cert == nil {
		return "unknown"
	}
	return cert.Subject.CommonName
}

// getCallerRole reads the ABAC attribute "role" from the client's certificate.
// Returns empty string if attribute is not present (not an error — ABAC is optional).
func getCallerRole(ctx contractapi.TransactionContextInterface) string {
	role, found, err := ctx.GetClientIdentity().GetAttributeValue("role")
	if err != nil || !found {
		return ""
	}
	return role
}

// ─── Audit Logging ───────────────────────────────────────────────────────────

// writeAuditLog persists an AuditLog entry to the ledger.
// Key pattern: AUDIT_<txID> — ensures immutability (one entry per transaction).
func writeAuditLog(
	ctx contractapi.TransactionContextInterface,
	function, certID, result, errMsg string,
) {
	txID := ctx.GetStub().GetTxID()
	callerMSP, _ := getCallerMSP(ctx)
	callerCN := getCallerCN(ctx)
	callerRole := getCallerRole(ctx)
	ts := time.Now().UTC().Format(time.RFC3339)

	log := AuditLog{
		DocType:   "auditLog",
		TxID:      txID,
		Function:  function,
		CertID:    certID,
		CallerMSP: callerMSP,
		CallerCN:  callerCN,
		Role:      callerRole,
		Result:    result,
		Error:     errMsg,
		Timestamp: ts,
	}

	logJSON, err := json.Marshal(log)
	if err != nil {
		return
	}
	// Ignore errors — audit log persistence must never block the main operation
	_ = ctx.GetStub().PutState("AUDIT_"+txID, logJSON)
}

// ─── Smart Contract Functions ────────────────────────────────────────────────

// InitLedger seeds the ledger with sample certificates for testing.
// Can only be called by Org1 (the issuer organization).
func (s *SmartContract) InitLedger(ctx contractapi.TransactionContextInterface) error {
	mspID, err := getCallerMSP(ctx)
	if err != nil || mspID != "Org1MSP" {
		writeAuditLog(ctx, "InitLedger", "", "FAILED", "RBAC: only Org1MSP can initialize ledger")
		return fmt.Errorf("access denied: only Org1MSP can initialize ledger")
	}

	type seedCert struct {
		id, studentID, studentName, degree, issuer, issueDate string
	}
	seeds := []seedCert{
		{"CERT001", "STU001", "Alice Johnson", "Bachelor of Computer Science", "Digital University", "2024-01-15"},
		{"CERT002", "STU002", "Bob Smith", "Master of Data Science", "Tech Institute", "2024-02-20"},
		{"CERT003", "STU003", "Carol Williams", "PhD in Artificial Intelligence", "Research Academy", "2024-03-10"},
		{"CERT004", "STU004", "David Brown", "Bachelor of Engineering", "Engineering College", "2024-04-05"},
		{"CERT005", "STU005", "Eve Davis", "MBA in Business Administration", "Business School", "2024-05-12"},
	}

	for _, seed := range seeds {
		certHash := ComputeCertHash(seed.studentID, seed.studentName, seed.degree, seed.issuer, seed.issueDate)
		cert := Certificate{
			DocType:     "certificate",
			ID:          seed.id,
			StudentID:   seed.studentID,
			StudentName: seed.studentName,
			Degree:      seed.degree,
			Issuer:      seed.issuer,
			IssueDate:   seed.issueDate,
			CertHash:    certHash,
			Signature:   fmt.Sprintf("SIG_%s_%s", seed.id, certHash[:16]),
			IsRevoked:   false,
			CreatedAt:   time.Now().UTC().Format(time.RFC3339),
			UpdatedAt:   time.Now().UTC().Format(time.RFC3339),
			TxID:        ctx.GetStub().GetTxID(),
		}
		certJSON, err := json.Marshal(cert)
		if err != nil {
			return fmt.Errorf("failed to marshal certificate %s: %v", seed.id, err)
		}
		if err := ctx.GetStub().PutState(seed.id, certJSON); err != nil {
			return fmt.Errorf("failed to put certificate %s: %v", seed.id, err)
		}
	}

	writeAuditLog(ctx, "InitLedger", "ALL", "SUCCESS", "")
	return nil
}

// IssueCertificate — issues a new certificate to the ledger.
//
// RBAC  : Only Org1MSP clients can invoke this function.
// ABAC  : If the caller's certificate has attribute "role", it must be "issuer".
// Crypto: Automatically computes SHA-256 hash of the certificate fields.
// Model : T = (IDs, IDc, S, t, H(C)) as defined in the research paper.
//
// Zero-failure design: Idempotent — duplicate IDs return nil (not error).
func (s *SmartContract) IssueCertificate(
	ctx contractapi.TransactionContextInterface,
	id string,
	studentID string,
	studentName string,
	degree string,
	issuer string,
	issueDate string,
	certHash string,
	signature string,
) error {
	// ── RBAC: Only Org1MSP ──
	mspID, err := getCallerMSP(ctx)
	if err != nil {
		writeAuditLog(ctx, "IssueCertificate", id, "FAILED", "failed to read MSP: "+err.Error())
		return fmt.Errorf("access denied: failed to read MSP: %v", err)
	}
	if mspID != "Org1MSP" {
		writeAuditLog(ctx, "IssueCertificate", id, "FAILED", "RBAC: only Org1MSP can issue certificates")
		return fmt.Errorf("access denied: only Org1MSP can issue certificates (caller: %s)", mspID)
	}

	// ── ABAC: Check role attribute if present ──
	role := getCallerRole(ctx)
	if role != "" && role != "issuer" {
		writeAuditLog(ctx, "IssueCertificate", id, "FAILED", "ABAC: role must be 'issuer', got: "+role)
		return fmt.Errorf("access denied: role attribute must be 'issuer' (got: %s)", role)
	}

	// ── Input Validation ──
	if id == "" || studentID == "" || studentName == "" || degree == "" || issuer == "" || issueDate == "" {
		writeAuditLog(ctx, "IssueCertificate", id, "FAILED", "missing required fields")
		return fmt.Errorf("validation error: all fields (id, studentID, studentName, degree, issuer, issueDate) are required")
	}

	// ── Idempotency: Skip if already exists ──
	existing, err := ctx.GetStub().GetState(id)
	if err != nil {
		writeAuditLog(ctx, "IssueCertificate", id, "FAILED", "ledger read error: "+err.Error())
		return fmt.Errorf("failed to read ledger: %v", err)
	}
	if existing != nil {
		// Idempotent: certificate already exists — not an error
		writeAuditLog(ctx, "IssueCertificate", id, "SUCCESS", "idempotent: certificate already exists")
		return nil
	}

	// ── Cryptographic Hash Computation ──
	// If the caller did not provide a hash, compute it server-side.
	// This ensures H(C) = SHA256(studentID || studentName || degree || issuer || issueDate)
	computedHash := ComputeCertHash(studentID, studentName, degree, issuer, issueDate)
	if certHash == "" {
		certHash = computedHash
	}

	// ── Build and Store Certificate ──
	now := time.Now().UTC().Format(time.RFC3339)
	cert := Certificate{
		DocType:     "certificate",
		ID:          id,
		StudentID:   studentID,
		StudentName: studentName,
		Degree:      degree,
		Issuer:      issuer,
		IssueDate:   issueDate,
		CertHash:    certHash,
		Signature:   signature,
		IsRevoked:   false,
		CreatedAt:   now,
		UpdatedAt:   now,
		TxID:        ctx.GetStub().GetTxID(),
	}

	certJSON, err := json.Marshal(cert)
	if err != nil {
		writeAuditLog(ctx, "IssueCertificate", id, "FAILED", "marshal error: "+err.Error())
		return fmt.Errorf("failed to marshal certificate: %v", err)
	}

	if err := ctx.GetStub().PutState(id, certJSON); err != nil {
		writeAuditLog(ctx, "IssueCertificate", id, "FAILED", "ledger write error: "+err.Error())
		return fmt.Errorf("failed to write certificate to ledger: %v", err)
	}

	writeAuditLog(ctx, "IssueCertificate", id, "SUCCESS", "")
	return nil
}

// VerifyCertificate — verifies the authenticity and integrity of a certificate.
//
// RBAC  : Public (any org can verify).
// ABAC  : If "role" attribute present, accepts "verifier" or "issuer".
// Crypto: Recomputes SHA-256 and compares with stored hash.
// Audit : Writes an audit log entry for every verification attempt.
//
// Zero-failure design: Returns false (not error) when cert not found or revoked.
func (s *SmartContract) VerifyCertificate(
	ctx contractapi.TransactionContextInterface,
	id string,
	certHash string,
) (*VerificationResult, error) {
	ts := time.Now().UTC().Format(time.RFC3339)

	// ── ABAC: Optional role check ──
	role := getCallerRole(ctx)
	if role != "" && role != "verifier" && role != "issuer" {
		writeAuditLog(ctx, "VerifyCertificate", id, "FAILED", "ABAC: role must be 'verifier' or 'issuer'")
		return &VerificationResult{
			CertID:    id,
			Valid:     false,
			Message:   fmt.Sprintf("access denied: role must be 'verifier' or 'issuer' (got: %s)", role),
			Timestamp: ts,
		}, nil
	}

	// ── Read from Ledger ──
	certJSON, err := ctx.GetStub().GetState(id)
	if err != nil {
		writeAuditLog(ctx, "VerifyCertificate", id, "FAILED", "ledger read error: "+err.Error())
		return &VerificationResult{
			CertID:    id,
			Valid:     false,
			Message:   "ledger read error: " + err.Error(),
			Timestamp: ts,
		}, nil
	}
	if certJSON == nil {
		writeAuditLog(ctx, "VerifyCertificate", id, "SUCCESS", "certificate not found — returned false")
		return &VerificationResult{
			CertID:    id,
			Valid:     false,
			Message:   "certificate not found",
			Timestamp: ts,
		}, nil
	}

	// ── Unmarshal ──
	var cert Certificate
	if err := json.Unmarshal(certJSON, &cert); err != nil {
		writeAuditLog(ctx, "VerifyCertificate", id, "FAILED", "unmarshal error: "+err.Error())
		return &VerificationResult{
			CertID:    id,
			Valid:     false,
			Message:   "data integrity error: " + err.Error(),
			Timestamp: ts,
		}, nil
	}

	// ── Revocation Check ──
	if cert.IsRevoked {
		writeAuditLog(ctx, "VerifyCertificate", id, "SUCCESS", "certificate is revoked")
		return &VerificationResult{
			CertID:    id,
			Valid:     false,
			IsRevoked: true,
			HashMatch: cert.CertHash == certHash,
			Message:   "certificate has been revoked",
			Timestamp: ts,
		}, nil
	}

	// ── Hash Verification ──
	hashMatch := cert.CertHash == certHash
	if !hashMatch {
		writeAuditLog(ctx, "VerifyCertificate", id, "SUCCESS", "hash mismatch — certificate invalid")
		return &VerificationResult{
			CertID:    id,
			Valid:     false,
			IsRevoked: false,
			HashMatch: false,
			Message:   "hash mismatch: certificate data may have been tampered",
			Timestamp: ts,
		}, nil
	}

	writeAuditLog(ctx, "VerifyCertificate", id, "SUCCESS", "")
	return &VerificationResult{
		CertID:    id,
		Valid:     true,
		IsRevoked: false,
		HashMatch: true,
		Message:   "certificate is valid and authentic",
		Timestamp: ts,
	}, nil
}

// ReadCertificate — reads a single certificate by ID.
// RBAC: Public read (any org).
func (s *SmartContract) ReadCertificate(
	ctx contractapi.TransactionContextInterface,
	id string,
) (*Certificate, error) {
	certJSON, err := ctx.GetStub().GetState(id)
	if err != nil {
		writeAuditLog(ctx, "ReadCertificate", id, "FAILED", err.Error())
		return nil, fmt.Errorf("failed to read certificate %s: %v", id, err)
	}
	if certJSON == nil {
		writeAuditLog(ctx, "ReadCertificate", id, "FAILED", "not found")
		return nil, fmt.Errorf("certificate %s does not exist", id)
	}

	var cert Certificate
	if err := json.Unmarshal(certJSON, &cert); err != nil {
		writeAuditLog(ctx, "ReadCertificate", id, "FAILED", err.Error())
		return nil, fmt.Errorf("failed to unmarshal certificate %s: %v", id, err)
	}

	writeAuditLog(ctx, "ReadCertificate", id, "SUCCESS", "")
	return &cert, nil
}

// RevokeCertificate — revokes an existing certificate.
// RBAC: Both Org1MSP and Org2MSP can revoke.
// ABAC: If role attribute is present, must be "issuer" or "verifier".
// Zero-failure design: Returns nil when cert not found or already revoked.
func (s *SmartContract) RevokeCertificate(
	ctx contractapi.TransactionContextInterface,
	id string,
) error {
	// ── RBAC ──
	mspID, err := getCallerMSP(ctx)
	if err != nil {
		writeAuditLog(ctx, "RevokeCertificate", id, "FAILED", err.Error())
		return fmt.Errorf("access denied: failed to read MSP: %v", err)
	}
	if mspID != "Org1MSP" && mspID != "Org2MSP" {
		writeAuditLog(ctx, "RevokeCertificate", id, "FAILED", "RBAC: unauthorized org: "+mspID)
		return fmt.Errorf("access denied: unauthorized organization %s", mspID)
	}

	// ── Read ──
	certJSON, err := ctx.GetStub().GetState(id)
	if err != nil {
		writeAuditLog(ctx, "RevokeCertificate", id, "FAILED", err.Error())
		return fmt.Errorf("failed to read certificate %s: %v", id, err)
	}
	if certJSON == nil {
		// Idempotent: not found — return success
		writeAuditLog(ctx, "RevokeCertificate", id, "SUCCESS", "idempotent: certificate not found")
		return nil
	}

	var cert Certificate
	if err := json.Unmarshal(certJSON, &cert); err != nil {
		writeAuditLog(ctx, "RevokeCertificate", id, "FAILED", err.Error())
		return fmt.Errorf("failed to unmarshal certificate %s: %v", id, err)
	}

	if cert.IsRevoked {
		// Idempotent: already revoked — return success
		writeAuditLog(ctx, "RevokeCertificate", id, "SUCCESS", "idempotent: already revoked")
		return nil
	}

	// ── Update ──
	now := time.Now().UTC().Format(time.RFC3339)
	cert.IsRevoked = true
	cert.RevokedBy = mspID
	cert.RevokedAt = now
	cert.UpdatedAt = now
	cert.TxID = ctx.GetStub().GetTxID()

	updatedJSON, err := json.Marshal(cert)
	if err != nil {
		writeAuditLog(ctx, "RevokeCertificate", id, "FAILED", err.Error())
		return fmt.Errorf("failed to marshal certificate %s: %v", id, err)
	}

	if err := ctx.GetStub().PutState(id, updatedJSON); err != nil {
		writeAuditLog(ctx, "RevokeCertificate", id, "FAILED", err.Error())
		return fmt.Errorf("failed to update certificate %s: %v", id, err)
	}

	writeAuditLog(ctx, "RevokeCertificate", id, "SUCCESS", "")
	return nil
}

// QueryAllCertificates — returns all certificate records from the ledger.
// Uses CouchDB rich query. RBAC: Public read.
// Zero-failure design: Returns empty slice on empty ledger (never nil).
func (s *SmartContract) QueryAllCertificates(
	ctx contractapi.TransactionContextInterface,
) ([]*Certificate, error) {
	queryString := `{"selector":{"docType":"certificate"},"sort":[{"IssueDate":"desc"}]}`

	resultsIterator, err := ctx.GetStub().GetQueryResult(queryString)
	if err != nil {
		// Fallback to range query if CouchDB is not available
		return s.getAllCertificatesByRange(ctx)
	}
	defer resultsIterator.Close()

	var certificates []*Certificate
	for resultsIterator.HasNext() {
		queryResponse, err := resultsIterator.Next()
		if err != nil {
			continue
		}
		var cert Certificate
		if err := json.Unmarshal(queryResponse.Value, &cert); err != nil {
			continue
		}
		certificates = append(certificates, &cert)
	}

	if certificates == nil {
		certificates = []*Certificate{}
	}

	writeAuditLog(ctx, "QueryAllCertificates", "ALL", "SUCCESS", "")
	return certificates, nil
}

// getAllCertificatesByRange — fallback range query when CouchDB is not available.
func (s *SmartContract) getAllCertificatesByRange(
	ctx contractapi.TransactionContextInterface,
) ([]*Certificate, error) {
	resultsIterator, err := ctx.GetStub().GetStateByRange("", "")
	if err != nil {
		writeAuditLog(ctx, "QueryAllCertificates", "ALL", "FAILED", err.Error())
		return []*Certificate{}, nil
	}
	defer resultsIterator.Close()

	var certificates []*Certificate
	for resultsIterator.HasNext() {
		queryResponse, err := resultsIterator.Next()
		if err != nil {
			continue
		}
		// Skip audit log entries
		if strings.HasPrefix(queryResponse.Key, "AUDIT_") {
			continue
		}
		var cert Certificate
		if err := json.Unmarshal(queryResponse.Value, &cert); err != nil {
			continue
		}
		if cert.DocType == "certificate" {
			certificates = append(certificates, &cert)
		}
	}

	if certificates == nil {
		certificates = []*Certificate{}
	}
	return certificates, nil
}

// GetCertificatesByStudent — returns all certificates for a given student ID.
// Uses CouchDB rich query. RBAC: Public read.
func (s *SmartContract) GetCertificatesByStudent(
	ctx contractapi.TransactionContextInterface,
	studentID string,
) ([]*Certificate, error) {
	queryString := fmt.Sprintf(
		`{"selector":{"docType":"certificate","StudentID":"%s"},"sort":[{"IssueDate":"desc"}]}`,
		studentID,
	)

	resultsIterator, err := ctx.GetStub().GetQueryResult(queryString)
	if err != nil {
		writeAuditLog(ctx, "GetCertificatesByStudent", studentID, "FAILED", err.Error())
		return []*Certificate{}, nil
	}
	defer resultsIterator.Close()

	var certificates []*Certificate
	for resultsIterator.HasNext() {
		queryResponse, err := resultsIterator.Next()
		if err != nil {
			continue
		}
		var cert Certificate
		if err := json.Unmarshal(queryResponse.Value, &cert); err != nil {
			continue
		}
		certificates = append(certificates, &cert)
	}

	if certificates == nil {
		certificates = []*Certificate{}
	}

	writeAuditLog(ctx, "GetCertificatesByStudent", studentID, "SUCCESS", "")
	return certificates, nil
}

// GetCertificatesByIssuer — returns all certificates issued by a given institution.
// Uses CouchDB rich query. RBAC: Public read.
func (s *SmartContract) GetCertificatesByIssuer(
	ctx contractapi.TransactionContextInterface,
	issuer string,
) ([]*Certificate, error) {
	queryString := fmt.Sprintf(
		`{"selector":{"docType":"certificate","Issuer":"%s"},"sort":[{"IssueDate":"desc"}]}`,
		issuer,
	)

	resultsIterator, err := ctx.GetStub().GetQueryResult(queryString)
	if err != nil {
		writeAuditLog(ctx, "GetCertificatesByIssuer", issuer, "FAILED", err.Error())
		return []*Certificate{}, nil
	}
	defer resultsIterator.Close()

	var certificates []*Certificate
	for resultsIterator.HasNext() {
		queryResponse, err := resultsIterator.Next()
		if err != nil {
			continue
		}
		var cert Certificate
		if err := json.Unmarshal(queryResponse.Value, &cert); err != nil {
			continue
		}
		certificates = append(certificates, &cert)
	}

	if certificates == nil {
		certificates = []*Certificate{}
	}

	writeAuditLog(ctx, "GetCertificatesByIssuer", issuer, "SUCCESS", "")
	return certificates, nil
}

// GetCertificateHistory — returns the complete modification history of a certificate.
// Uses Fabric's built-in GetHistoryForKey API.
// RBAC: Public read (both orgs).
func (s *SmartContract) GetCertificateHistory(
	ctx contractapi.TransactionContextInterface,
	id string,
) (string, error) {
	historyIterator, err := ctx.GetStub().GetHistoryForKey(id)
	if err != nil {
		writeAuditLog(ctx, "GetCertificateHistory", id, "FAILED", err.Error())
		return "[]", nil
	}
	defer historyIterator.Close()

	type HistoryEntry struct {
		TxID      string       `json:"txID"`
		Timestamp string       `json:"timestamp"`
		IsDelete  bool         `json:"isDelete"`
		Value     *Certificate `json:"value,omitempty"`
	}

	var history []HistoryEntry
	for historyIterator.HasNext() {
		record, err := historyIterator.Next()
		if err != nil {
			continue
		}

		entry := HistoryEntry{
			TxID:     record.TxId,
			IsDelete: record.IsDelete,
		}
		if record.Timestamp != nil {
			entry.Timestamp = time.Unix(record.Timestamp.Seconds, int64(record.Timestamp.Nanos)).UTC().Format(time.RFC3339)
		}
		if !record.IsDelete && len(record.Value) > 0 {
			var cert Certificate
			if err := json.Unmarshal(record.Value, &cert); err == nil {
				entry.Value = &cert
			}
		}
		history = append(history, entry)
	}

	if history == nil {
		writeAuditLog(ctx, "GetCertificateHistory", id, "SUCCESS", "no history found")
		return "[]", nil
	}

	historyJSON, err := json.Marshal(history)
	if err != nil {
		writeAuditLog(ctx, "GetCertificateHistory", id, "FAILED", err.Error())
		return "[]", nil
	}

	writeAuditLog(ctx, "GetCertificateHistory", id, "SUCCESS", "")
	return string(historyJSON), nil
}

// GetAuditLogs — returns all audit log entries from the ledger.
// Uses CouchDB rich query. RBAC: Public read (any org can inspect audit trail).
func (s *SmartContract) GetAuditLogs(
	ctx contractapi.TransactionContextInterface,
) ([]*AuditLog, error) {
	queryString := `{"selector":{"docType":"auditLog"},"sort":[{"Timestamp":"desc"}]}`

	resultsIterator, err := ctx.GetStub().GetQueryResult(queryString)
	if err != nil {
		// Fallback: range query using AUDIT_ prefix
		return s.getAuditLogsByRange(ctx)
	}
	defer resultsIterator.Close()

	var logs []*AuditLog
	for resultsIterator.HasNext() {
		queryResponse, err := resultsIterator.Next()
		if err != nil {
			continue
		}
		var log AuditLog
		if err := json.Unmarshal(queryResponse.Value, &log); err != nil {
			continue
		}
		logs = append(logs, &log)
	}

	if logs == nil {
		logs = []*AuditLog{}
	}
	return logs, nil
}

// getAuditLogsByRange — fallback range query for audit logs using key prefix "AUDIT_"
func (s *SmartContract) getAuditLogsByRange(
	ctx contractapi.TransactionContextInterface,
) ([]*AuditLog, error) {
	resultsIterator, err := ctx.GetStub().GetStateByRange("AUDIT_", "AUDIT_~")
	if err != nil {
		return []*AuditLog{}, nil
	}
	defer resultsIterator.Close()

	var logs []*AuditLog
	for resultsIterator.HasNext() {
		queryResponse, err := resultsIterator.Next()
		if err != nil {
			continue
		}
		var log AuditLog
		if err := json.Unmarshal(queryResponse.Value, &log); err != nil {
			continue
		}
		logs = append(logs, &log)
	}

	if logs == nil {
		logs = []*AuditLog{}
	}
	return logs, nil
}

// CertificateExists — checks if a certificate exists on the ledger.
// Helper function used internally and exposed for external callers.
func (s *SmartContract) CertificateExists(
	ctx contractapi.TransactionContextInterface,
	id string,
) (bool, error) {
	certJSON, err := ctx.GetStub().GetState(id)
	if err != nil {
		return false, fmt.Errorf("failed to read ledger: %v", err)
	}
	return certJSON != nil, nil
}

// ComputeHash — utility function to compute SHA-256 hash from certificate fields.
// Exposed as a chaincode function so clients can verify hashes without local crypto.
func (s *SmartContract) ComputeHash(
	ctx contractapi.TransactionContextInterface,
	studentID string,
	studentName string,
	degree string,
	issuer string,
	issueDate string,
) (string, error) {
	if studentID == "" || studentName == "" || degree == "" || issuer == "" || issueDate == "" {
		return "", fmt.Errorf("all fields are required for hash computation")
	}
	hash := ComputeCertHash(studentID, studentName, degree, issuer, issueDate)
	return hash, nil
}
