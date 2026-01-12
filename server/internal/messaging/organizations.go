package messaging

import (
	"net/http"
	"time"

	"github.com/gin-gonic/gin"
	"github.com/google/uuid"
	"github.com/kuurier/server/internal/config"
	"github.com/kuurier/server/internal/storage"
)

// OrganizationHandler handles organization-related endpoints
type OrganizationHandler struct {
	cfg *config.Config
	db  *storage.Postgres
}

// NewOrganizationHandler creates a new organization handler
func NewOrganizationHandler(cfg *config.Config, db *storage.Postgres) *OrganizationHandler {
	return &OrganizationHandler{cfg: cfg, db: db}
}

// Organization represents an organization
type Organization struct {
	ID          string    `json:"id"`
	Name        string    `json:"name"`
	Description *string   `json:"description,omitempty"`
	AvatarURL   *string   `json:"avatar_url,omitempty"`
	IsPublic    bool      `json:"is_public"`
	CreatedBy   string    `json:"created_by"`
	CreatedAt   time.Time `json:"created_at"`
	MemberCount int       `json:"member_count,omitempty"`
	Role        string    `json:"role,omitempty"` // Current user's role
}

// CreateOrganizationRequest is the request for creating an organization
type CreateOrganizationRequest struct {
	Name        string  `json:"name" binding:"required,min=1,max=100"`
	Description *string `json:"description"`
	IsPublic    bool    `json:"is_public"`
}

// CreateOrganization creates a new organization
func (h *OrganizationHandler) CreateOrganization(c *gin.Context) {
	userID := c.GetString("user_id")

	var req CreateOrganizationRequest
	if err := c.ShouldBindJSON(&req); err != nil {
		c.JSON(http.StatusBadRequest, gin.H{"error": "invalid request body"})
		return
	}

	ctx := c.Request.Context()
	orgID := uuid.New().String()
	now := time.Now().UTC()

	// Start transaction
	tx, err := h.db.Pool().Begin(ctx)
	if err != nil {
		c.JSON(http.StatusInternalServerError, gin.H{"error": "database error"})
		return
	}
	defer tx.Rollback(ctx)

	// Create organization
	_, err = tx.Exec(ctx, `
		INSERT INTO organizations (id, name, description, is_public, created_by, created_at, updated_at)
		VALUES ($1, $2, $3, $4, $5, $6, $6)
	`, orgID, req.Name, req.Description, req.IsPublic, userID, now)
	if err != nil {
		c.JSON(http.StatusInternalServerError, gin.H{"error": "failed to create organization"})
		return
	}

	// Add creator as admin
	_, err = tx.Exec(ctx, `
		INSERT INTO organization_members (org_id, user_id, role, joined_at)
		VALUES ($1, $2, 'admin', $3)
	`, orgID, userID, now)
	if err != nil {
		c.JSON(http.StatusInternalServerError, gin.H{"error": "failed to add creator as member"})
		return
	}

	// Create default #general channel
	channelID := uuid.New().String()
	_, err = tx.Exec(ctx, `
		INSERT INTO channels (id, org_id, name, description, type, created_by, created_at, updated_at)
		VALUES ($1, $2, 'general', 'General discussion', 'public', $3, $4, $4)
	`, channelID, orgID, userID, now)
	if err != nil {
		c.JSON(http.StatusInternalServerError, gin.H{"error": "failed to create default channel"})
		return
	}

	// Add creator to default channel
	_, err = tx.Exec(ctx, `
		INSERT INTO channel_members (channel_id, user_id, role, joined_at)
		VALUES ($1, $2, 'admin', $3)
	`, channelID, userID, now)
	if err != nil {
		c.JSON(http.StatusInternalServerError, gin.H{"error": "failed to add creator to channel"})
		return
	}

	if err := tx.Commit(ctx); err != nil {
		c.JSON(http.StatusInternalServerError, gin.H{"error": "failed to commit transaction"})
		return
	}

	c.JSON(http.StatusCreated, Organization{
		ID:          orgID,
		Name:        req.Name,
		Description: req.Description,
		IsPublic:    req.IsPublic,
		CreatedBy:   userID,
		CreatedAt:   now,
		MemberCount: 1,
		Role:        "admin",
	})
}

// ListOrganizations returns organizations the user is a member of
func (h *OrganizationHandler) ListOrganizations(c *gin.Context) {
	userID := c.GetString("user_id")
	ctx := c.Request.Context()

	rows, err := h.db.Pool().Query(ctx, `
		SELECT o.id, o.name, o.description, o.avatar_url, o.is_public, o.created_by, o.created_at,
		       om.role,
		       (SELECT COUNT(*) FROM organization_members WHERE org_id = o.id) as member_count
		FROM organizations o
		JOIN organization_members om ON o.id = om.org_id
		WHERE om.user_id = $1
		ORDER BY o.name
	`, userID)
	if err != nil {
		c.JSON(http.StatusInternalServerError, gin.H{"error": "failed to fetch organizations"})
		return
	}
	defer rows.Close()

	var orgs []Organization
	for rows.Next() {
		var org Organization
		if err := rows.Scan(&org.ID, &org.Name, &org.Description, &org.AvatarURL,
			&org.IsPublic, &org.CreatedBy, &org.CreatedAt, &org.Role, &org.MemberCount); err != nil {
			continue
		}
		orgs = append(orgs, org)
	}

	c.JSON(http.StatusOK, gin.H{"organizations": orgs})
}

// GetOrganization returns details of a specific organization
func (h *OrganizationHandler) GetOrganization(c *gin.Context) {
	userID := c.GetString("user_id")
	orgID := c.Param("id")
	ctx := c.Request.Context()

	var org Organization
	var isMember bool
	err := h.db.Pool().QueryRow(ctx, `
		SELECT o.id, o.name, o.description, o.avatar_url, o.is_public, o.created_by, o.created_at,
		       COALESCE(om.role, ''),
		       (SELECT COUNT(*) FROM organization_members WHERE org_id = o.id) as member_count,
		       om.user_id IS NOT NULL as is_member
		FROM organizations o
		LEFT JOIN organization_members om ON o.id = om.org_id AND om.user_id = $2
		WHERE o.id = $1
	`, orgID, userID).Scan(&org.ID, &org.Name, &org.Description, &org.AvatarURL,
		&org.IsPublic, &org.CreatedBy, &org.CreatedAt, &org.Role, &org.MemberCount, &isMember)

	if err != nil {
		c.JSON(http.StatusNotFound, gin.H{"error": "organization not found"})
		return
	}

	// Non-members can only see public orgs
	if !isMember && !org.IsPublic {
		c.JSON(http.StatusNotFound, gin.H{"error": "organization not found"})
		return
	}

	c.JSON(http.StatusOK, org)
}

// UpdateOrganizationRequest is the request for updating an organization
type UpdateOrganizationRequest struct {
	Name        *string `json:"name"`
	Description *string `json:"description"`
	IsPublic    *bool   `json:"is_public"`
}

// UpdateOrganization updates organization details (admin only)
func (h *OrganizationHandler) UpdateOrganization(c *gin.Context) {
	userID := c.GetString("user_id")
	orgID := c.Param("id")

	// Check if user is admin
	ctx := c.Request.Context()
	var role string
	err := h.db.Pool().QueryRow(ctx, `
		SELECT role FROM organization_members WHERE org_id = $1 AND user_id = $2
	`, orgID, userID).Scan(&role)

	if err != nil || role != "admin" {
		c.JSON(http.StatusForbidden, gin.H{"error": "only admins can update organizations"})
		return
	}

	var req UpdateOrganizationRequest
	if err := c.ShouldBindJSON(&req); err != nil {
		c.JSON(http.StatusBadRequest, gin.H{"error": "invalid request body"})
		return
	}

	// Build update query dynamically
	updates := []string{}
	args := []interface{}{orgID}
	argIdx := 2

	if req.Name != nil {
		updates = append(updates, "name = $"+string(rune('0'+argIdx)))
		args = append(args, *req.Name)
		argIdx++
	}
	if req.Description != nil {
		updates = append(updates, "description = $"+string(rune('0'+argIdx)))
		args = append(args, *req.Description)
		argIdx++
	}
	if req.IsPublic != nil {
		updates = append(updates, "is_public = $"+string(rune('0'+argIdx)))
		args = append(args, *req.IsPublic)
		argIdx++
	}

	if len(updates) == 0 {
		c.JSON(http.StatusBadRequest, gin.H{"error": "no updates provided"})
		return
	}

	query := "UPDATE organizations SET updated_at = NOW()"
	for _, u := range updates {
		query += ", " + u
	}
	query += " WHERE id = $1"

	_, err = h.db.Pool().Exec(ctx, query, args...)
	if err != nil {
		c.JSON(http.StatusInternalServerError, gin.H{"error": "failed to update organization"})
		return
	}

	c.JSON(http.StatusOK, gin.H{"message": "organization updated"})
}

// DeleteOrganization deletes an organization (admin only)
func (h *OrganizationHandler) DeleteOrganization(c *gin.Context) {
	userID := c.GetString("user_id")
	orgID := c.Param("id")
	ctx := c.Request.Context()

	// Check if user is admin
	var role string
	err := h.db.Pool().QueryRow(ctx, `
		SELECT role FROM organization_members WHERE org_id = $1 AND user_id = $2
	`, orgID, userID).Scan(&role)

	if err != nil || role != "admin" {
		c.JSON(http.StatusForbidden, gin.H{"error": "only admins can delete organizations"})
		return
	}

	// Delete organization (cascades to members, channels, etc.)
	_, err = h.db.Pool().Exec(ctx, `DELETE FROM organizations WHERE id = $1`, orgID)
	if err != nil {
		c.JSON(http.StatusInternalServerError, gin.H{"error": "failed to delete organization"})
		return
	}

	c.JSON(http.StatusOK, gin.H{"message": "organization deleted"})
}

// JoinOrganization joins a public organization
func (h *OrganizationHandler) JoinOrganization(c *gin.Context) {
	userID := c.GetString("user_id")
	orgID := c.Param("id")
	ctx := c.Request.Context()

	// Check if org is public
	var isPublic bool
	err := h.db.Pool().QueryRow(ctx, `
		SELECT is_public FROM organizations WHERE id = $1
	`, orgID).Scan(&isPublic)

	if err != nil {
		c.JSON(http.StatusNotFound, gin.H{"error": "organization not found"})
		return
	}

	if !isPublic {
		c.JSON(http.StatusForbidden, gin.H{"error": "this organization requires an invite"})
		return
	}

	// Add as member (ignore if already member)
	_, err = h.db.Pool().Exec(ctx, `
		INSERT INTO organization_members (org_id, user_id, role, joined_at)
		VALUES ($1, $2, 'member', NOW())
		ON CONFLICT (org_id, user_id) DO NOTHING
	`, orgID, userID)
	if err != nil {
		c.JSON(http.StatusInternalServerError, gin.H{"error": "failed to join organization"})
		return
	}

	// Also add to all public channels in the org
	_, err = h.db.Pool().Exec(ctx, `
		INSERT INTO channel_members (channel_id, user_id, role, joined_at)
		SELECT c.id, $2, 'member', NOW()
		FROM channels c
		WHERE c.org_id = $1 AND c.type = 'public'
		ON CONFLICT (channel_id, user_id) DO NOTHING
	`, orgID, userID)
	if err != nil {
		// Non-critical, log but continue
	}

	c.JSON(http.StatusOK, gin.H{"message": "joined organization"})
}

// LeaveOrganization leaves an organization
func (h *OrganizationHandler) LeaveOrganization(c *gin.Context) {
	userID := c.GetString("user_id")
	orgID := c.Param("id")
	ctx := c.Request.Context()

	// Check if user is the only admin
	var adminCount int
	var userRole string
	err := h.db.Pool().QueryRow(ctx, `
		SELECT
			(SELECT COUNT(*) FROM organization_members WHERE org_id = $1 AND role = 'admin'),
			COALESCE((SELECT role FROM organization_members WHERE org_id = $1 AND user_id = $2), '')
	`, orgID, userID).Scan(&adminCount, &userRole)

	if err != nil || userRole == "" {
		c.JSON(http.StatusNotFound, gin.H{"error": "not a member of this organization"})
		return
	}

	if userRole == "admin" && adminCount <= 1 {
		c.JSON(http.StatusForbidden, gin.H{"error": "cannot leave: you are the only admin. Transfer ownership first."})
		return
	}

	// Remove from org and all channels in org
	tx, err := h.db.Pool().Begin(ctx)
	if err != nil {
		c.JSON(http.StatusInternalServerError, gin.H{"error": "database error"})
		return
	}
	defer tx.Rollback(ctx)

	_, err = tx.Exec(ctx, `
		DELETE FROM channel_members
		WHERE user_id = $1 AND channel_id IN (SELECT id FROM channels WHERE org_id = $2)
	`, userID, orgID)
	if err != nil {
		c.JSON(http.StatusInternalServerError, gin.H{"error": "failed to leave channels"})
		return
	}

	_, err = tx.Exec(ctx, `
		DELETE FROM organization_members WHERE org_id = $1 AND user_id = $2
	`, orgID, userID)
	if err != nil {
		c.JSON(http.StatusInternalServerError, gin.H{"error": "failed to leave organization"})
		return
	}

	if err := tx.Commit(ctx); err != nil {
		c.JSON(http.StatusInternalServerError, gin.H{"error": "failed to commit transaction"})
		return
	}

	c.JSON(http.StatusOK, gin.H{"message": "left organization"})
}

// ListPublicOrganizations returns public organizations for discovery
func (h *OrganizationHandler) ListPublicOrganizations(c *gin.Context) {
	ctx := c.Request.Context()

	rows, err := h.db.Pool().Query(ctx, `
		SELECT o.id, o.name, o.description, o.avatar_url, o.created_at,
		       (SELECT COUNT(*) FROM organization_members WHERE org_id = o.id) as member_count
		FROM organizations o
		WHERE o.is_public = true
		ORDER BY member_count DESC, o.created_at DESC
		LIMIT 50
	`)
	if err != nil {
		c.JSON(http.StatusInternalServerError, gin.H{"error": "failed to fetch organizations"})
		return
	}
	defer rows.Close()

	var orgs []Organization
	for rows.Next() {
		var org Organization
		org.IsPublic = true
		if err := rows.Scan(&org.ID, &org.Name, &org.Description, &org.AvatarURL,
			&org.CreatedAt, &org.MemberCount); err != nil {
			continue
		}
		orgs = append(orgs, org)
	}

	c.JSON(http.StatusOK, gin.H{"organizations": orgs})
}
