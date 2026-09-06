package main

import (
	"crypto/rand"
	"encoding/hex"
	"flag"
	"fmt"
	"io"
	"log"
	"net"
	"net/http"
	"os"
	"strconv"
	"strings"
	"sync"
	"time"
)

const (
	rendezvousVersion = 1
	waitingRoomTTL    = 2 * time.Minute
	joinedRoomTTL     = 30 * time.Second
	cleanupEvery      = 10 * time.Second
	maxRooms          = 4096
	maxBodyBytes      = 2048
)

var roomAlphabet = []byte("ABCDEFGHJKLMNPQRSTUVWXYZ23456789")

type candidateSet struct {
	publicIP   string
	publicPort int
	ipv6       string
	ipv6Port   int
	local4     string
	local4Port int
}

type peer struct {
	token      string
	name       string
	protocol   int
	candidates candidateSet
	nonce      string
}

type room struct {
	code       string
	host       peer
	join       *peer
	punchNonce uint32
	created    time.Time
	updated    time.Time
}

type server struct {
	mu    sync.Mutex
	rooms map[string]*room
}

func main() {
	listen := flag.String("listen", "", "HTTP listen address (default: 0.0.0.0:$PORT, or 0.0.0.0:10000 locally)")
	flag.Parse()

	addr := strings.TrimSpace(*listen)
	if addr == "" {
		port := strings.TrimSpace(os.Getenv("PORT"))
		if port == "" {
			port = "10000"
		}
		addr = "0.0.0.0:" + port
	}

	s := &server{rooms: make(map[string]*room)}
	go s.cleanupLoop()

	mux := http.NewServeMux()
	mux.HandleFunc("/healthz", s.handleHealth)
	mux.HandleFunc("/v1/create", s.handleCreate)
	mux.HandleFunc("/v1/join", s.handleJoin)
	mux.HandleFunc("/v1/wait", s.handleWait)
	mux.HandleFunc("/v1/leave", s.handleLeave)

	httpServer := &http.Server{
		Addr:              addr,
		Handler:           mux,
		ReadHeaderTimeout: 5 * time.Second,
		ReadTimeout:       5 * time.Second,
		WriteTimeout:      5 * time.Second,
		IdleTimeout:       30 * time.Second,
	}

	log.Printf("pong HTTP rendezvous listening on %s", addr)
	log.Fatal(httpServer.ListenAndServe())
}

func (s *server) handleHealth(w http.ResponseWriter, r *http.Request) {
	if r.Method != http.MethodGet {
		w.Header().Set("Allow", http.MethodGet)
		http.Error(w, "method not allowed", http.StatusMethodNotAllowed)
		return
	}
	w.Header().Set("Content-Type", "text/plain; charset=utf-8")
	w.WriteHeader(http.StatusOK)
	_, _ = io.WriteString(w, "ok")
}

func readRequestBody(w http.ResponseWriter, r *http.Request) (string, bool) {
	if r.Method != http.MethodPost {
		w.Header().Set("Allow", http.MethodPost)
		http.Error(w, "method not allowed", http.StatusMethodNotAllowed)
		return "", false
	}
	r.Body = http.MaxBytesReader(w, r.Body, maxBodyBytes)
	data, err := io.ReadAll(r.Body)
	if err != nil {
		http.Error(w, "bad request", http.StatusBadRequest)
		return "", false
	}
	text := strings.TrimSpace(string(data))
	if text == "" {
		http.Error(w, "empty request", http.StatusBadRequest)
		return "", false
	}
	return text, true
}

func writeProtocol(w http.ResponseWriter, text string) {
	w.Header().Set("Content-Type", "text/plain; charset=utf-8")
	w.Header().Set("Cache-Control", "no-store")
	w.WriteHeader(http.StatusOK)
	_, _ = io.WriteString(w, text)
}

func (s *server) handleCreate(w http.ResponseWriter, r *http.Request) {
	text, ok := readRequestBody(w, r)
	if !ok {
		return
	}
	p := strings.Split(text, "|")
	// RV_CREATE|1|game_protocol|request_nonce|name|public_ip|public_port|ipv6|ipv6_port|local4|local4_port
	if len(p) != 11 || p[0] != "RV_CREATE" || p[1] != strconv.Itoa(rendezvousVersion) {
		writeProtocol(w, rvError("0", "BAD_REQUEST"))
		return
	}

	protocol, err := strconv.Atoi(p[2])
	if err != nil {
		writeProtocol(w, rvError(p[3], "BAD_REQUEST"))
		return
	}
	nonce := cleanField(p[3], 32)
	name := cleanName(p[4])
	candidates, valid := parseCandidates(p[5:11])
	if nonce == "" || name == "" || !valid {
		writeProtocol(w, rvError(p[3], "BAD_REQUEST"))
		return
	}

	s.mu.Lock()
	defer s.mu.Unlock()

	for _, existing := range s.rooms {
		if existing.host.nonce == nonce && existing.host.protocol == protocol && existing.host.name == name {
			existing.updated = time.Now()
			writeProtocol(w, fmt.Sprintf("RV_CREATED|%d|%s|%s|%s", rendezvousVersion, nonce, existing.code, existing.host.token))
			return
		}
	}

	if len(s.rooms) >= maxRooms {
		writeProtocol(w, rvError(nonce, "SERVER_FULL"))
		return
	}

	code := s.newUniqueCodeLocked()
	if code == "" {
		writeProtocol(w, rvError(nonce, "SERVER_FULL"))
		return
	}
	token, err := randomToken()
	if err != nil {
		writeProtocol(w, rvError(nonce, "SERVER_ERROR"))
		return
	}

	now := time.Now()
	rm := &room{
		code: code,
		host: peer{
			token:      token,
			name:       name,
			protocol:   protocol,
			candidates: candidates,
			nonce:      nonce,
		},
		created: now,
		updated: now,
	}
	s.rooms[code] = rm
	writeProtocol(w, fmt.Sprintf("RV_CREATED|%d|%s|%s|%s", rendezvousVersion, nonce, code, token))
}

func (s *server) handleJoin(w http.ResponseWriter, r *http.Request) {
	text, ok := readRequestBody(w, r)
	if !ok {
		return
	}
	p := strings.Split(text, "|")
	// RV_JOIN|1|game_protocol|request_nonce|code|name|public_ip|public_port|ipv6|ipv6_port|local4|local4_port
	if len(p) != 12 || p[0] != "RV_JOIN" || p[1] != strconv.Itoa(rendezvousVersion) {
		writeProtocol(w, rvError("0", "BAD_REQUEST"))
		return
	}

	protocol, err := strconv.Atoi(p[2])
	if err != nil {
		writeProtocol(w, rvError(p[3], "BAD_REQUEST"))
		return
	}
	nonce := cleanField(p[3], 32)
	code := normalizeCode(p[4])
	name := cleanName(p[5])
	candidates, valid := parseCandidates(p[6:12])
	if nonce == "" || code == "" || name == "" || !valid {
		writeProtocol(w, rvError(p[3], "BAD_REQUEST"))
		return
	}

	s.mu.Lock()
	defer s.mu.Unlock()

	rm := s.rooms[code]
	if rm == nil {
		writeProtocol(w, rvError(nonce, "ROOM_NOT_FOUND"))
		return
	}
	if rm.host.protocol != protocol {
		writeProtocol(w, rvError(nonce, "PROTOCOL_MISMATCH"))
		return
	}

	if rm.join != nil {
		if rm.join.nonce == nonce && rm.join.name == name {
			rm.updated = time.Now()
			writeProtocol(w, fmt.Sprintf("RV_JOINED|%d|%s|%s|%s", rendezvousVersion, nonce, code, rm.join.token))
			return
		}
		writeProtocol(w, rvError(nonce, "ROOM_FULL"))
		return
	}

	token, err := randomToken()
	if err != nil {
		writeProtocol(w, rvError(nonce, "SERVER_ERROR"))
		return
	}
	punchNonce, err := randomUint32()
	if err != nil {
		writeProtocol(w, rvError(nonce, "SERVER_ERROR"))
		return
	}

	rm.join = &peer{
		token:      token,
		name:       name,
		protocol:   protocol,
		candidates: candidates,
		nonce:      nonce,
	}
	rm.punchNonce = punchNonce
	rm.updated = time.Now()
	writeProtocol(w, fmt.Sprintf("RV_JOINED|%d|%s|%s|%s", rendezvousVersion, nonce, code, token))
}

func (s *server) handleWait(w http.ResponseWriter, r *http.Request) {
	text, ok := readRequestBody(w, r)
	if !ok {
		return
	}
	p := strings.Split(text, "|")
	// RV_WAIT|1|code|token
	if len(p) != 4 || p[0] != "RV_WAIT" || p[1] != strconv.Itoa(rendezvousVersion) {
		writeProtocol(w, rvError("0", "BAD_REQUEST"))
		return
	}
	code := normalizeCode(p[2])
	token := cleanField(p[3], 64)

	s.mu.Lock()
	defer s.mu.Unlock()

	rm := s.rooms[code]
	if rm == nil {
		writeProtocol(w, rvError("0", "ROOM_NOT_FOUND"))
		return
	}

	var other *peer
	if token == rm.host.token {
		other = rm.join
	} else if rm.join != nil && token == rm.join.token {
		other = &rm.host
	} else {
		writeProtocol(w, rvError("0", "BAD_TOKEN"))
		return
	}

	rm.updated = time.Now()
	if other == nil {
		writeProtocol(w, fmt.Sprintf("RV_WAITING|%d|%s", rendezvousVersion, code))
		return
	}

	writeProtocol(w, peerResponse(rm, token, other))
}

func (s *server) handleLeave(w http.ResponseWriter, r *http.Request) {
	text, ok := readRequestBody(w, r)
	if !ok {
		return
	}
	p := strings.Split(text, "|")
	// RV_LEAVE|1|code|token
	if len(p) != 4 || p[0] != "RV_LEAVE" || p[1] != strconv.Itoa(rendezvousVersion) {
		writeProtocol(w, rvError("0", "BAD_REQUEST"))
		return
	}
	code := normalizeCode(p[2])
	token := cleanField(p[3], 64)

	s.mu.Lock()
	defer s.mu.Unlock()
	rm := s.rooms[code]
	if rm == nil {
		writeProtocol(w, "RV_LEFT|1")
		return
	}
	if token != rm.host.token && (rm.join == nil || token != rm.join.token) {
		writeProtocol(w, rvError("0", "BAD_TOKEN"))
		return
	}
	delete(s.rooms, code)
	writeProtocol(w, "RV_LEFT|1")
}

func peerResponse(rm *room, callerToken string, other *peer) string {
	c := other.candidates
	return fmt.Sprintf(
		"RV_PEER|%d|%s|%s|%s|%d|%s|%d|%s|%d|%s|%d",
		rendezvousVersion,
		rm.code,
		callerToken,
		candidateOrDash(c.publicIP), c.publicPort,
		candidateOrDash(c.ipv6), c.ipv6Port,
		candidateOrDash(c.local4), c.local4Port,
		other.name,
		rm.punchNonce,
	)
}

func parseCandidates(p []string) (candidateSet, bool) {
	if len(p) != 6 {
		return candidateSet{}, false
	}

	// Candidates are hints, not authentication or room metadata. A platform may
	// surface an unusable interface address (for example an IPv4-mapped IPv6
	// address on Windows). Drop an invalid optional candidate instead of rejecting
	// an otherwise valid CREATE/JOIN request. Hole punching can still use the
	// remaining candidates.
	publicIP, publicPort := normalizeCandidate(p[0], p[1], 0)
	ipv6, ipv6Port := normalizeCandidate(p[2], p[3], 6)
	local4, local4Port := normalizeCandidate(p[4], p[5], 4)

	return candidateSet{
		publicIP:   publicIP,
		publicPort: publicPort,
		ipv6:       ipv6,
		ipv6Port:   ipv6Port,
		local4:     local4,
		local4Port: local4Port,
	}, true
}

func normalizeCandidate(value, portText string, family int) (string, int) {
	port := parsePortAllowZero(portText)
	if port < 1 {
		return "", 0
	}
	ip := normalizeIP(value, family)
	if ip == "" {
		return "", 0
	}
	return ip, port
}

func normalizeIP(value string, family int) string {
	value = strings.TrimSpace(value)
	if value == "" || value == "-" {
		return ""
	}
	ip := net.ParseIP(value)
	if ip == nil {
		return ""
	}
	switch family {
	case 4:
		v4 := ip.To4()
		if v4 == nil {
			return ""
		}
		return v4.String()
	case 6:
		if ip.To4() != nil || ip.To16() == nil {
			return ""
		}
		return ip.String()
	default:
		return ip.String()
	}
}

func parsePortAllowZero(value string) int {
	n, err := strconv.Atoi(value)
	if err != nil || n < 0 || n > 65535 {
		return -1
	}
	return n
}

func cleanName(value string) string {
	value = strings.TrimSpace(value)
	if len(value) == 0 || len(value) > 24 || strings.ContainsAny(value, "|\r\n") {
		return ""
	}
	return value
}

func cleanField(value string, maxLen int) string {
	value = strings.TrimSpace(value)
	if value == "" || len(value) > maxLen || strings.ContainsAny(value, "|\r\n") {
		return ""
	}
	return value
}

func normalizeCode(value string) string {
	value = strings.ToUpper(strings.ReplaceAll(strings.ReplaceAll(strings.TrimSpace(value), "-", ""), " ", ""))
	if len(value) != 6 {
		return ""
	}
	for i := 0; i < len(value); i++ {
		if !strings.ContainsRune(string(roomAlphabet), rune(value[i])) {
			return ""
		}
	}
	return value
}

func candidateOrDash(value string) string {
	if value == "" {
		return "-"
	}
	return value
}

func rvError(nonce, reason string) string {
	if nonce == "" {
		nonce = "0"
	}
	return fmt.Sprintf("RV_ERROR|%d|%s|%s", rendezvousVersion, nonce, reason)
}

func (s *server) cleanupLoop() {
	ticker := time.NewTicker(cleanupEvery)
	defer ticker.Stop()
	for now := range ticker.C {
		s.mu.Lock()
		for code, rm := range s.rooms {
			ttl := waitingRoomTTL
			if rm.join != nil {
				ttl = joinedRoomTTL
			}
			if now.Sub(rm.updated) > ttl {
				delete(s.rooms, code)
			}
		}
		s.mu.Unlock()
	}
}

func (s *server) newUniqueCodeLocked() string {
	for attempt := 0; attempt < 32; attempt++ {
		raw := make([]byte, 6)
		if _, err := rand.Read(raw); err != nil {
			return ""
		}
		code := make([]byte, 6)
		for i := range code {
			code[i] = roomAlphabet[int(raw[i])%len(roomAlphabet)]
		}
		text := string(code)
		if s.rooms[text] == nil {
			return text
		}
	}
	return ""
}

func randomToken() (string, error) {
	raw := make([]byte, 16)
	if _, err := rand.Read(raw); err != nil {
		return "", err
	}
	return hex.EncodeToString(raw), nil
}

func randomUint32() (uint32, error) {
	raw := make([]byte, 4)
	if _, err := rand.Read(raw); err != nil {
		return 0, err
	}
	return uint32(raw[0])<<24 | uint32(raw[1])<<16 | uint32(raw[2])<<8 | uint32(raw[3]), nil
}
