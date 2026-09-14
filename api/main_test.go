package main

import (
	"context"
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"errors"
	"net/http"
	"net/http/httptest"
	"reflect"
	"strings"
	"testing"
)

const testToken = "test-token-0123456789abcdef0123456789abcdef"

func testConfig() *config {
	sum := sha256.Sum256([]byte(testToken))
	return &config{Listen: "127.0.0.1:9870", TokenSHA256: hex.EncodeToString(sum[:]), PSM: "/bin/false"}
}

// fakeRunner records the arguments it was called with and returns canned output.
type fakeRunner struct {
	args   []string
	stdout string
	stderr string
	err    error
}

func (f *fakeRunner) run(_ context.Context, args ...string) ([]byte, []byte, error) {
	f.args = args
	return []byte(f.stdout), []byte(f.stderr), f.err
}

func do(t *testing.T, h http.Handler, method, path, token string) *httptest.ResponseRecorder {
	t.Helper()
	req := httptest.NewRequest(method, path, nil)
	if token != "" {
		req.Header.Set("Authorization", "Bearer "+token)
	}
	rec := httptest.NewRecorder()
	h.ServeHTTP(rec, req)
	return rec
}

func errorCode(t *testing.T, rec *httptest.ResponseRecorder) string {
	t.Helper()
	var body struct {
		Error struct{ Code string } `json:"error"`
	}
	if err := json.Unmarshal(rec.Body.Bytes(), &body); err != nil {
		t.Fatalf("error body is not JSON: %q", rec.Body.String())
	}
	return body.Error.Code
}

func TestAuth(t *testing.T) {
	f := &fakeRunner{stdout: `[]`}
	h := newServer(testConfig(), f.run).handler()
	for _, tc := range []struct {
		name, token string
		want        int
	}{
		{"no token", "", http.StatusUnauthorized},
		{"wrong token", "not-the-token", http.StatusUnauthorized},
		{"right token", testToken, http.StatusOK},
	} {
		if rec := do(t, h, "GET", "/v1/health", tc.token); rec.Code != tc.want {
			t.Errorf("%s: status %d, want %d", tc.name, rec.Code, tc.want)
		}
	}
	// a token passed any other way than "Bearer" is not accepted
	req := httptest.NewRequest("GET", "/v1/health", nil)
	req.Header.Set("Authorization", "Basic "+testToken)
	rec := httptest.NewRecorder()
	h.ServeHTTP(rec, req)
	if rec.Code != http.StatusUnauthorized {
		t.Errorf("Basic auth: status %d, want 401", rec.Code)
	}
}

func TestListNodesPassesJSONThrough(t *testing.T) {
	f := &fakeRunner{stdout: `[{"core":"xray","protocol":"reality","tag":"hk"}]`}
	h := newServer(testConfig(), f.run).handler()
	rec := do(t, h, "GET", "/v1/nodes?core=xray&protocol=reality", testToken)
	if rec.Code != http.StatusOK {
		t.Fatalf("status %d: %s", rec.Code, rec.Body.String())
	}
	if want := []string{"node", "list", "--json", "--core", "xray", "--protocol", "reality"}; !reflect.DeepEqual(f.args, want) {
		t.Errorf("psm args %q, want %q", f.args, want)
	}
	if strings.TrimSpace(rec.Body.String()) != f.stdout {
		t.Errorf("body %q, want psm's output", rec.Body.String())
	}
	if ct := rec.Header().Get("Content-Type"); ct != "application/json" {
		t.Errorf("content type %q", ct)
	}
}

func TestListNodesRejectsUnknownValues(t *testing.T) {
	f := &fakeRunner{stdout: `[]`}
	h := newServer(testConfig(), f.run).handler()
	for path, code := range map[string]string{
		// a ";" makes Go's URL.Query drop the parameter silently, which would
		// have skipped its check: a malformed query is refused outright
		"/v1/nodes?core=xray;rm":            "bad_query",
		"/v1/nodes?core=v2ray":              "bad_core",
		"/v1/nodes?protocol=--show-secrets": "bad_protocol",
		"/v1/nodes?show-secrets=1":          "bad_query",
	} {
		f.args = nil
		rec := do(t, h, "GET", path, testToken)
		if rec.Code != http.StatusBadRequest || errorCode(t, rec) != code {
			t.Errorf("%s: status %d code %q, want 400 %q", path, rec.Code, errorCode(t, rec), code)
		}
		if f.args != nil {
			t.Errorf("%s: psm ran with %q; a rejected request must not run psm", path, f.args)
		}
	}
}

func TestPSMFailureAndBadOutput(t *testing.T) {
	f := &fakeRunner{stderr: "loading…\nError: sing-box is not installed\n", err: errors.New("exit status 1")}
	h := newServer(testConfig(), f.run).handler()
	rec := do(t, h, "GET", "/v1/nodes", testToken)
	if rec.Code != http.StatusBadGateway || errorCode(t, rec) != "psm_failed" ||
		!strings.Contains(rec.Body.String(), "sing-box is not installed") {
		t.Errorf("failure: status %d body %s", rec.Code, rec.Body.String())
	}

	f = &fakeRunner{stdout: "[WARN] not json"}
	h = newServer(testConfig(), f.run).handler()
	if rec := do(t, h, "GET", "/v1/nodes", testToken); rec.Code != http.StatusBadGateway || errorCode(t, rec) != "bad_output" {
		t.Errorf("bad output: status %d body %s", rec.Code, rec.Body.String())
	}
}

func TestUnknownEndpointAndMethod(t *testing.T) {
	h := newServer(testConfig(), (&fakeRunner{stdout: `[]`}).run).handler()
	if rec := do(t, h, "GET", "/v1/nope", testToken); rec.Code != http.StatusNotFound {
		t.Errorf("unknown path: status %d", rec.Code)
	}
	if rec := do(t, h, "DELETE", "/v1/health", testToken); rec.Code == http.StatusOK {
		t.Errorf("DELETE /v1/health answered 200")
	}
	// unauthenticated requests learn nothing, not even whether a path exists
	if rec := do(t, h, "GET", "/v1/nope", ""); rec.Code != http.StatusUnauthorized {
		t.Errorf("unauthenticated unknown path: status %d, want 401", rec.Code)
	}
}

func TestConfigListensOnLoopbackOnly(t *testing.T) {
	for addr, ok := range map[string]bool{
		"127.0.0.1:9870": true, "[::1]:9870": true, "localhost:9870": true,
		"0.0.0.0:9870": false, ":9870": false, "203.0.113.10:9870": false, "[::]:9870": false,
	} {
		c := testConfig()
		c.Listen = addr
		if err := c.validate(); (err == nil) != ok {
			t.Errorf("listen %s: err=%v, want ok=%v", addr, err, ok)
		}
	}
	c := testConfig()
	c.TokenSHA256 = "abc"
	if c.validate() == nil {
		t.Error("a short token hash was accepted")
	}
}
