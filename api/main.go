// psm-api is the HTTP side of PSM for the PSM panel.
//
// It listens on loopback only: Cloudflare Tunnel is the one way in, with
// Cloudflare Access in front, so no port is opened on the server. Every request
// needs a bearer token whose SHA-256 is kept in the config; the token itself is
// never stored. Requests are served by running psm's own commands with --json,
// with arguments passed as an argv array (never through a shell) and checked
// against allowlists, so the panel can do nothing the command line cannot.
package main

import (
	"bytes"
	"context"
	"crypto/sha256"
	"crypto/subtle"
	"encoding/hex"
	"encoding/json"
	"errors"
	"flag"
	"fmt"
	"io"
	"log"
	"net"
	"net/http"
	"net/url"
	"os"
	"os/exec"
	"slices"
	"strings"
	"time"
)

const apiVersion = "0.1.0"

// How long one psm command may run; installing a core can take a while.
const commandTimeout = 120 * time.Second

var cores = map[string]bool{"xray": true, "sing-box": true, "mihomo": true}

var protocols = map[string]bool{
	"reality": true, "vision": true, "xhttp": true, "ss2022": true, "trojan": true,
	"vmess": true, "socks": true, "hysteria2": true, "anytls": true, "snell": true,
	"vless": true, "tuic": true, "wireguard": true,
}

type config struct {
	Listen      string `json:"listen"`       // loopback address, e.g. 127.0.0.1:9870
	TokenSHA256 string `json:"token_sha256"` // hex SHA-256 of the bearer token
	PSM         string `json:"psm"`          // the psm command, /usr/local/bin/psm by default
}

func loadConfig(path string) (*config, error) {
	raw, err := os.ReadFile(path)
	if err != nil {
		return nil, err
	}
	cfg := &config{Listen: "127.0.0.1:9870", PSM: "/usr/local/bin/psm"}
	if err := json.Unmarshal(raw, cfg); err != nil {
		return nil, fmt.Errorf("%s: %w", path, err)
	}
	return cfg, cfg.validate()
}

func (c *config) validate() error {
	host, _, err := net.SplitHostPort(c.Listen)
	if err != nil {
		return fmt.Errorf("listen %q: %w", c.Listen, err)
	}
	if ip := net.ParseIP(host); host != "localhost" && (ip == nil || !ip.IsLoopback()) {
		return fmt.Errorf("listen %q: psm-api only listens on loopback; Cloudflare Tunnel is the way in", c.Listen)
	}
	if b, err := hex.DecodeString(c.TokenSHA256); err != nil || len(b) != sha256.Size {
		return errors.New("token_sha256 must be the hex SHA-256 of the API token")
	}
	if c.PSM == "" {
		return errors.New("psm: command path is empty")
	}
	return nil
}

// runner runs psm with the given arguments and returns stdout and stderr.
type runner func(ctx context.Context, args ...string) (stdout, stderr []byte, err error)

func execRunner(bin string) runner {
	return func(ctx context.Context, args ...string) ([]byte, []byte, error) {
		cmd := exec.CommandContext(ctx, bin, args...)
		// English messages and a UTF-8 locale whatever the server's defaults
		cmd.Env = append(os.Environ(), "PSM_LANG=en", "LANG=C.UTF-8", "TERM=dumb")
		var out, errOut bytes.Buffer
		cmd.Stdout, cmd.Stderr = &out, &errOut
		err := cmd.Run()
		return out.Bytes(), errOut.Bytes(), err
	}
}

type server struct {
	tokenHash []byte
	run       runner
	hostname  string
}

func newServer(cfg *config, run runner) *server {
	h, _ := hex.DecodeString(cfg.TokenSHA256)
	name, _ := os.Hostname()
	return &server{tokenHash: h, run: run, hostname: name}
}

func (s *server) handler() http.Handler {
	mux := http.NewServeMux()
	mux.HandleFunc("GET /v1/health", s.health)
	mux.HandleFunc("GET /v1/nodes", s.listNodes)
	mux.HandleFunc("/", func(w http.ResponseWriter, r *http.Request) {
		writeError(w, http.StatusNotFound, "not_found", "no such endpoint")
	})
	return logRequests(s.auth(mux))
}

// auth accepts only "Authorization: Bearer <token>" whose SHA-256 matches.
func (s *server) auth(next http.Handler) http.Handler {
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		token, ok := strings.CutPrefix(r.Header.Get("Authorization"), "Bearer ")
		if !ok || token == "" {
			writeError(w, http.StatusUnauthorized, "unauthorized", "missing bearer token")
			return
		}
		sum := sha256.Sum256([]byte(token))
		if subtle.ConstantTimeCompare(sum[:], s.tokenHash) != 1 {
			writeError(w, http.StatusUnauthorized, "unauthorized", "invalid token")
			return
		}
		next.ServeHTTP(w, r)
	})
}

func (s *server) health(w http.ResponseWriter, _ *http.Request) {
	writeJSON(w, http.StatusOK, map[string]string{"api_version": apiVersion, "hostname": s.hostname})
}

// strictQuery parses the query string, refusing a malformed one (r.URL.Query
// silently drops a parameter it cannot parse, e.g. one with ";", which would
// skip its validation) and any parameter not in allowed.
func strictQuery(w http.ResponseWriter, r *http.Request, allowed ...string) (url.Values, bool) {
	q, err := url.ParseQuery(r.URL.RawQuery)
	if err != nil {
		writeError(w, http.StatusBadRequest, "bad_query", "malformed query string")
		return nil, false
	}
	for k := range q {
		if !slices.Contains(allowed, k) {
			writeError(w, http.StatusBadRequest, "bad_query", "unknown parameter: "+k)
			return nil, false
		}
	}
	return q, true
}

// GET /v1/nodes[?core=&protocol=] → psm node list --json
func (s *server) listNodes(w http.ResponseWriter, r *http.Request) {
	args := []string{"node", "list", "--json"}
	q, ok := strictQuery(w, r, "core", "protocol")
	if !ok {
		return
	}
	if c := q.Get("core"); c != "" {
		if !cores[c] {
			writeError(w, http.StatusBadRequest, "bad_core", "unknown core: "+c)
			return
		}
		args = append(args, "--core", c)
	}
	if p := q.Get("protocol"); p != "" {
		if !protocols[p] {
			writeError(w, http.StatusBadRequest, "bad_protocol", "unknown protocol: "+p)
			return
		}
		args = append(args, "--protocol", p)
	}
	s.psmJSON(w, r, args...)
}

// psmJSON runs psm and passes its JSON output through; psm's own error goes
// back as the message when it fails.
func (s *server) psmJSON(w http.ResponseWriter, r *http.Request, args ...string) {
	ctx, cancel := context.WithTimeout(r.Context(), commandTimeout)
	defer cancel()
	out, errOut, err := s.run(ctx, args...)
	if err != nil {
		msg := lastLine(errOut)
		if msg == "" {
			msg = err.Error()
		}
		writeError(w, http.StatusBadGateway, "psm_failed", msg)
		return
	}
	if !json.Valid(out) {
		writeError(w, http.StatusBadGateway, "bad_output", "psm did not return JSON")
		return
	}
	w.Header().Set("Content-Type", "application/json")
	w.WriteHeader(http.StatusOK)
	_, _ = w.Write(out)
}

func lastLine(b []byte) string {
	lines := strings.Split(strings.TrimSpace(string(b)), "\n")
	return strings.TrimSpace(lines[len(lines)-1])
}

func writeJSON(w http.ResponseWriter, status int, v any) {
	w.Header().Set("Content-Type", "application/json")
	w.WriteHeader(status)
	_ = json.NewEncoder(w).Encode(v)
}

func writeError(w http.ResponseWriter, status int, code, message string) {
	writeJSON(w, status, map[string]any{"error": map[string]string{"code": code, "message": message}})
}

// logRequests writes one line per request: method, path, status, duration.
// Never headers or bodies, which carry credentials.
type statusWriter struct {
	http.ResponseWriter
	status int
}

func (sw *statusWriter) WriteHeader(code int) {
	sw.status = code
	sw.ResponseWriter.WriteHeader(code)
}

func logRequests(next http.Handler) http.Handler {
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		start := time.Now()
		sw := &statusWriter{ResponseWriter: w, status: http.StatusOK}
		next.ServeHTTP(sw, r)
		log.Printf("%s %s %d %s", r.Method, r.URL.Path, sw.status, time.Since(start).Round(time.Millisecond))
	})
}

func main() {
	cfgPath := flag.String("config", "/etc/psm/api.json", "config file")
	hashToken := flag.Bool("hash-token", false, "read a token on stdin and print its SHA-256 (for the config)")
	showVersion := flag.Bool("version", false, "print the version")
	flag.Parse()

	switch {
	case *showVersion:
		fmt.Println(apiVersion)
		return
	case *hashToken:
		tok, err := io.ReadAll(io.LimitReader(os.Stdin, 4096))
		if err != nil {
			log.Fatal(err)
		}
		sum := sha256.Sum256(bytes.TrimSpace(tok))
		fmt.Println(hex.EncodeToString(sum[:]))
		return
	}

	cfg, err := loadConfig(*cfgPath)
	if err != nil {
		log.Fatalf("psm-api: %v", err)
	}
	srv := &http.Server{
		Addr:              cfg.Listen,
		Handler:           newServer(cfg, execRunner(cfg.PSM)).handler(),
		ReadHeaderTimeout: 10 * time.Second,
		WriteTimeout:      commandTimeout + 30*time.Second,
		MaxHeaderBytes:    16 << 10,
	}
	log.Printf("psm-api %s listening on %s", apiVersion, cfg.Listen)
	log.Fatal(srv.ListenAndServe())
}
