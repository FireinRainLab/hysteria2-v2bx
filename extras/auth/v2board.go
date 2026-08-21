package auth

import (
	"context"
	"encoding/json"
	"fmt"
	"log"
	"net"
	"net/http"
	"strconv"
	"sync"
	"time"

	"github.com/apernet/hysteria/core/v2/server"
)

// V2boardKicker is implemented by TrafficLogger to forcefully disconnect
// a user (e.g. when they are removed from the v2board user list).
// Keeping the interface in the auth package (instead of trafficlogger)
// avoids a circular dependency and lets the two packages agree on a
// single contract.
type V2boardKicker interface {
	NewKick(id string) bool
}

// V2boardApiProvider implements server.Authenticator by looking up
// credentials from a local cache that is periodically refreshed from a
// v2board-compatible HTTP API.
var _ server.Authenticator = &V2boardApiProvider{}

// User mirrors the subset of v2board's user payload that we care about.
type User struct {
	ID         int     `json:"id"`
	UUID       string  `json:"uuid"`
	SpeedLimit *uint32 `json:"speed_limit"`
}

type responseData struct {
	Users []User `json:"users"`
}

// Logger is the minimal logging surface used by this package.
// It is intentionally tiny so callers can plug in any logger they
// want (zap, slog, log, ...) without pulling a heavy dependency into
// the widely-used "extras" module.
type Logger interface {
	Infof(format string, args ...any)
	Warnf(format string, args ...any)
}

// stdLogger adapts *log.Logger to the Logger interface.
type stdLogger struct{ l *log.Logger }

func (stdLogger) Infof(format string, args ...any) {} // kept silent by default
func (s stdLogger) Warnf(format string, args ...any) {
	s.l.Printf("[v2board] "+format, args...)
}

type nopLogger struct{}

func (nopLogger) Infof(string, ...any) {}
func (nopLogger) Warnf(string, ...any) {}

// V2boardApiProvider holds the state for a v2board-backed authenticator.
// A single instance is normally enough for the whole process; for tests
// or advanced usages multiple instances can coexist safely because the
// cache is instance-scoped (not a package-level variable).
type V2boardApiProvider struct {
	Client *http.Client
	URL    string

	logger Logger

	mu    sync.RWMutex
	cache map[string]User
}

// NewV2boardApiProvider constructs a provider with sensible defaults.
// If logger is nil only warnings are forwarded to the standard
// library logger (so production errors still show up); tests typically
// pass a nopLogger.
func NewV2boardApiProvider(url string, logger Logger) *V2boardApiProvider {
	if logger == nil {
		logger = stdLogger{l: log.Default()}
	}
	return &V2boardApiProvider{
		Client: &http.Client{Timeout: 15 * time.Second},
		URL:    url,
		logger: logger,
		cache:  make(map[string]User),
	}
}

func fetchUserList(url string, client *http.Client) ([]User, error) {
	if client == nil {
		client = &http.Client{Timeout: 15 * time.Second}
	}
	ctx, cancel := context.WithTimeout(context.Background(), client.Timeout)
	defer cancel()
	req, err := http.NewRequestWithContext(ctx, http.MethodGet, url, nil)
	if err != nil {
		return nil, err
	}
	resp, err := client.Do(req)
	if err != nil {
		return nil, err
	}
	defer resp.Body.Close()

	if resp.StatusCode != http.StatusOK {
		return nil, fmt.Errorf("unexpected status code %d", resp.StatusCode)
	}

	var rd responseData
	if err := json.NewDecoder(resp.Body).Decode(&rd); err != nil {
		return nil, err
	}
	return rd.Users, nil
}

// UpdateUsers starts a background goroutine that refreshes the user
// list from the given URL at the specified interval. If kicker is
// non-nil, any user that disappears from the upstream list will be
// kicked via KickMap so that connected clients are disconnected.
// It returns a stop function that cancels the refresh loop.
func (v *V2boardApiProvider) UpdateUsers(interval time.Duration, kicker V2boardKicker) (stop func()) {
	v.logger.Infof("v2board user list auto-update started, interval=%s", interval)

	if userList, err := fetchUserList(v.URL, v.Client); err != nil {
		v.logger.Warnf("initial user list fetch failed: %v", err)
	} else {
		v.applyUserList(userList, kicker)
	}

	ctx, cancel := context.WithCancel(context.Background())
	go func() {
		ticker := time.NewTicker(interval)
		defer ticker.Stop()
		for {
			select {
			case <-ctx.Done():
				return
			case <-ticker.C:
				ul, err := fetchUserList(v.URL, v.Client)
				if err != nil {
					v.logger.Warnf("user list fetch failed: %v", err)
					continue
				}
				v.applyUserList(ul, kicker)
			}
		}
	}()

	return cancel
}

func (v *V2boardApiProvider) applyUserList(userList []User, kicker V2boardKicker) {
	newMap := make(map[string]User, len(userList))
	for _, u := range userList {
		newMap[u.UUID] = u
	}

	v.mu.Lock()
	defer v.mu.Unlock()

	if kicker != nil {
		for uuid, old := range v.cache {
			if _, exists := newMap[uuid]; !exists {
				kicker.NewKick(strconv.Itoa(old.ID))
			}
		}
	}
	v.cache = newMap
}

// Authenticate implements server.Authenticator.
func (v *V2boardApiProvider) Authenticate(addr net.Addr, auth string, tx uint64) (ok bool, id string) {
	v.mu.RLock()
	defer v.mu.RUnlock()

	if user, exists := v.cache[auth]; exists {
		return true, strconv.Itoa(user.ID)
	}
	return false, ""
}

// SetClient overrides the HTTP client used for API calls. Primarily
// useful in tests to inject a httptest.Server.
func (v *V2boardApiProvider) SetClient(c *http.Client) {
	v.Client = c
}
