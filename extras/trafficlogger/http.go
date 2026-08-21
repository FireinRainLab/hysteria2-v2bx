package trafficlogger

import (
	"bytes"
	"cmp"
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"log"
	"net/http"
	"slices"
	"strconv"
	"strings"
	"sync"
	"time"

	"github.com/apernet/hysteria/core/v2/server"
)

const (
	indexHTML = `<!DOCTYPE html><html lang="en"><head> <meta charset="UTF-8"> <meta name="viewport" content="width=device-width, initial-scale=1.0"> <title>Hysteria Traffic Stats API Server</title> <style>body{font-family: Arial, sans-serif; display: flex; justify-content: center; align-items: center; height: 100vh; margin: 0; padding: 0; background-color: #f4f4f4;}.container{padding: 20px; background-color: #fff; box-shadow: 0 4px 6px rgba(0, 0, 0, 0.1); border-radius: 5px;}</style></head><body> <div class="container"> <p>This is a Hysteria Traffic Stats API server.</p><p>Check the documentation for usage.</p></div></body></html>`
)

// TrafficStatsServer implements both server.TrafficLogger and http.Handler
// to provide a simple HTTP API to get the traffic stats per user.
type TrafficStatsServer interface {
	server.TrafficLogger
	http.Handler
}

func NewTrafficStatsServer(secret string) TrafficStatsServer {
	return &trafficStatsServerImpl{
		StatsMap:  make(map[string]*trafficStatsEntry),
		KickMap:   make(map[string]struct{}),
		OnlineMap: make(map[string]int),
		StreamMap: make(map[server.HyStream]*server.StreamStats),
		Secret:    secret,
	}
}

type trafficStatsServerImpl struct {
	Mutex     sync.RWMutex
	StatsMap  map[string]*trafficStatsEntry
	OnlineMap map[string]int
	StreamMap map[server.HyStream]*server.StreamStats
	KickMap   map[string]struct{}
	Secret    string
}

type trafficStatsEntry struct {
	Tx uint64 `json:"tx"`
	Rx uint64 `json:"rx"`
}

func (s *trafficStatsServerImpl) LogTraffic(id string, tx, rx uint64) (ok bool) {
	s.Mutex.Lock()
	defer s.Mutex.Unlock()

	_, ok = s.KickMap[id]
	if ok {
		delete(s.KickMap, id)
		return false
	}

	entry, ok := s.StatsMap[id]
	if !ok {
		entry = &trafficStatsEntry{}
		s.StatsMap[id] = entry
	}
	entry.Tx += tx
	entry.Rx += rx

	return true
}

// LogOnlineState updates the online state to the online map.
func (s *trafficStatsServerImpl) LogOnlineState(id string, online bool) {
	s.Mutex.Lock()
	defer s.Mutex.Unlock()

	if online {
		s.OnlineMap[id]++
	} else {
		s.OnlineMap[id]--
		if s.OnlineMap[id] <= 0 {
			delete(s.OnlineMap, id)
		}
	}
}

func (s *trafficStatsServerImpl) TraceStream(stream server.HyStream, stats *server.StreamStats) {
	s.Mutex.Lock()
	defer s.Mutex.Unlock()

	s.StreamMap[stream] = stats
}

func (s *trafficStatsServerImpl) UntraceStream(stream server.HyStream) {
	s.Mutex.Lock()
	defer s.Mutex.Unlock()

	delete(s.StreamMap, stream)
}

func (s *trafficStatsServerImpl) ServeHTTP(w http.ResponseWriter, r *http.Request) {
	if s.Secret != "" && r.Header.Get("Authorization") != s.Secret {
		http.Error(w, "unauthorized", http.StatusUnauthorized)
		return
	}
	if r.Method == http.MethodGet && r.URL.Path == "/" {
		_, _ = w.Write([]byte(indexHTML))
		return
	}
	if r.Method == http.MethodGet && r.URL.Path == "/traffic" {
		s.getTraffic(w, r)
		return
	}
	if r.Method == http.MethodPost && r.URL.Path == "/kick" {
		s.kick(w, r)
		return
	}
	if r.Method == http.MethodGet && r.URL.Path == "/online" {
		s.getOnline(w, r)
		return
	}
	if r.Method == http.MethodGet && r.URL.Path == "/dump/streams" {
		s.getDumpStreams(w, r)
		return
	}
	http.NotFound(w, r)
}

func (s *trafficStatsServerImpl) getTraffic(w http.ResponseWriter, r *http.Request) {
	bClear, _ := strconv.ParseBool(r.URL.Query().Get("clear"))
	var jb []byte
	var err error
	if bClear {
		s.Mutex.Lock()
		jb, err = json.Marshal(s.StatsMap)
		s.StatsMap = make(map[string]*trafficStatsEntry)
		s.Mutex.Unlock()
	} else {
		s.Mutex.RLock()
		jb, err = json.Marshal(s.StatsMap)
		s.Mutex.RUnlock()
	}
	if err != nil {
		http.Error(w, err.Error(), http.StatusInternalServerError)
		return
	}
	w.Header().Set("Content-Type", "application/json; charset=utf-8")
	_, _ = w.Write(jb)
}

func (s *trafficStatsServerImpl) getOnline(w http.ResponseWriter, r *http.Request) {
	s.Mutex.RLock()
	defer s.Mutex.RUnlock()

	jb, err := json.Marshal(s.OnlineMap)
	if err != nil {
		http.Error(w, err.Error(), http.StatusInternalServerError)
		return
	}
	w.Header().Set("Content-Type", "application/json; charset=utf-8")
	_, _ = w.Write(jb)
}

type dumpStreamEntry struct {
	State string `json:"state"`

	Auth       string `json:"auth"`
	Connection uint32 `json:"connection"`
	Stream     uint64 `json:"stream"`

	ReqAddr       string `json:"req_addr"`
	HookedReqAddr string `json:"hooked_req_addr"`

	Tx uint64 `json:"tx"`
	Rx uint64 `json:"rx"`

	InitialAt    string `json:"initial_at"`
	LastActiveAt string `json:"last_active_at"`

	// for text/plain output
	initialTime    time.Time
	lastActiveTime time.Time
}

func (e *dumpStreamEntry) fromStreamStats(stream server.HyStream, s *server.StreamStats) {
	e.State = s.State.Load().String()
	e.Auth = s.AuthID
	e.Connection = s.ConnID
	e.Stream = uint64(stream.StreamID())
	e.ReqAddr = s.ReqAddr.Load()
	e.HookedReqAddr = s.HookedReqAddr.Load()
	e.Tx = s.Tx.Load()
	e.Rx = s.Rx.Load()
	e.initialTime = s.InitialTime
	e.lastActiveTime = s.LastActiveTime.Load()
	e.InitialAt = e.initialTime.Format(time.RFC3339Nano)
	e.LastActiveAt = e.lastActiveTime.Format(time.RFC3339Nano)
}

func formatDumpStreamLine(state, auth, connection, stream, reqAddr, hookedReqAddr, tx, rx, lifetime, lastActive string) string {
	return fmt.Sprintf("%-8s %-12s %12s %8s %12s %12s %12s %12s %-16s %s", state, auth, connection, stream, tx, rx, lifetime, lastActive, reqAddr, hookedReqAddr)
}

func (e *dumpStreamEntry) String() string {
	stateText := strings.ToUpper(e.State)
	connectionText := fmt.Sprintf("%08X", e.Connection)
	streamText := strconv.FormatUint(e.Stream, 10)
	reqAddrText := e.ReqAddr
	if reqAddrText == "" {
		reqAddrText = "-"
	}
	hookedReqAddrText := e.HookedReqAddr
	if hookedReqAddrText == "" {
		hookedReqAddrText = "-"
	}
	txText := strconv.FormatUint(e.Tx, 10)
	rxText := strconv.FormatUint(e.Rx, 10)
	lifetime := time.Since(e.initialTime)
	if lifetime < 10*time.Minute {
		lifetime = lifetime.Round(time.Millisecond)
	} else {
		lifetime = lifetime.Round(time.Second)
	}
	lastActive := time.Since(e.lastActiveTime)
	if lastActive < 10*time.Minute {
		lastActive = lastActive.Round(time.Millisecond)
	} else {
		lastActive = lastActive.Round(time.Second)
	}

	return formatDumpStreamLine(stateText, e.Auth, connectionText, streamText, reqAddrText, hookedReqAddrText, txText, rxText, lifetime.String(), lastActive.String())
}

func (s *trafficStatsServerImpl) getDumpStreams(w http.ResponseWriter, r *http.Request) {
	var entries []dumpStreamEntry

	s.Mutex.RLock()
	entries = make([]dumpStreamEntry, len(s.StreamMap))
	index := 0
	for stream, stats := range s.StreamMap {
		entries[index].fromStreamStats(stream, stats)
		index++
	}
	s.Mutex.RUnlock()

	slices.SortFunc(entries, func(lhs, rhs dumpStreamEntry) int {
		if ret := cmp.Compare(lhs.Auth, rhs.Auth); ret != 0 {
			return ret
		}
		if ret := cmp.Compare(lhs.Connection, rhs.Connection); ret != 0 {
			return ret
		}
		if ret := cmp.Compare(lhs.Stream, rhs.Stream); ret != 0 {
			return ret
		}
		return 0
	})

	accept := r.Header.Get("Accept")

	if strings.Contains(accept, "text/plain") {
		// Generate netstat-like output for humans
		w.Header().Set("Content-Type", "text/plain; charset=utf-8")

		// Print table header
		_, _ = fmt.Fprintln(w, formatDumpStreamLine("State", "Auth", "Connection", "Stream", "Req-Addr", "Hooked-Req-Addr", "TX-Bytes", "RX-Bytes", "Lifetime", "Last-Active"))
		for _, entry := range entries {
			_, _ = fmt.Fprintln(w, entry.String())
		}
		return
	}

	// Response with json by default
	wrapper := struct {
		Streams []dumpStreamEntry `json:"streams"`
	}{entries}
	w.Header().Set("Content-Type", "application/json; charset=utf-8")
	err := json.NewEncoder(w).Encode(&wrapper)
	if err != nil {
		http.Error(w, err.Error(), http.StatusInternalServerError)
	}
}

func (s *trafficStatsServerImpl) kick(w http.ResponseWriter, r *http.Request) {
	var ids []string
	err := json.NewDecoder(r.Body).Decode(&ids)
	if err != nil {
		http.Error(w, err.Error(), http.StatusBadRequest)
		return
	}
	s.Mutex.Lock()
	for _, id := range ids {
		s.KickMap[id] = struct{}{}
	}
	s.Mutex.Unlock()

	w.WriteHeader(http.StatusOK)
}

// NewKick marks a user id so that the next LogTraffic call for that
// id will return false, causing the server to disconnect the client.
// This satisfies auth.V2boardKicker so the auth package can request
// kicks when a user is removed from the v2board panel.
func (s *trafficStatsServerImpl) NewKick(id string) bool {
	s.Mutex.Lock()
	defer s.Mutex.Unlock()
	s.KickMap[id] = struct{}{}
	return true
}

// PushTrafficToV2board posts the current traffic statistics to the
// v2board push endpoint and clears the in-memory stats map on
// success so the next push interval starts from a clean slate.
// It returns the number of users pushed so callers can log it.
func (s *trafficStatsServerImpl) PushTrafficToV2board(url string) (int, error) {
	s.Mutex.Lock()

	payload := make(map[string][2]int64, len(s.StatsMap))
	for id, stats := range s.StatsMap {
		payload[id] = [2]int64{int64(stats.Tx), int64(stats.Rx)}
	}
	if len(payload) == 0 {
		s.Mutex.Unlock()
		return 0, nil
	}
	body, err := json.Marshal(payload)
	if err != nil {
		s.Mutex.Unlock()
		return 0, err
	}
	s.StatsMap = make(map[string]*trafficStatsEntry)
	s.Mutex.Unlock()

	ctx, cancel := context.WithTimeout(context.Background(), 15*time.Second)
	defer cancel()
	req, err := http.NewRequestWithContext(ctx, http.MethodPost, url, bytes.NewBuffer(body))
	if err != nil {
		return 0, err
	}
	req.Header.Set("Content-Type", "application/json")
	client := &http.Client{Timeout: 15 * time.Second}
	resp, err := client.Do(req)
	if err != nil {
		return 0, err
	}
	defer resp.Body.Close()
	if resp.StatusCode != http.StatusOK {
		return 0, errors.New("push failed with status " + resp.Status)
	}
	return len(payload), nil
}

// PushTrafficToV2boardInterval starts a background loop that invokes
// PushTrafficToV2board at the specified interval. The returned stop
// function terminates the loop.
func (s *trafficStatsServerImpl) PushTrafficToV2boardInterval(url string, interval time.Duration) (stop func()) {
	log.Printf("[v2board] traffic push started, interval=%s", interval)
	ctx, cancel := context.WithCancel(context.Background())
	go func() {
		ticker := time.NewTicker(interval)
		defer ticker.Stop()
		for {
			select {
			case <-ctx.Done():
				return
			case <-ticker.C:
				n, err := s.PushTrafficToV2board(url)
				if err != nil {
					log.Printf("[v2board] traffic push failed: %v", err)
				} else {
					log.Printf("[v2board] traffic push succeeded, users=%d", n)
				}
			}
		}
	}()
	return cancel
}
