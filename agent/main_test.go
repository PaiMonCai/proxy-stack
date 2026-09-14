package main

import (
	"context"
	"encoding/json"
	"errors"
	"io"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"reflect"
	"strings"
	"sync"
	"testing"
)

const agentToken = "agent-token-0123456789abcdef0123456789abcdef"

// call is one psm invocation seen by the fake runner.
type call struct {
	args  []string
	stdin string
}

type fakeRunner struct {
	mu     sync.Mutex
	calls  []call
	stdout map[string]string // by the psm subcommand ("add", "export", …)
	fail   map[string]string // subcommand → stderr of a failure
}

func (f *fakeRunner) run(_ context.Context, stdin []byte, args ...string) ([]byte, []byte, error) {
	f.mu.Lock()
	defer f.mu.Unlock()
	f.calls = append(f.calls, call{args, string(stdin)})
	sub := ""
	if len(args) > 1 {
		sub = args[1]
	}
	if msg, ok := f.fail[sub]; ok {
		return nil, []byte(msg), errors.New("exit status 1")
	}
	return []byte(f.stdout[sub]), nil, nil
}

// fakePanel serves /api/agent/sync: the queued tasks once, and records every
// request's body.
type fakePanel struct {
	mu       sync.Mutex
	tasks    []task
	requests []map[string]json.RawMessage
	failNext int // answer this many syncs with 500
}

func (p *fakePanel) handler(t *testing.T) http.Handler {
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		p.mu.Lock()
		defer p.mu.Unlock()
		switch r.URL.Path {
		case "/api/agent/join":
			var body map[string]string
			_ = json.NewDecoder(r.Body).Decode(&body)
			if body["join_token"] != "join-ok" {
				w.WriteHeader(http.StatusForbidden)
				_, _ = io.WriteString(w, `{"error":{"message":"invalid or expired join token"}}`)
				return
			}
			_, _ = io.WriteString(w, `{"agent_token":"`+agentToken+`","server":{"id":1,"name":"hk1"}}`)
		case "/api/agent/sync":
			if r.Header.Get("Authorization") != "Bearer "+agentToken {
				w.WriteHeader(http.StatusUnauthorized)
				return
			}
			if p.failNext > 0 {
				p.failNext--
				w.WriteHeader(http.StatusInternalServerError)
				return
			}
			var body map[string]json.RawMessage
			_ = json.NewDecoder(r.Body).Decode(&body)
			p.requests = append(p.requests, body)
			resp, _ := json.Marshal(map[string]any{"interval": 10, "tasks": p.tasks})
			p.tasks = nil
			_, _ = w.Write(resp)
		default:
			w.WriteHeader(http.StatusNotFound)
		}
	})
}

func newTestAgent(t *testing.T, p *fakePanel, f *fakeRunner) (*agent, func()) {
	srv := httptest.NewServer(p.handler(t))
	return &agent{cfg: &config{Panel: srv.URL, Token: agentToken, AllowHTTP: true}, run: f.run, hostname: "hk1"}, srv.Close
}

func results(t *testing.T, raw json.RawMessage) []result {
	t.Helper()
	var rs []result
	if err := json.Unmarshal(raw, &rs); err != nil {
		t.Fatalf("results: %v (%s)", err, raw)
	}
	return rs
}

func TestJoinWritesConfig(t *testing.T) {
	p := &fakePanel{}
	srv := httptest.NewServer(p.handler(t))
	defer srv.Close()
	path := filepath.Join(t.TempDir(), "etc", "agent.json")

	if err := join(context.Background(), path, srv.URL, "join-wrong", true); err == nil || !strings.Contains(err.Error(), "403") {
		t.Fatalf("a wrong join token: err=%v, want a 403", err)
	}
	if _, err := os.Stat(path); err == nil {
		t.Fatal("a failed join wrote a config")
	}
	if err := join(context.Background(), path, srv.URL, "join-ok", true); err != nil {
		t.Fatal(err)
	}
	st, err := os.Stat(path)
	if err != nil || st.Mode().Perm() != 0o600 {
		t.Fatalf("config: %v, mode %v, want 0600", err, st.Mode().Perm())
	}
	cfg, err := loadConfig(path)
	if err != nil || cfg.Token != agentToken || cfg.Panel != srv.URL {
		t.Fatalf("config read back: %+v %v", cfg, err)
	}
}

func TestPanelMustBeHTTPS(t *testing.T) {
	for raw, ok := range map[string]bool{
		"https://psm.example.com": true, "https://psm.example.com/": true,
		"http://psm.example.com": false, "psm.example.com": false, "https://psm.example.com/?a=1": false, "ftp://x": false,
	} {
		if _, err := checkPanelURL(raw, false); (err == nil) != ok {
			t.Errorf("%s: err=%v, want ok=%v", raw, err, ok)
		}
	}
}

func TestSyncRunsTasksAndReportsResults(t *testing.T) {
	p := &fakePanel{tasks: []task{
		{ID: 1, Kind: "node.add", Core: "xray", Protocol: "reality", Data: json.RawMessage(`{"tag":"hk","port":443,"server_name":"a.example"}`), Server: "203.0.113.10", Format: "uri"},
		{ID: 2, Kind: "node.delete", Core: "sing-box", Protocol: "tuic", Tag: "old"},
	}}
	f := &fakeRunner{stdout: map[string]string{"add": `{"status":"created"}`, "export": "vless://x@203.0.113.10:443#PSM-hk\n", "delete": `{"status":"deleted"}`}}
	a, done := newTestAgent(t, p, f)
	defer done()

	if wait, err := a.step(context.Background()); err != nil || wait != 0 {
		t.Fatalf("first sync: wait=%v err=%v (with results pending it reports at once)", wait, err)
	}
	want := []call{
		{[]string{"node", "add", "xray", "reality", "--input", "-", "--json"}, `{"tag":"hk","port":443,"server_name":"a.example"}`},
		{[]string{"node", "export", "xray", "reality", "hk", "--format", "uri", "--server", "203.0.113.10"}, ""},
		{[]string{"node", "delete", "sing-box", "tuic", "old", "--yes", "--if-exists", "--json"}, ""},
	}
	if !reflect.DeepEqual(f.calls, want) {
		t.Fatalf("psm calls\n got %q\nwant %q", f.calls, want)
	}
	if wait, err := a.step(context.Background()); err != nil || wait.Seconds() != 10 {
		t.Fatalf("second sync: wait=%v err=%v", wait, err)
	}
	rs := results(t, p.requests[1]["results"])
	if len(rs) != 2 || !rs[0].OK || rs[0].Link != "vless://x@203.0.113.10:443#PSM-hk" || !rs[1].OK {
		t.Fatalf("results delivered: %+v", rs)
	}
	if len(results(t, p.requests[0]["results"])) != 0 {
		t.Error("the first sync carried results before any task ran")
	}
}

func TestBadTasksNeverReachPSM(t *testing.T) {
	p := &fakePanel{tasks: []task{
		{ID: 1, Kind: "node.add", Core: "v2ray", Protocol: "reality", Data: json.RawMessage(`{"tag":"a","port":1}`)},
		{ID: 2, Kind: "node.add", Core: "xray", Protocol: "naive", Data: json.RawMessage(`{"tag":"a","port":1}`)},
		{ID: 3, Kind: "node.add", Core: "xray", Protocol: "reality", Data: json.RawMessage(`{"tag":"--show-secrets","port":1}`)},
		{ID: 4, Kind: "node.add", Core: "xray", Protocol: "reality", Data: json.RawMessage(`{"tag":"a","port":70000}`)},
		{ID: 5, Kind: "node.add", Core: "xray", Protocol: "reality", Data: json.RawMessage(`[1,2]`)},
		{ID: 6, Kind: "node.delete", Core: "xray", Protocol: "reality", Tag: "--yes"},
		{ID: 7, Kind: "node.update", Core: "xray", Protocol: "reality", Tag: "a", Data: json.RawMessage(`"x"`)},
		{ID: 8, Kind: "node.export", Core: "xray", Protocol: "reality", Tag: "a", Server: "$(id)"},
		{ID: 9, Kind: "shell", Core: "xray", Protocol: "reality"},
	}}
	f := &fakeRunner{}
	a, done := newTestAgent(t, p, f)
	defer done()
	if _, err := a.step(context.Background()); err != nil {
		t.Fatal(err)
	}
	if len(f.calls) != 0 {
		t.Fatalf("psm ran for a bad task: %q", f.calls)
	}
	if _, err := a.step(context.Background()); err != nil {
		t.Fatal(err)
	}
	rs := results(t, p.requests[1]["results"])
	if len(rs) != 9 {
		t.Fatalf("%d results, want 9", len(rs))
	}
	for _, r := range rs {
		if r.OK || !strings.HasPrefix(r.Error, "rejected by psm-agent") {
			t.Errorf("task %d: %+v, want a rejection", r.TaskID, r)
		}
	}
}

func TestPSMFailureIsReported(t *testing.T) {
	p := &fakePanel{tasks: []task{{ID: 7, Kind: "node.add", Core: "xray", Protocol: "tuic", Data: json.RawMessage(`{"tag":"t","port":9443}`)}}}
	f := &fakeRunner{fail: map[string]string{"add": "loading…\npsm node: unsupported core/protocol: xray/tuic\n"}}
	a, done := newTestAgent(t, p, f)
	defer done()
	_, _ = a.step(context.Background())
	_, _ = a.step(context.Background())
	rs := results(t, p.requests[1]["results"])
	if len(rs) != 1 || rs[0].OK || rs[0].Error != "psm node: unsupported core/protocol: xray/tuic" {
		t.Fatalf("result %+v", rs)
	}
}

func TestResultsSurviveAFailedSync(t *testing.T) {
	p := &fakePanel{tasks: []task{{ID: 3, Kind: "status"}}}
	f := &fakeRunner{stdout: map[string]string{"list": `{"count":0,"items":[]}`}}
	a, done := newTestAgent(t, p, f)
	defer done()
	if _, err := a.step(context.Background()); err != nil { // runs the task
		t.Fatal(err)
	}
	p.failNext = 1
	if _, err := a.step(context.Background()); err == nil {
		t.Fatal("a 500 from the panel was not an error")
	}
	if len(a.pending) != 1 {
		t.Fatalf("%d pending results after a failed sync, want 1", len(a.pending))
	}
	if _, err := a.step(context.Background()); err != nil {
		t.Fatal(err)
	}
	if rs := results(t, p.requests[len(p.requests)-1]["results"]); len(rs) != 1 || rs[0].TaskID != 3 || !rs[0].OK {
		t.Fatalf("delivered after the retry: %+v", rs)
	}
}

func TestWrongTokenIsAnHTTPError(t *testing.T) {
	p := &fakePanel{}
	a, done := newTestAgent(t, p, &fakeRunner{})
	defer done()
	a.cfg.Token = "wrong-token-0123456789abcdef0123456789abcdef"
	_, err := a.step(context.Background())
	var he *httpError
	if !errors.As(err, &he) || he.status != http.StatusUnauthorized {
		t.Fatalf("err=%v, want a 401 httpError", err)
	}
}
