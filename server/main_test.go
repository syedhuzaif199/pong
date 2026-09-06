package main

import (
	"io"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"
)

func post(t *testing.T, client *http.Client, url, body string) string {
	t.Helper()
	resp, err := client.Post(url, "text/plain", strings.NewReader(body))
	if err != nil {
		t.Fatalf("POST %s: %v", url, err)
	}
	defer resp.Body.Close()
	data, err := io.ReadAll(resp.Body)
	if err != nil {
		t.Fatal(err)
	}
	return string(data)
}

func TestCreateJoinAndExchangeCandidates(t *testing.T) {
	s := &server{rooms: make(map[string]*room)}
	mux := http.NewServeMux()
	mux.HandleFunc("/v1/create", s.handleCreate)
	mux.HandleFunc("/v1/join", s.handleJoin)
	mux.HandleFunc("/v1/wait", s.handleWait)
	mux.HandleFunc("/v1/leave", s.handleLeave)
	ts := httptest.NewServer(mux)
	defer ts.Close()

	created := post(t, ts.Client(), ts.URL+"/v1/create", "RV_CREATE|1|4|101|Alice|203.0.113.10|50001|2001:db8::10|50001|192.168.1.10|50001")
	cp := strings.Split(created, "|")
	if len(cp) != 5 || cp[0] != "RV_CREATED" || len(cp[3]) != 6 {
		t.Fatalf("unexpected create response: %q", created)
	}
	code, hostToken := cp[3], cp[4]

	joined := post(t, ts.Client(), ts.URL+"/v1/join", "RV_JOIN|1|4|202|"+code+"|Bob|198.51.100.20|50002|2001:db8::20|50002|192.168.1.20|50002")
	jp := strings.Split(joined, "|")
	if len(jp) != 5 || jp[0] != "RV_JOINED" {
		t.Fatalf("unexpected join response: %q", joined)
	}
	joinToken := jp[4]

	hostPeer := post(t, ts.Client(), ts.URL+"/v1/wait", "RV_WAIT|1|"+code+"|"+hostToken)
	if !strings.Contains(hostPeer, "|198.51.100.20|50002|") || !strings.Contains(hostPeer, "|Bob|") {
		t.Fatalf("host did not receive Bob candidates: %q", hostPeer)
	}

	joinPeer := post(t, ts.Client(), ts.URL+"/v1/wait", "RV_WAIT|1|"+code+"|"+joinToken)
	if !strings.Contains(joinPeer, "|203.0.113.10|50001|") || !strings.Contains(joinPeer, "|Alice|") {
		t.Fatalf("joiner did not receive Alice candidates: %q", joinPeer)
	}

	hp := strings.Split(hostPeer, "|")
	bp := strings.Split(joinPeer, "|")
	if hp[len(hp)-1] != bp[len(bp)-1] {
		t.Fatalf("punch nonces differ: %q vs %q", hp[len(hp)-1], bp[len(bp)-1])
	}
}

func TestWaitingRoom(t *testing.T) {
	s := &server{rooms: make(map[string]*room)}
	mux := http.NewServeMux()
	mux.HandleFunc("/v1/create", s.handleCreate)
	mux.HandleFunc("/v1/wait", s.handleWait)
	ts := httptest.NewServer(mux)
	defer ts.Close()

	created := post(t, ts.Client(), ts.URL+"/v1/create", "RV_CREATE|1|4|303|Alice|-|0|-|0|192.168.1.10|50001")
	cp := strings.Split(created, "|")
	if len(cp) != 5 {
		t.Fatalf("unexpected create response: %q", created)
	}
	waiting := post(t, ts.Client(), ts.URL+"/v1/wait", "RV_WAIT|1|"+cp[3]+"|"+cp[4])
	if !strings.HasPrefix(waiting, "RV_WAITING|1|") {
		t.Fatalf("unexpected wait response: %q", waiting)
	}
}

func TestHealth(t *testing.T) {
	s := &server{rooms: make(map[string]*room)}
	req := httptest.NewRequest(http.MethodGet, "/healthz", nil)
	rr := httptest.NewRecorder()
	s.handleHealth(rr, req)
	if rr.Code != http.StatusOK || strings.TrimSpace(rr.Body.String()) != "ok" {
		t.Fatalf("unexpected health response: %d %q", rr.Code, rr.Body.String())
	}
}
