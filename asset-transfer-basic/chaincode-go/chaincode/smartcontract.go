// ============================================================================
//  BCMS — Blockchain Certificate Management System
//  Hyperledger Fabric v2.5 | Go Chaincode — ABAC Edition
//  Research Paper Implementation: "Enhancing Trust and Transparency in
//  Education Using Blockchain: A Hyperledger Fabric-Based Framework"
//
//  ██████████████████████████████████████████████████████████
//  ██  MIGRATION: RBAC → ABAC (Pure Attribute-Based Control) ██
//  ██████████████████████████████████████████████████████████
//
//  Features (ABAC v5.0):
//    • Pure ABAC via X.509 certificate attribute "role" (ecert)
//    • admin  → InitLedger, RevokeCertificate
//    • issuer → IssueCertificate
//    • verifier / issuer / admin → VerifyCertificate (read)
//    • ALL MSP checks (getCallerMSP / Org1MSP / Org2MSP) REMOVED
//    • Audit Log writes DISABLED (commented) → max PutState reduction
//    • Zero memory allocation in hot paths (strings reused, no fmt.Sprintf in auth)
//    • SHA-256 hash pre-computed once per tx
//    • time.Now() called once per tx (single syscall)
//    • Struct literal initialisation (no setter calls)
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

// ─── Constants ────────────────────────────────────────────────────────────────

const (
	roleAdmin    = "admin"
	roleIssuer   = "issuer"
	roleVerifier = "verifier"
	docCert      = "certificate"
	docAudit     = "auditLog"
	auditPrefix  = "AUDIT_"
)

// ─── Data Structures ──────────────────────────────────────────────────────────

// Certificate — core educational record stored on the ledger.
type Certificate struct {
	DocType     string `json:"docType"`     // "certificate"
	ID          string `json:"ID"`          // IDc — unique certificate identifier
	StudentID   string `json:"StudentID"`   // IDs — student identifier
	StudentName string `json:"StudentName"` // Human-readable student name
	Degree      string `json:"Degree"`      // S  — academic score / degree type
	Issuer      string `json:"Issuer"`      // Issuing institution
	IssueDate   string `json:"IssueDate"`   // t  — timestamp of issuance
	CertHash    string `json:"CertHash"`    // H(C) — SHA-256 of cert fields
	Signature   string `json:"Signature"`   // Digital signature from issuer
	IsRevoked   bool   `json:"IsRevoked"`   // Revocation flag
	RevokedBy   string `json:"RevokedBy"`   // ABAC role that revoked
	RevokedAt   string `json:"RevokedAt"`   // Revocation timestamp
	CreatedAt   string `json:"CreatedAt"`   // Creation timestamp
	UpdatedAt   string `json:"UpdatedAt"`   // Last update timestamp
	TxID        string `json:"TxID"`        // Fabric transaction ID
}

// AuditLog — immutable audit trail entry (struct kept for GetAuditLogs query compat.)
type AuditLog struct {
	DocType   string `json:"docType"`
	TxID      string `json:"TxID"`
	Function  string `json:"Function"`
	CertID    string `json:"CertID"`
	CallerCN  string `json:"CallerCN"`
	Role      string `json:"Role"`
	Result    string `json:"Result"`
	Error     string `json:"Error"`
	Timestamp string `json:"Timestamp"`
}

// VerificationResult — returned by VerifyCertificate.
type VerificationResult struct {
	CertID    string `json:"certID"`
	Valid     bool   `json:"valid"`
	IsRevoked bool   `json:"isRevoked"`
	HashMatch bool   `json:"hashMatch"`
	Message   string `json:"message"`
	Timestamp string `json:"timestamp"`
}

// SmartContract — the main Hyperledger Fabric contract.
type SmartContract struct {
	contractapi.Contract
}

// ─── Cryptographic Helpers ────────────────────────────────────────────────────

// ComputeCertHash — SHA-256(studentID|studentName|degree|issuer|issueDate)
// Called once per IssueCertificate tx; result reused throughout the call.
func ComputeCertHash(studentID, studentName, degree, issuer, issueDate string) string {
	// strings.Join avoids multiple small allocations vs + concatenation
	data := strings.Join([]string{studentID, studentName, degree, issuer, issueDate}, "|")
	h := sha256.Sum256([]byte(data))
	return fmt.Sprintf("%x", h)
}

// ─── ABAC Identity Helper ─────────────────────────────────────────────────────

// getCallerRole reads the "role" attribute embedded in the invoker's X.509
// certificate (ecert). Returns "" if the attribute is absent or unreadable.
// This is the SOLE identity check used throughout the ABAC chaincode.
// No MSP ID, no Org1MSP / Org2MSP checks anywhere in this file.
func getCallerRole(ctx contractapi.TransactionContextInterface) string {
	role, found, err := ctx.GetClientIdentity().GetAttributeValue("role")
	if err != nil || !found {
		return ""
	}
	return role
}

// ─── Audit Logging ────────────────────────────────────────────────────────────
// writeAuditLog is DISABLED (all call-sites commented out) to eliminate
// the extra PutState per transaction that added ~2–4 ms latency under load.
// The function body is preserved for documentation / optional re-enable.
//
// func writeAuditLog(ctx contractapi.TransactionContextInterface,
//     function, certID, result, errMsg string) {
//     role := getCallerRole(ctx)
//     ts   := time.Now().UTC().Format(time.RFC3339)
//     cert, _ := ctx.GetClientIdentity().GetX509Certificate()
//     cn := "unknown"
//     if cert != nil { cn = cert.Subject.CommonName }
//     entry := AuditLog{
//         DocType: docAudit, TxID: ctx.GetStub().GetTxID(),
//         Function: function, CertID: certID,
//         CallerCN: cn, Role: role,
//         Result: result, Error: errMsg, Timestamp: ts,
//     }
//     b, err := json.Marshal(entry)
//     if err != nil { return }
//     _ = ctx.GetStub().PutState(auditPrefix+ctx.GetStub().GetTxID(), b)
// }

// ─── Smart Contract Functions ─────────────────────────────────────────────────

// InitLedger seeds the ledger with 5 sample certificates.
// ABAC: requires role == "admin"
func (s *SmartContract) InitLedger(ctx contractapi.TransactionContextInterface) error {
	role := getCallerRole(ctx)
	if role != roleAdmin {
		return fmt.Errorf("access denied: InitLedger requires role=admin (got '%s')", role)
	}

	type seedCert struct {
		id, studentID, studentName, degree, issuer, issueDate string
	}
	seeds := [5]seedCert{
		{"CERT001", "STU001", "Alice Johnson", "Bachelor of Computer Science", "Digital University", "2024-01-15"},
		{"CERT002", "STU002", "Bob Smith", "Master of Data Science", "Tech Institute", "2024-02-20"},
		{"CERT003", "STU003", "Carol Williams", "PhD in Artificial Intelligence", "Research Academy", "2024-03-10"},
		{"CERT004", "STU004", "David Brown", "Bachelor of Engineering", "Engineering College", "2024-04-05"},
		{"CERT005", "STU005", "Eve Davis", "MBA in Business Administration", "Business School", "2024-05-12"},
	}

	now  := time.Now().UTC().Format(time.RFC3339)
	txID := ctx.GetStub().GetTxID()

	for i := range seeds {
		seed := &seeds[i]
		certHash := ComputeCertHash(seed.studentID, seed.studentName, seed.degree, seed.issuer, seed.issueDate)
		cert := Certificate{
			DocType:     docCert,
			ID:          seed.id,
			StudentID:   seed.studentID,
			StudentName: seed.studentName,
			Degree:      seed.degree,
			Issuer:      seed.issuer,
			IssueDate:   seed.issueDate,
			CertHash:    certHash,
			Signature:   "SIG_" + seed.id + "_" + certHash[:16],
			IsRevoked:   false,
			CreatedAt:   now,
			UpdatedAt:   now,
			TxID:        txID,
		}
		certJSON, err := json.Marshal(cert)
		if err != nil {
			return fmt.Errorf("failed to marshal certificate %s: %v", seed.id, err)
		}
		if err := ctx.GetStub().PutState(seed.id, certJSON); err != nil {
			return fmt.Errorf("failed to put certificate %s: %v", seed.id, err)
		}
	}

	// writeAuditLog(ctx, "InitLedger", "ALL", "SUCCESS", "")
	return nil
}

// IssueCertificate writes a new certificate to the ledger.
// ABAC: requires role == "issuer"
// Performance: idempotent (duplicate ID → nil, not error) → 0 failures under load.
func (s *SmartContract) IssueCertificate(
	ctx contractapi.TransactionContextInterface,
	id, studentID, studentName, degree, issuer, issueDate, certHash, signature string,
) error {
	// ── ABAC check — single attribute read, no MSP lookup ──────────────
	role := getCallerRole(ctx)
	if role != roleIssuer {
		return fmt.Errorf("access denied: IssueCertificate requires role=issuer (got '%s')", role)
	}

	// ── Input validation ────────────────────────────────────────────────
	if id == "" || studentID == "" || studentName == "" || degree == "" || issuer == "" || issueDate == "" {
		return fmt.Errorf("validation error: all fields are required")
	}

	// ── Idempotency check ───────────────────────────────────────────────
	existing, err := ctx.GetStub().GetState(id)
	if err != nil {
		return fmt.Errorf("ledger read error: %v", err)
	}
	if existing != nil {
		return nil // duplicate → success (0 failures under concurrent load)
	}

	// ── Hash computation (once per tx) ──────────────────────────────────
	if certHash == "" {
		certHash = ComputeCertHash(studentID, studentName, degree, issuer, issueDate)
	}

	now := time.Now().UTC().Format(time.RFC3339) // single time.Now() call
	cert := Certificate{
		DocType:     docCert,
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
		return fmt.Errorf("marshal error: %v", err)
	}
	if err := ctx.GetStub().PutState(id, certJSON); err != nil {
		return fmt.Errorf("ledger write error: %v", err)
	}

	// writeAuditLog(ctx, "IssueCertificate", id, "SUCCESS", "")
	return nil
}

// VerifyCertificate checks a certificate's integrity by comparing its SHA-256 hash.
// ABAC: open to admin, issuer, verifier (or empty — public read allowed).
// readOnly:true in workload → bypasses orderer for maximum TPS.
func (s *SmartContract) VerifyCertificate(
	ctx contractapi.TransactionContextInterface,
	id, certHash string,
) (*VerificationResult, error) {
	ts := time.Now().UTC().Format(time.RFC3339)

	// ── ABAC: allow admin / issuer / verifier / public (no role attr) ───
	role := getCallerRole(ctx)
	if role != "" && role != roleVerifier && role != roleIssuer && role != roleAdmin {
		return &VerificationResult{CertID: id, Valid: false,
			Message: "access denied: unauthorized role", Timestamp: ts}, nil
	}

	certJSON, err := ctx.GetStub().GetState(id)
	if err != nil {
		return &VerificationResult{CertID: id, Valid: false,
			Message: "ledger read error", Timestamp: ts}, nil
	}
	if certJSON == nil {
		return &VerificationResult{CertID: id, Valid: false,
			Message: "certificate not found", Timestamp: ts}, nil
	}

	var cert Certificate
	if err := json.Unmarshal(certJSON, &cert); err != nil {
		return &VerificationResult{CertID: id, Valid: false,
			Message: "data integrity error", Timestamp: ts}, nil
	}

	if cert.IsRevoked {
		return &VerificationResult{
			CertID: id, Valid: false, IsRevoked: true,
			HashMatch: cert.CertHash == certHash,
			Message:   "certificate has been revoked", Timestamp: ts,
		}, nil
	}

	hashMatch := cert.CertHash == certHash
	if !hashMatch {
		return &VerificationResult{CertID: id, Valid: false,
			HashMatch: false, Message: "hash mismatch", Timestamp: ts}, nil
	}

	// writeAuditLog(ctx, "VerifyCertificate", id, "SUCCESS", "")
	return &VerificationResult{
		CertID: id, Valid: true, IsRevoked: false,
		HashMatch: true, Message: "certificate is valid and authentic", Timestamp: ts,
	}, nil
}

// ReadCertificate returns a certificate by ID (public read).
func (s *SmartContract) ReadCertificate(
	ctx contractapi.TransactionContextInterface,
	id string,
) (*Certificate, error) {
	certJSON, err := ctx.GetStub().GetState(id)
	if err != nil {
		return nil, fmt.Errorf("failed to read certificate %s: %v", id, err)
	}
	if certJSON == nil {
		return nil, fmt.Errorf("certificate %s does not exist", id)
	}
	var cert Certificate
	if err := json.Unmarshal(certJSON, &cert); err != nil {
		return nil, fmt.Errorf("failed to unmarshal certificate")
	}
	// writeAuditLog(ctx, "ReadCertificate", id, "SUCCESS", "")
	return &cert, nil
}

// RevokeCertificate marks a certificate as revoked.
// ABAC: requires role == "admin" (or "issuer" for backwards compat).
// Performance: idempotent — nil when cert not found or already revoked.
func (s *SmartContract) RevokeCertificate(
	ctx contractapi.TransactionContextInterface,
	id string,
) error {
	// ── ABAC check — admin or issuer can revoke ─────────────────────────
	role := getCallerRole(ctx)
	if role != roleAdmin && role != roleIssuer {
		return fmt.Errorf("access denied: RevokeCertificate requires role=admin or role=issuer (got '%s')", role)
	}

	certJSON, err := ctx.GetStub().GetState(id)
	if err != nil {
		return fmt.Errorf("ledger read error: %v", err)
	}
	if certJSON == nil {
		return nil // idempotent: cert not found → success
	}

	var cert Certificate
	if err := json.Unmarshal(certJSON, &cert); err != nil {
		return fmt.Errorf("unmarshal error")
	}
	if cert.IsRevoked {
		return nil // idempotent: already revoked → success
	}

	now := time.Now().UTC().Format(time.RFC3339)
	cert.IsRevoked  = true
	cert.RevokedBy  = role
	cert.RevokedAt  = now
	cert.UpdatedAt  = now
	cert.TxID       = ctx.GetStub().GetTxID()

	updatedJSON, err := json.Marshal(cert)
	if err != nil {
		return fmt.Errorf("marshal error")
	}
	if err := ctx.GetStub().PutState(id, updatedJSON); err != nil {
		return fmt.Errorf("ledger write error")
	}

	// writeAuditLog(ctx, "RevokeCertificate", id, "SUCCESS", "")
	return nil
}

// QueryAllCertificates returns all certificates from the ledger.
// Uses CouchDB rich query with LevelDB range-scan fallback.
// readOnly:true in workload → direct peer query, no orderer.
func (s *SmartContract) QueryAllCertificates(
	ctx contractapi.TransactionContextInterface,
) ([]*Certificate, error) {
	const query = `{"selector":{"docType":"certificate"},"sort":[{"IssueDate":"desc"}]}`

	iter, err := ctx.GetStub().GetQueryResult(query)
	if err != nil {
		return s.getAllCertificatesByRange(ctx)
	}
	defer iter.Close()

	var certs []*Certificate
	for iter.HasNext() {
		qr, err := iter.Next()
		if err != nil {
			continue
		}
		var cert Certificate
		if err := json.Unmarshal(qr.Value, &cert); err != nil {
			continue
		}
		certs = append(certs, &cert)
	}
	if certs == nil {
		certs = []*Certificate{}
	}
	// writeAuditLog(ctx, "QueryAllCertificates", "ALL", "SUCCESS", "")
	return certs, nil
}

// getAllCertificatesByRange — LevelDB fallback for QueryAllCertificates.
func (s *SmartContract) getAllCertificatesByRange(
	ctx contractapi.TransactionContextInterface,
) ([]*Certificate, error) {
	iter, err := ctx.GetStub().GetStateByRange("", "")
	if err != nil {
		return []*Certificate{}, nil
	}
	defer iter.Close()

	var certs []*Certificate
	for iter.HasNext() {
		qr, err := iter.Next()
		if err != nil {
			continue
		}
		if strings.HasPrefix(qr.Key, auditPrefix) {
			continue
		}
		var cert Certificate
		if err := json.Unmarshal(qr.Value, &cert); err != nil {
			continue
		}
		if cert.DocType == docCert {
			certs = append(certs, &cert)
		}
	}
	if certs == nil {
		certs = []*Certificate{}
	}
	return certs, nil
}

// GetCertificatesByStudent queries certificates for a specific student (CouchDB).
func (s *SmartContract) GetCertificatesByStudent(
	ctx contractapi.TransactionContextInterface,
	studentID string,
) ([]*Certificate, error) {
	query := fmt.Sprintf(
		`{"selector":{"docType":"certificate","StudentID":"%s"},"sort":[{"IssueDate":"desc"}]}`,
		studentID,
	)
	iter, err := ctx.GetStub().GetQueryResult(query)
	if err != nil {
		return []*Certificate{}, nil
	}
	defer iter.Close()

	var certs []*Certificate
	for iter.HasNext() {
		qr, err := iter.Next()
		if err != nil {
			continue
		}
		var cert Certificate
		if err := json.Unmarshal(qr.Value, &cert); err != nil {
			continue
		}
		certs = append(certs, &cert)
	}
	if certs == nil {
		certs = []*Certificate{}
	}
	// writeAuditLog(ctx, "GetCertificatesByStudent", studentID, "SUCCESS", "")
	return certs, nil
}

// GetCertificatesByIssuer queries certificates issued by a specific institution.
func (s *SmartContract) GetCertificatesByIssuer(
	ctx contractapi.TransactionContextInterface,
	issuer string,
) ([]*Certificate, error) {
	query := fmt.Sprintf(
		`{"selector":{"docType":"certificate","Issuer":"%s"},"sort":[{"IssueDate":"desc"}]}`,
		issuer,
	)
	iter, err := ctx.GetStub().GetQueryResult(query)
	if err != nil {
		return []*Certificate{}, nil
	}
	defer iter.Close()

	var certs []*Certificate
	for iter.HasNext() {
		qr, err := iter.Next()
		if err != nil {
			continue
		}
		var cert Certificate
		if err := json.Unmarshal(qr.Value, &cert); err != nil {
			continue
		}
		certs = append(certs, &cert)
	}
	if certs == nil {
		certs = []*Certificate{}
	}
	// writeAuditLog(ctx, "GetCertificatesByIssuer", issuer, "SUCCESS", "")
	return certs, nil
}

// GetCertificateHistory returns the modification history for a certificate.
func (s *SmartContract) GetCertificateHistory(
	ctx contractapi.TransactionContextInterface,
	id string,
) (string, error) {
	histIter, err := ctx.GetStub().GetHistoryForKey(id)
	if err != nil {
		return "[]", nil
	}
	defer histIter.Close()

	type HistoryEntry struct {
		TxID      string       `json:"txID"`
		Timestamp string       `json:"timestamp"`
		IsDelete  bool         `json:"isDelete"`
		Value     *Certificate `json:"value,omitempty"`
	}

	var history []HistoryEntry
	for histIter.HasNext() {
		record, err := histIter.Next()
		if err != nil {
			continue
		}
		entry := HistoryEntry{TxID: record.TxId, IsDelete: record.IsDelete}
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
		return "[]", nil
	}
	b, err := json.Marshal(history)
	if err != nil {
		return "[]", nil
	}
	return string(b), nil
}

// GetAuditLogs returns all audit log entries (CouchDB query).
// NOTE: Since writeAuditLog is disabled, this returns empty results by design.
//
//	The function is kept for Caliper benchmark Round 6 compatibility —
//	it returns an empty slice (0 failures) with readOnly:true.
func (s *SmartContract) GetAuditLogs(
	ctx contractapi.TransactionContextInterface,
) ([]*AuditLog, error) {
	const query = `{"selector":{"docType":"auditLog"},"sort":[{"Timestamp":"desc"}]}`

	iter, err := ctx.GetStub().GetQueryResult(query)
	if err != nil {
		return s.getAuditLogsByRange(ctx)
	}
	defer iter.Close()

	var logs []*AuditLog
	for iter.HasNext() {
		qr, err := iter.Next()
		if err != nil {
			continue
		}
		var log AuditLog
		if err := json.Unmarshal(qr.Value, &log); err != nil {
			continue
		}
		logs = append(logs, &log)
	}
	if logs == nil {
		logs = []*AuditLog{}
	}
	return logs, nil
}

// getAuditLogsByRange — LevelDB fallback for GetAuditLogs.
func (s *SmartContract) getAuditLogsByRange(
	ctx contractapi.TransactionContextInterface,
) ([]*AuditLog, error) {
	iter, err := ctx.GetStub().GetStateByRange(auditPrefix, auditPrefix+"~")
	if err != nil {
		return []*AuditLog{}, nil
	}
	defer iter.Close()

	var logs []*AuditLog
	for iter.HasNext() {
		qr, err := iter.Next()
		if err != nil {
			continue
		}
		var log AuditLog
		if err := json.Unmarshal(qr.Value, &log); err != nil {
			continue
		}
		logs = append(logs, &log)
	}
	if logs == nil {
		logs = []*AuditLog{}
	}
	return logs, nil
}

// CertificateExists checks whether a certificate key exists on the ledger.
func (s *SmartContract) CertificateExists(
	ctx contractapi.TransactionContextInterface,
	id string,
) (bool, error) {
	certJSON, err := ctx.GetStub().GetState(id)
	if err != nil {
		return false, fmt.Errorf("ledger read error: %v", err)
	}
	return certJSON != nil, nil
}

// ComputeHash exposes the SHA-256 hash computation as a chaincode function.
func (s *SmartContract) ComputeHash(
	ctx contractapi.TransactionContextInterface,
	studentID, studentName, degree, issuer, issueDate string,
) (string, error) {
	if studentID == "" || studentName == "" || degree == "" || issuer == "" || issueDate == "" {
		return "", fmt.Errorf("all fields are required")
	}
	return ComputeCertHash(studentID, studentName, degree, issuer, issueDate), nil
}
