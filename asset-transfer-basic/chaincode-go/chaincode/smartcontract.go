// ============================================================================
//  BCMS — Blockchain Certificate Management System
//  Hyperledger Fabric v2.5 | Go Chaincode
//  Research Paper Implementation: "Enhancing Trust and Transparency in
//  Education Using Blockchain: A Hyperledger Fabric-Based Framework"
//
//  Access Control Model: ABAC (Attribute-Based Access Control)
//  ─────────────────────────────────────────────────────────────
//  يعتمد هذا العقد الذكي بالكامل على نظام ABAC للتحكم في الوصول.
//  يتم التحقق من سمة (role) المضمّنة داخل شهادة X.509 لكل مستخدم.
//
//  توزيع الصلاحيات (Roles):
//    • role=admin    → InitLedger, RevokeCertificate
//    • role=issuer   → IssueCertificate, VerifyCertificate
//    • role=verifier → VerifyCertificate
//
//  ملاحظة: تم إزالة جميع تحققات RBAC (MSP ID) بالكامل.
//  السمة يجب أن تكون مطبوعة داخل الشهادة (ecert=true) عند التسجيل.
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

// Certificate — سجل الشهادة الأكاديمية المخزّن على السجل المحاسبي (Ledger).
type Certificate struct {
	DocType     string `json:"docType"`     // "certificate"
	ID          string `json:"ID"`          // IDc — معرّف الشهادة الفريد
	StudentID   string `json:"StudentID"`   // IDs — معرّف الطالب
	StudentName string `json:"StudentName"` // اسم الطالب
	Degree      string `json:"Degree"`      // الدرجة العلمية
	Issuer      string `json:"Issuer"`      // جهة الإصدار
	IssueDate   string `json:"IssueDate"`   // تاريخ الإصدار
	CertHash    string `json:"CertHash"`    // H(C) — SHA-256 لبيانات الشهادة
	Signature   string `json:"Signature"`   // التوقيع الرقمي للمُصدِر
	IsRevoked   bool   `json:"IsRevoked"`   // حالة الإلغاء
	RevokedBy   string `json:"RevokedBy"`   // اسم المستخدم (CN) الذي ألغى الشهادة
	RevokedAt   string `json:"RevokedAt"`   // وقت الإلغاء
	CreatedAt   string `json:"CreatedAt"`   // وقت الإنشاء
	UpdatedAt   string `json:"UpdatedAt"`   // آخر وقت تحديث
	TxID        string `json:"TxID"`        // معرّف معاملة Fabric
}

// AuditLog — سجل التدقيق غير القابل للتغيير لكل استدعاء للعقد الذكي.
type AuditLog struct {
	DocType   string `json:"docType"`   // "auditLog"
	TxID      string `json:"TxID"`      // معرّف المعاملة
	Function  string `json:"Function"`  // اسم الدالة
	CertID    string `json:"CertID"`    // معرّف الشهادة المستهدفة
	CallerCN  string `json:"CallerCN"`  // الاسم الشائع (CN) للمستخدم
	Role      string `json:"Role"`      // دور المستخدم (ABAC)
	Result    string `json:"Result"`    // "SUCCESS" | "FAILED"
	Error     string `json:"Error"`     // رسالة الخطأ (فارغة عند النجاح)
	Timestamp string `json:"Timestamp"` // الوقت بصيغة RFC3339
}

// VerificationResult — نتيجة التحقق من الشهادة.
type VerificationResult struct {
	CertID    string `json:"certID"`
	Valid     bool   `json:"valid"`
	IsRevoked bool   `json:"isRevoked"`
	HashMatch bool   `json:"hashMatch"`
	Message   string `json:"message"`
	Timestamp string `json:"timestamp"`
}

// SmartContract — العقد الذكي الرئيسي لـ Hyperledger Fabric.
type SmartContract struct {
	contractapi.Contract
}

// ─── Cryptographic Helpers ───────────────────────────────────────────────────

// ComputeCertHash — يحسب SHA-256 لبيانات الشهادة.
// الصيغة: H(C) = SHA256(StudentID|StudentName|Degree|Issuer|IssueDate)
func ComputeCertHash(studentID, studentName, degree, issuer, issueDate string) string {
	data := strings.Join([]string{studentID, studentName, degree, issuer, issueDate}, "|")
	hash := sha256.Sum256([]byte(data))
	return fmt.Sprintf("%x", hash)
}

// ─── ABAC Identity Helpers ───────────────────────────────────────────────────

// getCallerRole — يستخرج سمة (role) من شهادة X.509 للمستخدم المُستدعي.
// تعتمد هذه الدالة على أن السمة مطبوعة داخل الشهادة (ecert=true).
func getCallerRole(ctx contractapi.TransactionContextInterface) (string, error) {
	role, found, err := ctx.GetClientIdentity().GetAttributeValue("role")
	if err != nil {
		return "", fmt.Errorf("failed to read 'role' attribute from certificate: %v", err)
	}
	if !found {
		return "", fmt.Errorf("'role' attribute not found in certificate — ensure ecert=true was set during enrollment")
	}
	return role, nil
}

// getCallerCN — يستخرج الاسم الشائع (Common Name) من شهادة المستخدم.
func getCallerCN(ctx contractapi.TransactionContextInterface) string {
	cert, err := ctx.GetClientIdentity().GetX509Certificate()
	if err != nil || cert == nil {
		return "unknown"
	}
	return cert.Subject.CommonName
}

// ─── Audit Logging ───────────────────────────────────────────────────────────

// writeAuditLog — يكتب سجل تدقيق في السجل المحاسبي.
func writeAuditLog(
	ctx contractapi.TransactionContextInterface,
	function, certID, result, errMsg string,
) {
	txID := ctx.GetStub().GetTxID()
	callerCN := getCallerCN(ctx)

	// نحاول قراءة الدور، لكن لا نفشل إذا لم يكن موجوداً في سياق التدقيق
	callerRole, _ := ctx.GetClientIdentity().GetAttributeValue("role")
	if callerRole == "" {
		callerRole = "unknown"
	}

	ts := time.Now().UTC().Format(time.RFC3339)

	log := AuditLog{
		DocType:   "auditLog",
		TxID:      txID,
		Function:  function,
		CertID:    certID,
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
	_ = ctx.GetStub().PutState("AUDIT_"+txID, logJSON)
}

// ─── Smart Contract Functions ────────────────────────────────────────────────

// InitLedger — تهيئة السجل المحاسبي بشهادات تجريبية.
// الصلاحية المطلوبة: role=admin
func (s *SmartContract) InitLedger(ctx contractapi.TransactionContextInterface) error {
	// ── التحقق من الصلاحية (ABAC) ──────────────────────────────────────────
	role, err := getCallerRole(ctx)
	if err != nil {
		writeAuditLog(ctx, "InitLedger", "", "FAILED", err.Error())
		return fmt.Errorf("access denied: %v", err)
	}
	if role != "admin" {
		msg := fmt.Sprintf("access denied: role '%s' is not authorized — only 'admin' can initialize the ledger", role)
		writeAuditLog(ctx, "InitLedger", "", "FAILED", msg)
		return fmt.Errorf(msg)
	}
	// ────────────────────────────────────────────────────────────────────────

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
		now := time.Now().UTC().Format(time.RFC3339)
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
			CreatedAt:   now,
			UpdatedAt:   now,
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

	writeAuditLog(ctx, "InitLedger", "ALL_SEEDS", "SUCCESS", "")
	return nil
}

// IssueCertificate — إصدار شهادة أكاديمية جديدة.
// الصلاحية المطلوبة: role=issuer
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
	// ── التحقق من الصلاحية (ABAC) ──────────────────────────────────────────
	role, err := getCallerRole(ctx)
	if err != nil {
		writeAuditLog(ctx, "IssueCertificate", id, "FAILED", err.Error())
		return fmt.Errorf("access denied: %v", err)
	}
	if role != "issuer" {
		msg := fmt.Sprintf("access denied: role '%s' is not authorized — only 'issuer' can issue certificates", role)
		writeAuditLog(ctx, "IssueCertificate", id, "FAILED", msg)
		return fmt.Errorf(msg)
	}
	// ────────────────────────────────────────────────────────────────────────

	// ── التحقق من صحة المدخلات ──────────────────────────────────────────────
	if id == "" || studentID == "" || studentName == "" || degree == "" || issuer == "" || issueDate == "" {
		msg := "validation error: missing required fields (id, studentID, studentName, degree, issuer, issueDate)"
		writeAuditLog(ctx, "IssueCertificate", id, "FAILED", msg)
		return fmt.Errorf(msg)
	}

	// ── التحقق من عدم وجود الشهادة مسبقاً (Idempotency) ──────────────────
	existing, err := ctx.GetStub().GetState(id)
	if err != nil {
		return fmt.Errorf("failed to read ledger: %v", err)
	}
	if existing != nil {
		// الشهادة موجودة مسبقاً — نعيد النجاح بدلاً من الفشل (Idempotent)
		return nil
	}

	// ── حساب أو التحقق من Hash الشهادة ────────────────────────────────────
	computedHash := ComputeCertHash(studentID, studentName, degree, issuer, issueDate)
	if certHash == "" {
		certHash = computedHash
	}

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
		return fmt.Errorf("failed to marshal certificate: %v", err)
	}

	if err := ctx.GetStub().PutState(id, certJSON); err != nil {
		msg := fmt.Sprintf("failed to write certificate to ledger: %v", err)
		writeAuditLog(ctx, "IssueCertificate", id, "FAILED", msg)
		return fmt.Errorf(msg)
	}

	writeAuditLog(ctx, "IssueCertificate", id, "SUCCESS", "")
	return nil
}

// VerifyCertificate — التحقق من صحة شهادة أكاديمية.
// الصلاحية المطلوبة: role=verifier أو role=issuer أو role=admin
func (s *SmartContract) VerifyCertificate(
	ctx contractapi.TransactionContextInterface,
	id string,
	certHash string,
) (*VerificationResult, error) {
	ts := time.Now().UTC().Format(time.RFC3339)

	// ── التحقق من الصلاحية (ABAC) ──────────────────────────────────────────
	role, err := getCallerRole(ctx)
	if err != nil {
		writeAuditLog(ctx, "VerifyCertificate", id, "FAILED", err.Error())
		return &VerificationResult{
			CertID:    id,
			Valid:     false,
			Message:   fmt.Sprintf("access denied: %v", err),
			Timestamp: ts,
		}, nil
	}

	authorizedRoles := map[string]bool{
		"verifier": true,
		"issuer":   true,
		"admin":    true,
	}
	if !authorizedRoles[role] {
		msg := fmt.Sprintf("access denied: role '%s' is not authorized — allowed roles: verifier, issuer, admin", role)
		writeAuditLog(ctx, "VerifyCertificate", id, "FAILED", msg)
		return &VerificationResult{
			CertID:    id,
			Valid:     false,
			Message:   msg,
			Timestamp: ts,
		}, nil
	}
	// ────────────────────────────────────────────────────────────────────────

	// ── قراءة الشهادة من السجل ─────────────────────────────────────────────
	certJSON, err := ctx.GetStub().GetState(id)
	if err != nil {
		return &VerificationResult{
			CertID:    id,
			Valid:     false,
			Message:   "ledger read error",
			Timestamp: ts,
		}, nil
	}
	if certJSON == nil {
		return &VerificationResult{
			CertID:    id,
			Valid:     false,
			Message:   "certificate not found",
			Timestamp: ts,
		}, nil
	}

	var cert Certificate
	if err := json.Unmarshal(certJSON, &cert); err != nil {
		return &VerificationResult{
			CertID:    id,
			Valid:     false,
			Message:   "data integrity error",
			Timestamp: ts,
		}, nil
	}

	// ── التحقق من حالة الإلغاء ─────────────────────────────────────────────
	if cert.IsRevoked {
		writeAuditLog(ctx, "VerifyCertificate", id, "SUCCESS", "certificate is revoked")
		return &VerificationResult{
			CertID:    id,
			Valid:     false,
			IsRevoked: true,
			HashMatch: cert.CertHash == certHash,
			Message:   fmt.Sprintf("certificate has been revoked by %s at %s", cert.RevokedBy, cert.RevokedAt),
			Timestamp: ts,
		}, nil
	}

	// ── التحقق من تطابق الـ Hash ────────────────────────────────────────────
	hashMatch := cert.CertHash == certHash
	if !hashMatch {
		writeAuditLog(ctx, "VerifyCertificate", id, "SUCCESS", "hash mismatch")
		return &VerificationResult{
			CertID:    id,
			Valid:     false,
			IsRevoked: false,
			HashMatch: false,
			Message:   "hash mismatch — certificate data may have been tampered with",
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

// RevokeCertificate — إلغاء شهادة أكاديمية.
// الصلاحية المطلوبة: role=admin
// يُسجَّل اسم المستخدم (CallerCN) في حقل RevokedBy بدلاً من MSP ID.
func (s *SmartContract) RevokeCertificate(
	ctx contractapi.TransactionContextInterface,
	id string,
) error {
	// ── التحقق من الصلاحية (ABAC) ──────────────────────────────────────────
	role, err := getCallerRole(ctx)
	if err != nil {
		writeAuditLog(ctx, "RevokeCertificate", id, "FAILED", err.Error())
		return fmt.Errorf("access denied: %v", err)
	}
	if role != "admin" {
		msg := fmt.Sprintf("access denied: role '%s' is not authorized — only 'admin' can revoke certificates", role)
		writeAuditLog(ctx, "RevokeCertificate", id, "FAILED", msg)
		return fmt.Errorf(msg)
	}
	// ────────────────────────────────────────────────────────────────────────

	// ── قراءة الشهادة ──────────────────────────────────────────────────────
	certJSON, err := ctx.GetStub().GetState(id)
	if err != nil {
		return fmt.Errorf("failed to read certificate %s: %v", id, err)
	}
	if certJSON == nil {
		// الشهادة غير موجودة — نعيد النجاح (Idempotent)
		return nil
	}

	var cert Certificate
	if err := json.Unmarshal(certJSON, &cert); err != nil {
		return fmt.Errorf("failed to unmarshal certificate")
	}

	if cert.IsRevoked {
		// الشهادة ملغاة بالفعل — نعيد النجاح (Idempotent)
		return nil
	}

	// ── تحديث حالة الشهادة ─────────────────────────────────────────────────
	now := time.Now().UTC().Format(time.RFC3339)

	// يُستخدم CallerCN (اسم المستخدم من شهادة X.509) بدلاً من MSP ID
	callerCN := getCallerCN(ctx)

	cert.IsRevoked = true
	cert.RevokedBy = callerCN // ABAC: اسم المستخدم الفعلي، لا المنظمة
	cert.RevokedAt = now
	cert.UpdatedAt = now
	cert.TxID = ctx.GetStub().GetTxID()

	updatedJSON, err := json.Marshal(cert)
	if err != nil {
		return fmt.Errorf("failed to marshal certificate")
	}

	if err := ctx.GetStub().PutState(id, updatedJSON); err != nil {
		msg := fmt.Sprintf("failed to update certificate: %v", err)
		writeAuditLog(ctx, "RevokeCertificate", id, "FAILED", msg)
		return fmt.Errorf(msg)
	}

	writeAuditLog(ctx, "RevokeCertificate", id, "SUCCESS", "")
	return nil
}

// ReadCertificate — قراءة شهادة بمعرّفها.
// لا تحتاج إلى دور معيّن — متاحة للجميع.
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

	writeAuditLog(ctx, "ReadCertificate", id, "SUCCESS", "")
	return &cert, nil
}

// QueryAllCertificates — استعلام عن جميع الشهادات.
// لا تحتاج إلى دور معيّن — متاحة للجميع.
func (s *SmartContract) QueryAllCertificates(
	ctx contractapi.TransactionContextInterface,
) ([]*Certificate, error) {
	queryString := `{"selector":{"docType":"certificate"},"sort":[{"IssueDate":"desc"}]}`

	resultsIterator, err := ctx.GetStub().GetQueryResult(queryString)
	if err != nil {
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

// getAllCertificatesByRange — fallback عند عدم دعم CouchDB.
func (s *SmartContract) getAllCertificatesByRange(
	ctx contractapi.TransactionContextInterface,
) ([]*Certificate, error) {
	resultsIterator, err := ctx.GetStub().GetStateByRange("", "")
	if err != nil {
		return []*Certificate{}, nil
	}
	defer resultsIterator.Close()

	var certificates []*Certificate
	for resultsIterator.HasNext() {
		queryResponse, err := resultsIterator.Next()
		if err != nil {
			continue
		}
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

// GetCertificatesByStudent — الاستعلام عن شهادات طالب معيّن.
// لا تحتاج إلى دور معيّن — متاحة للجميع.
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

// GetCertificatesByIssuer — الاستعلام عن شهادات جهة إصدار معيّنة.
// لا تحتاج إلى دور معيّن — متاحة للجميع.
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

// GetCertificateHistory — استرداد تاريخ تعديلات شهادة معيّنة.
// لا تحتاج إلى دور معيّن — متاحة للجميع.
func (s *SmartContract) GetCertificateHistory(
	ctx contractapi.TransactionContextInterface,
	id string,
) (string, error) {
	historyIterator, err := ctx.GetStub().GetHistoryForKey(id)
	if err != nil {
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
		return "[]", nil
	}

	historyJSON, err := json.Marshal(history)
	if err != nil {
		return "[]", nil
	}

	writeAuditLog(ctx, "GetCertificateHistory", id, "SUCCESS", "")
	return string(historyJSON), nil
}

// GetAuditLogs — استرداد سجلات التدقيق.
// لا تحتاج إلى دور معيّن — متاحة للجميع.
func (s *SmartContract) GetAuditLogs(
	ctx contractapi.TransactionContextInterface,
) ([]*AuditLog, error) {
	queryString := `{"selector":{"docType":"auditLog"},"sort":[{"Timestamp":"desc"}]}`

	resultsIterator, err := ctx.GetStub().GetQueryResult(queryString)
	if err != nil {
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

// getAuditLogsByRange — fallback لاسترداد سجلات التدقيق.
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

// CertificateExists — التحقق من وجود شهادة.
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

// ComputeHash — حساب Hash لبيانات شهادة معيّنة.
func (s *SmartContract) ComputeHash(
	ctx contractapi.TransactionContextInterface,
	studentID string,
	studentName string,
	degree string,
	issuer string,
	issueDate string,
) (string, error) {
	if studentID == "" || studentName == "" || degree == "" || issuer == "" || issueDate == "" {
		return "", fmt.Errorf("all fields are required")
	}
	hash := ComputeCertHash(studentID, studentName, degree, issuer, issueDate)
	return hash, nil
}
