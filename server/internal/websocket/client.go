package websocket

import (
	"encoding/json"
	"log"
	"net/http"
	"time"

	"github.com/gin-gonic/gin"
	"github.com/gorilla/websocket"
	"github.com/kuurier/server/internal/config"
)

const (
	// Time allowed to write a message to the peer
	writeWait = 10 * time.Second

	// Time allowed to read the next pong message from the peer
	pongWait = 60 * time.Second

	// Send pings to peer with this period (must be less than pongWait)
	pingPeriod = (pongWait * 9) / 10

	// Maximum message size allowed from peer
	maxMessageSize = 65536

	// Size of client send buffer
	sendBufferSize = 256
)

var upgrader = websocket.Upgrader{
	ReadBufferSize:  1024,
	WriteBufferSize: 1024,
	CheckOrigin: func(r *http.Request) bool {
		// In production, validate origin properly
		return true
	},
}

// Client represents a WebSocket client connection
type Client struct {
	hub      *Hub
	conn     *websocket.Conn
	send     chan []byte
	userID   string
	channels map[string]bool
}

// Handler handles WebSocket connections
type Handler struct {
	hub *Hub
	cfg *config.Config
}

// NewHandler creates a new WebSocket handler
func NewHandler(cfg *config.Config, hub *Hub) *Handler {
	return &Handler{
		hub: hub,
		cfg: cfg,
	}
}

// HandleConnection upgrades HTTP to WebSocket and handles the connection
func (h *Handler) HandleConnection(c *gin.Context) {
	userID := c.GetString("user_id")
	if userID == "" {
		c.JSON(http.StatusUnauthorized, gin.H{"error": "unauthorized"})
		return
	}

	conn, err := upgrader.Upgrade(c.Writer, c.Request, nil)
	if err != nil {
		log.Printf("Failed to upgrade connection: %v", err)
		return
	}

	client := &Client{
		hub:      h.hub,
		conn:     conn,
		send:     make(chan []byte, sendBufferSize),
		userID:   userID,
		channels: make(map[string]bool),
	}

	// Register client with hub
	h.hub.register <- client

	// Start goroutines for reading and writing
	go client.writePump()
	go client.readPump()
}

// readPump pumps messages from the WebSocket connection to the hub
func (c *Client) readPump() {
	defer func() {
		c.hub.unregister <- c
		c.conn.Close()
	}()

	c.conn.SetReadLimit(maxMessageSize)
	c.conn.SetReadDeadline(time.Now().Add(pongWait))
	c.conn.SetPongHandler(func(string) error {
		c.conn.SetReadDeadline(time.Now().Add(pongWait))
		return nil
	})

	for {
		_, message, err := c.conn.ReadMessage()
		if err != nil {
			if websocket.IsUnexpectedCloseError(err, websocket.CloseGoingAway, websocket.CloseAbnormalClosure) {
				log.Printf("WebSocket error: %v", err)
			}
			break
		}

		c.handleMessage(message)
	}
}

// writePump pumps messages from the hub to the WebSocket connection
func (c *Client) writePump() {
	ticker := time.NewTicker(pingPeriod)
	defer func() {
		ticker.Stop()
		c.conn.Close()
	}()

	for {
		select {
		case message, ok := <-c.send:
			c.conn.SetWriteDeadline(time.Now().Add(writeWait))
			if !ok {
				// Hub closed the channel
				c.conn.WriteMessage(websocket.CloseMessage, []byte{})
				return
			}

			w, err := c.conn.NextWriter(websocket.TextMessage)
			if err != nil {
				return
			}
			w.Write(message)

			// Add queued messages to the current WebSocket message
			n := len(c.send)
			for i := 0; i < n; i++ {
				w.Write([]byte{'\n'})
				w.Write(<-c.send)
			}

			if err := w.Close(); err != nil {
				return
			}

		case <-ticker.C:
			c.conn.SetWriteDeadline(time.Now().Add(writeWait))
			if err := c.conn.WriteMessage(websocket.PingMessage, nil); err != nil {
				return
			}
		}
	}
}

// handleMessage processes incoming WebSocket messages
func (c *Client) handleMessage(data []byte) {
	var msg Message
	if err := json.Unmarshal(data, &msg); err != nil {
		c.sendError("invalid message format")
		return
	}

	msg.UserID = c.userID
	msg.Timestamp = time.Now().UTC()

	switch msg.Type {
	case "ping":
		c.sendPong()

	case TypeSubscribe:
		c.handleSubscribe(&msg)

	case TypeUnsubscribe:
		c.handleUnsubscribe(&msg)

	case TypeMessageSend:
		c.handleMessageSend(&msg)

	case TypeMessageRead:
		c.handleMessageRead(&msg)

	case TypeTypingStart:
		c.handleTypingStart(&msg)

	case TypeTypingStop:
		c.handleTypingStop(&msg)

	default:
		c.sendError("unknown message type: " + msg.Type)
	}
}

// handleSubscribe subscribes client to a channel
func (c *Client) handleSubscribe(msg *Message) {
	if msg.ChannelID == "" {
		c.sendError("channel_id required")
		return
	}

	// TODO: Verify user has access to channel
	c.hub.SubscribeToChannel(c, msg.ChannelID)

	// Send confirmation
	c.sendJSON(&Message{
		Type:      "subscribed",
		ChannelID: msg.ChannelID,
		Timestamp: time.Now().UTC(),
	})
}

// handleUnsubscribe unsubscribes client from a channel
func (c *Client) handleUnsubscribe(msg *Message) {
	if msg.ChannelID == "" {
		c.sendError("channel_id required")
		return
	}

	c.hub.UnsubscribeFromChannel(c, msg.ChannelID)

	c.sendJSON(&Message{
		Type:      "unsubscribed",
		ChannelID: msg.ChannelID,
		Timestamp: time.Now().UTC(),
	})
}

// handleMessageSend handles sending a new message
func (c *Client) handleMessageSend(msg *Message) {
	if msg.ChannelID == "" {
		c.sendError("channel_id required")
		return
	}

	// Broadcast to all channel subscribers
	outMsg := &Message{
		Type:      TypeMessageNew,
		ChannelID: msg.ChannelID,
		UserID:    c.userID,
		Payload:   msg.Payload,
		Timestamp: time.Now().UTC(),
	}

	c.hub.BroadcastToChannel(msg.ChannelID, outMsg)
}

// handleMessageRead handles read receipts
func (c *Client) handleMessageRead(msg *Message) {
	if msg.ChannelID == "" {
		c.sendError("channel_id required")
		return
	}

	// Broadcast read receipt to channel
	outMsg := &Message{
		Type:      TypeMessageRead,
		ChannelID: msg.ChannelID,
		UserID:    c.userID,
		Payload:   msg.Payload,
		Timestamp: time.Now().UTC(),
	}

	c.hub.BroadcastToChannel(msg.ChannelID, outMsg)
}

// handleTypingStart handles typing start indicator
func (c *Client) handleTypingStart(msg *Message) {
	if msg.ChannelID == "" {
		c.sendError("channel_id required")
		return
	}

	outMsg := &Message{
		Type:      TypeTypingUpdate,
		ChannelID: msg.ChannelID,
		UserID:    c.userID,
		Payload:   json.RawMessage(`{"typing": true}`),
		Timestamp: time.Now().UTC(),
	}

	c.hub.BroadcastToChannel(msg.ChannelID, outMsg)
}

// handleTypingStop handles typing stop indicator
func (c *Client) handleTypingStop(msg *Message) {
	if msg.ChannelID == "" {
		c.sendError("channel_id required")
		return
	}

	outMsg := &Message{
		Type:      TypeTypingUpdate,
		ChannelID: msg.ChannelID,
		UserID:    c.userID,
		Payload:   json.RawMessage(`{"typing": false}`),
		Timestamp: time.Now().UTC(),
	}

	c.hub.BroadcastToChannel(msg.ChannelID, outMsg)
}

// sendError sends an error message to the client
func (c *Client) sendError(message string) {
	c.sendJSON(&Message{
		Type:      TypeError,
		Payload:   json.RawMessage(`{"error": "` + message + `"}`),
		Timestamp: time.Now().UTC(),
	})
}

// sendPong sends a pong response
func (c *Client) sendPong() {
	c.sendJSON(&Message{
		Type:      TypePong,
		Timestamp: time.Now().UTC(),
	})
}

// sendJSON sends a JSON message to the client
func (c *Client) sendJSON(msg *Message) {
	data, err := json.Marshal(msg)
	if err != nil {
		log.Printf("Failed to marshal message: %v", err)
		return
	}

	select {
	case c.send <- data:
	default:
		// Buffer full
		log.Printf("Client send buffer full, user=%s", c.userID)
	}
}

// SendToUser sends a message to a specific user (used by external code)
func (h *Handler) SendToUser(userID string, msg *Message) {
	h.hub.BroadcastToUser(userID, msg)
}

// SendToChannel sends a message to a channel (used by external code)
func (h *Handler) SendToChannel(channelID string, msg *Message) {
	h.hub.BroadcastToChannel(channelID, msg)
}

// GetOnlineUsers returns list of online users
func (h *Handler) GetOnlineUsers() []string {
	return h.hub.GetOnlineUsers()
}

// IsUserOnline checks if a user is online
func (h *Handler) IsUserOnline(userID string) bool {
	return h.hub.IsUserOnline(userID)
}
