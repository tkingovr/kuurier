package websocket

import (
	"context"
	"encoding/json"
	"log"
	"sync"
	"time"

	"github.com/kuurier/server/internal/storage"
)

// Hub maintains the set of active clients and broadcasts messages
type Hub struct {
	// Registered clients by user ID
	clients map[string]map[*Client]bool

	// Clients by channel subscription
	channelClients map[string]map[*Client]bool

	// Register requests from clients
	register chan *Client

	// Unregister requests from clients
	unregister chan *Client

	// Inbound messages from clients
	broadcast chan *Message

	// Mutex for thread-safe access
	mu sync.RWMutex

	// Redis for pub/sub across multiple server instances
	redis *storage.Redis

	// Context for shutdown
	ctx    context.Context
	cancel context.CancelFunc
}

// Message represents a WebSocket message
type Message struct {
	Type      string          `json:"type"`
	ChannelID string          `json:"channel_id,omitempty"`
	UserID    string          `json:"user_id,omitempty"`
	Payload   json.RawMessage `json:"payload,omitempty"`
	Timestamp time.Time       `json:"timestamp"`
}

// Message types
const (
	// Client -> Server
	TypeMessageSend   = "message.send"
	TypeMessageRead   = "message.read"
	TypeTypingStart   = "typing.start"
	TypeTypingStop    = "typing.stop"
	TypePresenceUpdate = "presence.update"
	TypeSubscribe     = "subscribe"
	TypeUnsubscribe   = "unsubscribe"

	// Server -> Client
	TypeMessageNew     = "message.new"
	TypeMessageEdited  = "message.edited"
	TypeMessageDeleted = "message.deleted"
	TypeTypingUpdate   = "typing.update"
	TypeChannelUpdated = "channel.updated"
	TypePresenceOnline = "presence.online"
	TypePresenceOffline = "presence.offline"
	TypeError          = "error"
	TypePong           = "pong"
)

// NewHub creates a new Hub
func NewHub(redis *storage.Redis) *Hub {
	ctx, cancel := context.WithCancel(context.Background())
	return &Hub{
		clients:        make(map[string]map[*Client]bool),
		channelClients: make(map[string]map[*Client]bool),
		register:       make(chan *Client),
		unregister:     make(chan *Client),
		broadcast:      make(chan *Message, 256),
		redis:          redis,
		ctx:            ctx,
		cancel:         cancel,
	}
}

// Run starts the hub's main loop
func (h *Hub) Run() {
	// Start Redis subscriber for cross-instance messaging
	go h.subscribeRedis()

	for {
		select {
		case <-h.ctx.Done():
			return

		case client := <-h.register:
			h.registerClient(client)

		case client := <-h.unregister:
			h.unregisterClient(client)

		case message := <-h.broadcast:
			h.broadcastMessage(message)
		}
	}
}

// Stop gracefully shuts down the hub
func (h *Hub) Stop() {
	h.cancel()
}

// registerClient adds a new client to the hub
func (h *Hub) registerClient(client *Client) {
	h.mu.Lock()
	defer h.mu.Unlock()

	if _, ok := h.clients[client.userID]; !ok {
		h.clients[client.userID] = make(map[*Client]bool)
	}
	h.clients[client.userID][client] = true

	log.Printf("Client registered: user=%s, total connections=%d", client.userID, len(h.clients[client.userID]))

	// Broadcast presence online
	h.publishPresence(client.userID, true)
}

// unregisterClient removes a client from the hub
func (h *Hub) unregisterClient(client *Client) {
	h.mu.Lock()
	defer h.mu.Unlock()

	// Remove from user clients
	if clients, ok := h.clients[client.userID]; ok {
		if _, ok := clients[client]; ok {
			delete(clients, client)
			close(client.send)

			// If no more connections for this user, broadcast offline
			if len(clients) == 0 {
				delete(h.clients, client.userID)
				h.publishPresence(client.userID, false)
			}
		}
	}

	// Remove from channel subscriptions
	for channelID, clients := range h.channelClients {
		if _, ok := clients[client]; ok {
			delete(clients, client)
			if len(clients) == 0 {
				delete(h.channelClients, channelID)
			}
		}
	}

	log.Printf("Client unregistered: user=%s", client.userID)
}

// SubscribeToChannel subscribes a client to a channel
func (h *Hub) SubscribeToChannel(client *Client, channelID string) {
	h.mu.Lock()
	defer h.mu.Unlock()

	if _, ok := h.channelClients[channelID]; !ok {
		h.channelClients[channelID] = make(map[*Client]bool)
	}
	h.channelClients[channelID][client] = true
	client.channels[channelID] = true

	log.Printf("Client subscribed to channel: user=%s, channel=%s", client.userID, channelID)
}

// UnsubscribeFromChannel unsubscribes a client from a channel
func (h *Hub) UnsubscribeFromChannel(client *Client, channelID string) {
	h.mu.Lock()
	defer h.mu.Unlock()

	if clients, ok := h.channelClients[channelID]; ok {
		delete(clients, client)
		if len(clients) == 0 {
			delete(h.channelClients, channelID)
		}
	}
	delete(client.channels, channelID)

	log.Printf("Client unsubscribed from channel: user=%s, channel=%s", client.userID, channelID)
}

// BroadcastToChannel sends a message to all clients subscribed to a channel
func (h *Hub) BroadcastToChannel(channelID string, message *Message) {
	h.mu.RLock()
	clients := h.channelClients[channelID]
	h.mu.RUnlock()

	data, err := json.Marshal(message)
	if err != nil {
		log.Printf("Failed to marshal message: %v", err)
		return
	}

	for client := range clients {
		select {
		case client.send <- data:
		default:
			// Client buffer full, close connection
			h.unregister <- client
		}
	}

	// Publish to Redis for other server instances
	h.publishToRedis(channelID, message)
}

// BroadcastToUser sends a message to all connections of a specific user
func (h *Hub) BroadcastToUser(userID string, message *Message) {
	h.mu.RLock()
	clients := h.clients[userID]
	h.mu.RUnlock()

	data, err := json.Marshal(message)
	if err != nil {
		log.Printf("Failed to marshal message: %v", err)
		return
	}

	for client := range clients {
		select {
		case client.send <- data:
		default:
			h.unregister <- client
		}
	}
}

// broadcastMessage handles incoming broadcast requests
func (h *Hub) broadcastMessage(message *Message) {
	if message.ChannelID != "" {
		h.BroadcastToChannel(message.ChannelID, message)
	}
}

// publishPresence publishes a presence update
func (h *Hub) publishPresence(userID string, online bool) {
	msgType := TypePresenceOffline
	if online {
		msgType = TypePresenceOnline
	}

	message := &Message{
		Type:      msgType,
		UserID:    userID,
		Timestamp: time.Now().UTC(),
	}

	// Broadcast to all connected clients (they can filter by who they care about)
	h.mu.RLock()
	for _, clients := range h.clients {
		data, _ := json.Marshal(message)
		for client := range clients {
			select {
			case client.send <- data:
			default:
			}
		}
	}
	h.mu.RUnlock()

	// Also publish to Redis
	h.publishToRedis("presence", message)
}

// publishToRedis publishes a message to Redis pub/sub
func (h *Hub) publishToRedis(channel string, message *Message) {
	if h.redis == nil {
		return
	}

	data, err := json.Marshal(message)
	if err != nil {
		return
	}

	ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer cancel()

	if err := h.redis.Publish(ctx, "ws:"+channel, data); err != nil {
		log.Printf("Failed to publish to Redis: %v", err)
	}
}

// subscribeRedis subscribes to Redis pub/sub for cross-instance messaging
func (h *Hub) subscribeRedis() {
	if h.redis == nil {
		return
	}

	// Subscribe to a pattern for all channels
	pubsub := h.redis.PSubscribe(h.ctx, "ws:*")
	defer pubsub.Close()

	ch := pubsub.Channel()
	for {
		select {
		case <-h.ctx.Done():
			return
		case msg := <-ch:
			if msg == nil {
				continue
			}

			var message Message
			if err := json.Unmarshal([]byte(msg.Payload), &message); err != nil {
				continue
			}

			// Extract channel ID from Redis channel name (ws:channel_id)
			channelID := msg.Channel[3:] // Remove "ws:" prefix

			if channelID == "presence" {
				// Broadcast presence to all local clients
				h.mu.RLock()
				data := []byte(msg.Payload)
				for _, clients := range h.clients {
					for client := range clients {
						select {
						case client.send <- data:
						default:
						}
					}
				}
				h.mu.RUnlock()
			} else {
				// Broadcast to channel subscribers
				h.mu.RLock()
				clients := h.channelClients[channelID]
				data := []byte(msg.Payload)
				for client := range clients {
					select {
					case client.send <- data:
					default:
					}
				}
				h.mu.RUnlock()
			}
		}
	}
}

// GetOnlineUsers returns a list of online user IDs
func (h *Hub) GetOnlineUsers() []string {
	h.mu.RLock()
	defer h.mu.RUnlock()

	users := make([]string, 0, len(h.clients))
	for userID := range h.clients {
		users = append(users, userID)
	}
	return users
}

// IsUserOnline checks if a user has any active connections
func (h *Hub) IsUserOnline(userID string) bool {
	h.mu.RLock()
	defer h.mu.RUnlock()
	_, ok := h.clients[userID]
	return ok
}

// GetChannelMembers returns online users in a channel
func (h *Hub) GetChannelMembers(channelID string) []string {
	h.mu.RLock()
	defer h.mu.RUnlock()

	seen := make(map[string]bool)
	var users []string

	if clients, ok := h.channelClients[channelID]; ok {
		for client := range clients {
			if !seen[client.userID] {
				seen[client.userID] = true
				users = append(users, client.userID)
			}
		}
	}
	return users
}
