package keys

import (
	"context"
	"encoding/base64"
	"errors"

	"github.com/kuurier/server/internal/storage"
)

var (
	// ErrNoKeys is returned when a user has not uploaded any keys
	ErrNoKeys = errors.New("user has not uploaded keys")
	// ErrInvalidKey is returned when a key fails validation
	ErrInvalidKey = errors.New("invalid key format")
)

// Service handles Signal key management business logic
type Service struct {
	db *storage.Postgres
}

// NewService creates a new keys service
func NewService(db *storage.Postgres) *Service {
	return &Service{db: db}
}

// KeyBundle represents a complete key bundle for a user
type KeyBundle struct {
	IdentityKey    string
	RegistrationID int
	SignedPreKey   SignedPreKey
	PreKeys        []PreKey  // For uploading
	PreKey         *PreKey   // For fetching (single consumed key)
}

// SignedPreKey represents a signed pre-key
type SignedPreKey struct {
	KeyID     int
	PublicKey string
	Signature string
}

// PreKey represents a one-time pre-key
type PreKey struct {
	KeyID     int
	PublicKey string
}

// UploadBundle stores a user's identity key, signed pre-key, and optionally pre-keys
func (s *Service) UploadBundle(ctx context.Context, userID string, bundle *KeyBundle) error {
	// Decode and validate identity key
	identityKeyBytes, err := base64.StdEncoding.DecodeString(bundle.IdentityKey)
	if err != nil || len(identityKeyBytes) != 32 {
		return ErrInvalidKey
	}

	// Decode signed pre-key
	signedPKBytes, err := base64.StdEncoding.DecodeString(bundle.SignedPreKey.PublicKey)
	if err != nil || len(signedPKBytes) != 32 {
		return ErrInvalidKey
	}

	signatureBytes, err := base64.StdEncoding.DecodeString(bundle.SignedPreKey.Signature)
	if err != nil || len(signatureBytes) != 64 {
		return ErrInvalidKey
	}

	// Start transaction
	tx, err := s.db.Pool().Begin(ctx)
	if err != nil {
		return err
	}
	defer tx.Rollback(ctx)

	// Upsert identity key
	_, err = tx.Exec(ctx, `
		INSERT INTO signal_identity_keys (user_id, identity_key, registration_id, updated_at)
		VALUES ($1, $2, $3, NOW())
		ON CONFLICT (user_id) DO UPDATE SET
			identity_key = EXCLUDED.identity_key,
			registration_id = EXCLUDED.registration_id,
			updated_at = NOW()
	`, userID, identityKeyBytes, bundle.RegistrationID)
	if err != nil {
		return err
	}

	// Upsert signed pre-key
	_, err = tx.Exec(ctx, `
		INSERT INTO signal_signed_prekeys (user_id, key_id, public_key, signature)
		VALUES ($1, $2, $3, $4)
		ON CONFLICT (user_id, key_id) DO UPDATE SET
			public_key = EXCLUDED.public_key,
			signature = EXCLUDED.signature,
			created_at = NOW()
	`, userID, bundle.SignedPreKey.KeyID, signedPKBytes, signatureBytes)
	if err != nil {
		return err
	}

	// Insert pre-keys if provided
	for _, pk := range bundle.PreKeys {
		pkBytes, err := base64.StdEncoding.DecodeString(pk.PublicKey)
		if err != nil || len(pkBytes) != 32 {
			continue // Skip invalid keys
		}

		_, err = tx.Exec(ctx, `
			INSERT INTO signal_prekeys (user_id, key_id, public_key)
			VALUES ($1, $2, $3)
			ON CONFLICT (user_id, key_id) DO NOTHING
		`, userID, pk.KeyID, pkBytes)
		if err != nil {
			return err
		}
	}

	return tx.Commit(ctx)
}

// GetBundle fetches a user's key bundle, consuming one pre-key
func (s *Service) GetBundle(ctx context.Context, userID string) (*KeyBundle, error) {
	// Start transaction for atomic pre-key consumption
	tx, err := s.db.Pool().Begin(ctx)
	if err != nil {
		return nil, err
	}
	defer tx.Rollback(ctx)

	// Get identity key
	var identityKeyBytes []byte
	var registrationID int
	err = tx.QueryRow(ctx, `
		SELECT identity_key, registration_id
		FROM signal_identity_keys
		WHERE user_id = $1
	`, userID).Scan(&identityKeyBytes, &registrationID)
	if err != nil {
		return nil, ErrNoKeys
	}

	// Get latest signed pre-key
	var signedKeyID int
	var signedPKBytes, signatureBytes []byte
	err = tx.QueryRow(ctx, `
		SELECT key_id, public_key, signature
		FROM signal_signed_prekeys
		WHERE user_id = $1
		ORDER BY created_at DESC
		LIMIT 1
	`, userID).Scan(&signedKeyID, &signedPKBytes, &signatureBytes)
	if err != nil {
		return nil, ErrNoKeys
	}

	bundle := &KeyBundle{
		IdentityKey:    base64.StdEncoding.EncodeToString(identityKeyBytes),
		RegistrationID: registrationID,
		SignedPreKey: SignedPreKey{
			KeyID:     signedKeyID,
			PublicKey: base64.StdEncoding.EncodeToString(signedPKBytes),
			Signature: base64.StdEncoding.EncodeToString(signatureBytes),
		},
	}

	// Consume one pre-key (using the database function)
	var preKeyID int
	var preKeyBytes []byte
	err = tx.QueryRow(ctx, `SELECT * FROM consume_prekey($1)`, userID).Scan(&preKeyID, &preKeyBytes)
	if err == nil && preKeyBytes != nil {
		bundle.PreKey = &PreKey{
			KeyID:     preKeyID,
			PublicKey: base64.StdEncoding.EncodeToString(preKeyBytes),
		}
	}
	// No pre-key is okay - session can still be established with just signed pre-key

	if err := tx.Commit(ctx); err != nil {
		return nil, err
	}

	return bundle, nil
}

// UploadPreKeys adds additional one-time pre-keys for a user
func (s *Service) UploadPreKeys(ctx context.Context, userID string, preKeys []PreKey) error {
	// Verify user has identity key first
	var exists bool
	err := s.db.Pool().QueryRow(ctx, `
		SELECT EXISTS(SELECT 1 FROM signal_identity_keys WHERE user_id = $1)
	`, userID).Scan(&exists)
	if err != nil || !exists {
		return ErrNoKeys
	}

	tx, err := s.db.Pool().Begin(ctx)
	if err != nil {
		return err
	}
	defer tx.Rollback(ctx)

	for _, pk := range preKeys {
		pkBytes, err := base64.StdEncoding.DecodeString(pk.PublicKey)
		if err != nil || len(pkBytes) != 32 {
			continue // Skip invalid keys
		}

		_, err = tx.Exec(ctx, `
			INSERT INTO signal_prekeys (user_id, key_id, public_key)
			VALUES ($1, $2, $3)
			ON CONFLICT (user_id, key_id) DO NOTHING
		`, userID, pk.KeyID, pkBytes)
		if err != nil {
			return err
		}
	}

	return tx.Commit(ctx)
}

// GetPreKeyCount returns the number of remaining pre-keys for a user
func (s *Service) GetPreKeyCount(ctx context.Context, userID string) (int, error) {
	var count int
	err := s.db.Pool().QueryRow(ctx, `SELECT get_prekey_count($1)`, userID).Scan(&count)
	return count, err
}

// UpdateSignedPreKey updates the user's signed pre-key
func (s *Service) UpdateSignedPreKey(ctx context.Context, userID string, signedPreKey SignedPreKey) error {
	// Decode and validate
	signedPKBytes, err := base64.StdEncoding.DecodeString(signedPreKey.PublicKey)
	if err != nil || len(signedPKBytes) != 32 {
		return ErrInvalidKey
	}

	signatureBytes, err := base64.StdEncoding.DecodeString(signedPreKey.Signature)
	if err != nil || len(signatureBytes) != 64 {
		return ErrInvalidKey
	}

	// Verify user has identity key
	var exists bool
	err = s.db.Pool().QueryRow(ctx, `
		SELECT EXISTS(SELECT 1 FROM signal_identity_keys WHERE user_id = $1)
	`, userID).Scan(&exists)
	if err != nil || !exists {
		return ErrNoKeys
	}

	// Upsert signed pre-key
	_, err = s.db.Pool().Exec(ctx, `
		INSERT INTO signal_signed_prekeys (user_id, key_id, public_key, signature)
		VALUES ($1, $2, $3, $4)
		ON CONFLICT (user_id, key_id) DO UPDATE SET
			public_key = EXCLUDED.public_key,
			signature = EXCLUDED.signature,
			created_at = NOW()
	`, userID, signedPreKey.KeyID, signedPKBytes, signatureBytes)

	return err
}

// HasKeys checks if a user has uploaded their Signal keys
func (s *Service) HasKeys(ctx context.Context, userID string) (bool, error) {
	var exists bool
	err := s.db.Pool().QueryRow(ctx, `
		SELECT EXISTS(SELECT 1 FROM signal_identity_keys WHERE user_id = $1)
	`, userID).Scan(&exists)
	return exists, err
}
