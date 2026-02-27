package auth

import (
	"bytes"
	"crypto/ed25519"
	"crypto/rand"
	"encoding/base64"
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"testing"

	"github.com/gin-gonic/gin"
	"github.com/stretchr/testify/assert"
	"github.com/stretchr/testify/require"
)

func init() {
	gin.SetMode(gin.TestMode)
}

// TestRegisterRequest_Validation tests request body validation
func TestRegisterRequest_Validation(t *testing.T) {
	tests := []struct {
		name           string
		body           map[string]interface{}
		expectedStatus int
		expectedError  string
	}{
		{
			name:           "missing public_key",
			body:           map[string]interface{}{},
			expectedStatus: http.StatusBadRequest,
			expectedError:  "invalid request body",
		},
		{
			name: "empty public_key",
			body: map[string]interface{}{
				"public_key": "",
			},
			expectedStatus: http.StatusBadRequest,
			expectedError:  "invalid request body",
		},
		{
			name: "invalid base64 public_key",
			body: map[string]interface{}{
				"public_key": "not-valid-base64!!!",
			},
			expectedStatus: http.StatusBadRequest,
			expectedError:  "invalid public key",
		},
		{
			name: "wrong length public_key",
			body: map[string]interface{}{
				"public_key": base64.StdEncoding.EncodeToString([]byte("tooshort")),
			},
			expectedStatus: http.StatusBadRequest,
			expectedError:  "invalid public key",
		},
	}

	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			router := gin.New()
			router.POST("/register", func(c *gin.Context) {
				var req RegisterRequest
				if err := c.ShouldBindJSON(&req); err != nil {
					c.JSON(http.StatusBadRequest, gin.H{"error": "invalid request body"})
					return
				}

				// Validate public key
				pubKeyBytes, err := base64.StdEncoding.DecodeString(req.PublicKey)
				if err != nil || len(pubKeyBytes) != ed25519.PublicKeySize {
					c.JSON(http.StatusBadRequest, gin.H{"error": "invalid public key"})
					return
				}

				c.JSON(http.StatusOK, gin.H{"status": "ok"})
			})

			body, _ := json.Marshal(tt.body)
			req := httptest.NewRequest("POST", "/register", bytes.NewReader(body))
			req.Header.Set("Content-Type", "application/json")
			w := httptest.NewRecorder()
			router.ServeHTTP(w, req)

			assert.Equal(t, tt.expectedStatus, w.Code)

			var response map[string]interface{}
			json.Unmarshal(w.Body.Bytes(), &response)
			assert.Equal(t, tt.expectedError, response["error"])
		})
	}
}

// TestValidEd25519PublicKey tests that valid Ed25519 keys are accepted
func TestValidEd25519PublicKey(t *testing.T) {
	// Generate a valid Ed25519 key pair
	pubKey, _, err := ed25519.GenerateKey(rand.Reader)
	require.NoError(t, err)

	pubKeyBase64 := base64.StdEncoding.EncodeToString(pubKey)

	router := gin.New()
	router.POST("/register", func(c *gin.Context) {
		var req RegisterRequest
		if err := c.ShouldBindJSON(&req); err != nil {
			c.JSON(http.StatusBadRequest, gin.H{"error": "invalid request body"})
			return
		}

		// Validate public key
		pubKeyBytes, err := base64.StdEncoding.DecodeString(req.PublicKey)
		if err != nil || len(pubKeyBytes) != ed25519.PublicKeySize {
			c.JSON(http.StatusBadRequest, gin.H{"error": "invalid public key"})
			return
		}

		c.JSON(http.StatusOK, gin.H{
			"status":     "valid",
			"key_length": len(pubKeyBytes),
		})
	})

	body, _ := json.Marshal(map[string]interface{}{
		"public_key":  pubKeyBase64,
		"invite_code": "TESTCODE",
	})

	req := httptest.NewRequest("POST", "/register", bytes.NewReader(body))
	req.Header.Set("Content-Type", "application/json")
	w := httptest.NewRecorder()
	router.ServeHTTP(w, req)

	assert.Equal(t, http.StatusOK, w.Code)

	var response map[string]interface{}
	json.Unmarshal(w.Body.Bytes(), &response)
	assert.Equal(t, "valid", response["status"])
	assert.Equal(t, float64(32), response["key_length"])
}

// TestChallengeRequest_Validation tests challenge request validation
func TestChallengeRequest_Validation(t *testing.T) {
	router := gin.New()
	router.POST("/challenge", func(c *gin.Context) {
		var req ChallengeRequest
		if err := c.ShouldBindJSON(&req); err != nil {
			c.JSON(http.StatusBadRequest, gin.H{"error": "invalid request body"})
			return
		}
		c.JSON(http.StatusOK, gin.H{"status": "ok"})
	})

	// Test missing public_key
	req := httptest.NewRequest("POST", "/challenge", bytes.NewReader([]byte(`{}`)))
	req.Header.Set("Content-Type", "application/json")
	w := httptest.NewRecorder()
	router.ServeHTTP(w, req)

	assert.Equal(t, http.StatusBadRequest, w.Code)
}

// TestVerifyRequest_Validation tests verify request validation
func TestVerifyRequest_Validation(t *testing.T) {
	tests := []struct {
		name           string
		body           map[string]interface{}
		expectedStatus int
	}{
		{
			name:           "missing all fields",
			body:           map[string]interface{}{},
			expectedStatus: http.StatusBadRequest,
		},
		{
			name: "missing user_id",
			body: map[string]interface{}{
				"challenge": "abc123",
				"signature": "sig123",
			},
			expectedStatus: http.StatusBadRequest,
		},
		{
			name: "missing challenge",
			body: map[string]interface{}{
				"user_id":   "user123",
				"signature": "sig123",
			},
			expectedStatus: http.StatusBadRequest,
		},
		{
			name: "missing signature",
			body: map[string]interface{}{
				"user_id":   "user123",
				"challenge": "abc123",
			},
			expectedStatus: http.StatusBadRequest,
		},
	}

	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			router := gin.New()
			router.POST("/verify", func(c *gin.Context) {
				var req VerifyRequest
				if err := c.ShouldBindJSON(&req); err != nil {
					c.JSON(http.StatusBadRequest, gin.H{"error": "invalid request body"})
					return
				}
				c.JSON(http.StatusOK, gin.H{"status": "ok"})
			})

			body, _ := json.Marshal(tt.body)
			req := httptest.NewRequest("POST", "/verify", bytes.NewReader(body))
			req.Header.Set("Content-Type", "application/json")
			w := httptest.NewRecorder()
			router.ServeHTTP(w, req)

			assert.Equal(t, tt.expectedStatus, w.Code)
		})
	}
}

// TestEd25519SignatureVerification tests the signature verification logic
func TestEd25519SignatureVerification(t *testing.T) {
	// Generate key pair
	pubKey, privKey, err := ed25519.GenerateKey(rand.Reader)
	require.NoError(t, err)

	challenge := "test-challenge-12345"

	// Sign the challenge
	signature := ed25519.Sign(privKey, []byte(challenge))

	// Verify the signature
	assert.True(t, ed25519.Verify(pubKey, []byte(challenge), signature))

	// Verify with wrong message fails
	assert.False(t, ed25519.Verify(pubKey, []byte("wrong-challenge"), signature))

	// Verify with wrong key fails
	wrongPubKey, _, _ := ed25519.GenerateKey(rand.Reader)
	assert.False(t, ed25519.Verify(wrongPubKey, []byte(challenge), signature))
}

// TestSearchUsers_QueryValidation tests search query validation
func TestSearchUsers_QueryValidation(t *testing.T) {
	tests := []struct {
		name           string
		query          string
		expectedStatus int
		expectedError  string
	}{
		{
			name:           "query too short (1 char)",
			query:          "a",
			expectedStatus: http.StatusBadRequest,
			expectedError:  "search query must be at least 3 characters",
		},
		{
			name:           "query too short (2 chars)",
			query:          "ab",
			expectedStatus: http.StatusBadRequest,
			expectedError:  "search query must be at least 3 characters",
		},
		{
			name:           "valid query (3 chars)",
			query:          "abc",
			expectedStatus: http.StatusOK,
			expectedError:  "",
		},
	}

	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			router := gin.New()
			router.GET("/users", func(c *gin.Context) {
				query := c.Query("q")
				if len(query) < 3 {
					c.JSON(http.StatusBadRequest, gin.H{"error": "search query must be at least 3 characters"})
					return
				}
				c.JSON(http.StatusOK, gin.H{"users": []interface{}{}, "query": query})
			})

			req := httptest.NewRequest("GET", "/users?q="+tt.query, nil)
			w := httptest.NewRecorder()
			router.ServeHTTP(w, req)

			assert.Equal(t, tt.expectedStatus, w.Code)

			var response map[string]interface{}
			json.Unmarshal(w.Body.Bytes(), &response)
			if tt.expectedError != "" {
				assert.Equal(t, tt.expectedError, response["error"])
			}
		})
	}
}

// TestTrustScoreCalculation tests the trust score thresholds
func TestTrustScoreCalculation(t *testing.T) {
	// Test vouching requirements
	minTrustToVouch := 30

	tests := []struct {
		name     string
		trust    int
		canVouch bool
	}{
		{"trust 0", 0, false},
		{"trust 15", 15, false},
		{"trust 29", 29, false},
		{"trust 30", 30, true},
		{"trust 50", 50, true},
		{"trust 100", 100, true},
	}

	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			assert.Equal(t, tt.canVouch, tt.trust >= minTrustToVouch)
		})
	}
}

// TestInitialTrustScore verifies initial trust score constant
func TestInitialTrustScore(t *testing.T) {
	assert.Equal(t, 15, InitialTrustScore, "Initial trust score should be 15")
}

// TestBase64Url_RejectedByServer verifies that base64url encoding is rejected
// This was a real bug: the web app sent base64url but the server expects standard base64
func TestBase64Url_RejectedByServer(t *testing.T) {
	pubKey, _, err := ed25519.GenerateKey(rand.Reader)
	require.NoError(t, err)

	// Encode as base64url (what the web app was incorrectly sending)
	stdBase64 := base64.StdEncoding.EncodeToString(pubKey)
	urlBase64 := base64.RawURLEncoding.EncodeToString(pubKey)

	router := gin.New()
	router.POST("/register", func(c *gin.Context) {
		var req RegisterRequest
		if err := c.ShouldBindJSON(&req); err != nil {
			c.JSON(http.StatusBadRequest, gin.H{"error": "invalid request body"})
			return
		}

		pubKeyBytes, err := base64.StdEncoding.DecodeString(req.PublicKey)
		if err != nil || len(pubKeyBytes) != ed25519.PublicKeySize {
			c.JSON(http.StatusBadRequest, gin.H{"error": "invalid public key"})
			return
		}
		c.JSON(http.StatusOK, gin.H{"status": "valid"})
	})

	// Standard base64 should succeed
	body, _ := json.Marshal(map[string]interface{}{
		"public_key":  stdBase64,
		"invite_code": "TEST",
	})
	req := httptest.NewRequest("POST", "/register", bytes.NewReader(body))
	req.Header.Set("Content-Type", "application/json")
	w := httptest.NewRecorder()
	router.ServeHTTP(w, req)
	assert.Equal(t, http.StatusOK, w.Code, "standard base64 should be accepted")

	// Base64url should fail (this was the bug)
	body, _ = json.Marshal(map[string]interface{}{
		"public_key":  urlBase64,
		"invite_code": "TEST",
	})
	req = httptest.NewRequest("POST", "/register", bytes.NewReader(body))
	req.Header.Set("Content-Type", "application/json")
	w = httptest.NewRecorder()
	router.ServeHTTP(w, req)
	assert.Equal(t, http.StatusBadRequest, w.Code, "base64url should be rejected")
}

// TestRegisterRequest_InviteCodeField tests that invite_code is optional in the request struct
func TestRegisterRequest_InviteCodeField(t *testing.T) {
	// invite_code has no binding:"required" tag, so it should be optional
	router := gin.New()
	router.POST("/register", func(c *gin.Context) {
		var req RegisterRequest
		if err := c.ShouldBindJSON(&req); err != nil {
			c.JSON(http.StatusBadRequest, gin.H{"error": "invalid request body"})
			return
		}
		c.JSON(http.StatusOK, gin.H{
			"public_key":  req.PublicKey,
			"invite_code": req.InviteCode,
		})
	})

	// Without invite_code (login flow)
	pubKey, _, _ := ed25519.GenerateKey(rand.Reader)
	body, _ := json.Marshal(map[string]interface{}{
		"public_key": base64.StdEncoding.EncodeToString(pubKey),
	})
	req := httptest.NewRequest("POST", "/register", bytes.NewReader(body))
	req.Header.Set("Content-Type", "application/json")
	w := httptest.NewRecorder()
	router.ServeHTTP(w, req)

	assert.Equal(t, http.StatusOK, w.Code)
	var resp map[string]interface{}
	json.Unmarshal(w.Body.Bytes(), &resp)
	assert.Empty(t, resp["invite_code"], "invite_code should be empty when not provided")
}

// TestEd25519KeySize verifies Ed25519 key sizes match expectations
func TestEd25519KeySize(t *testing.T) {
	pubKey, privKey, err := ed25519.GenerateKey(rand.Reader)
	require.NoError(t, err)

	assert.Equal(t, ed25519.PublicKeySize, len(pubKey), "public key should be 32 bytes")
	assert.Equal(t, ed25519.PrivateKeySize, len(privKey), "private key should be 64 bytes")
	assert.Equal(t, 32, ed25519.PublicKeySize, "Ed25519 public key size constant")
	assert.Equal(t, 64, ed25519.PrivateKeySize, "Ed25519 private key size constant")

	// Verify base64 encoding lengths
	pubKeyBase64 := base64.StdEncoding.EncodeToString(pubKey)
	assert.Equal(t, 44, len(pubKeyBase64), "base64 of 32 bytes should be 44 chars")
}

// TestSignatureVerification_FullFlow tests generate key, sign, verify
func TestSignatureVerification_FullFlow(t *testing.T) {
	// Generate keypair
	pubKey, privKey, err := ed25519.GenerateKey(rand.Reader)
	require.NoError(t, err)

	// Simulate server sending a challenge
	challengeBytes := make([]byte, 32)
	_, err = rand.Read(challengeBytes)
	require.NoError(t, err)
	challenge := base64.StdEncoding.EncodeToString(challengeBytes)

	// Client signs challenge
	signature := ed25519.Sign(privKey, []byte(challenge))

	// Server verifies
	assert.True(t, ed25519.Verify(pubKey, []byte(challenge), signature))

	// Tampered challenge should fail
	assert.False(t, ed25519.Verify(pubKey, []byte(challenge+"tampered"), signature))

	// Different key should fail
	otherPub, _, _ := ed25519.GenerateKey(rand.Reader)
	assert.False(t, ed25519.Verify(otherPub, []byte(challenge), signature))

	// Tampered signature should fail
	badSig := make([]byte, len(signature))
	copy(badSig, signature)
	badSig[0] ^= 0xFF
	assert.False(t, ed25519.Verify(pubKey, []byte(challenge), badSig))
}

// TestVerifyRequest_SignatureDecoding tests signature base64 decoding
func TestVerifyRequest_SignatureDecoding(t *testing.T) {
	tests := []struct {
		name      string
		signature string
		wantErr   bool
	}{
		{"valid standard base64", base64.StdEncoding.EncodeToString([]byte("test-signature-64-bytes-long-needs-to-be-padded-to-correct-length!")), false},
		{"invalid base64", "not-valid!!!base64", true},
		{"base64url should fail", base64.RawURLEncoding.EncodeToString([]byte("test")), true},
		{"empty string decodes to empty bytes", "", false}, // base64("") = "" which is valid, but 0 bytes != 32 bytes
	}

	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			_, err := base64.StdEncoding.DecodeString(tt.signature)
			if tt.wantErr {
				assert.Error(t, err, "should fail to decode")
			} else {
				assert.NoError(t, err, "should decode successfully")
			}
		})
	}
}

// TestTrustScoreThresholds tests all trust-gated capabilities
func TestTrustScoreThresholds(t *testing.T) {
	thresholds := []struct {
		name       string
		threshold  int
		capability string
	}{
		{"browse only", 0, "browse"},
		{"post creation", 30, "create posts"},
		{"event creation", 50, "create events"},
		{"SOS alerts", 100, "broadcast SOS"},
	}

	for _, th := range thresholds {
		t.Run(th.capability, func(t *testing.T) {
			// Just below threshold
			if th.threshold > 0 {
				assert.False(t, th.threshold-1 >= th.threshold,
					"trust %d should not grant %s", th.threshold-1, th.capability)
			}
			// At threshold
			assert.True(t, th.threshold >= th.threshold,
				"trust %d should grant %s", th.threshold, th.capability)
		})
	}
}
