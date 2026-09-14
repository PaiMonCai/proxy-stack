// psm-agent connects a server to the PSM panel.
//
// It opens no port, not even on loopback: it makes one HTTPS request to the
// panel at a time, which carries the results of its last tasks and brings back
// new ones, then waits as long as the panel says (30 s when idle, 3 s while
// there is work). Each task is run as a psm command with its arguments passed as
// an argv array (never through a shell) and checked against allowlists first,
// so the panel can make the server do nothing the psm command line cannot.
//
//	psm-agent join -panel https://psm.example.com -token <join token>
//	psm-agent run
package main

import (
	"bytes"
	"context"
	"encoding/json"
	"errors"
	"flag"
	"fmt"
	"io"
	"log"
	"net/http"
	"net/url"
	"os"
	"os/exec"
	"os/signal"
	"path/filepath"
	"regexp"
	"strings"
	"syscall"
	"time"
)

const agentVersion = "0.3.0"

const (
	commandTimeout  = 120 * time.Second // one psm command
	requestTimeout  = 30 * time.Second  // one request to the panel
	maxTaskData     = 64 << 10          // a task's node settings
	maxResponse     = 1 << 20           // a response from the panel
	defaultInterval = 30 * time.Second  // the panel says how long to wait; this is the fallback
	defaultConfig   = "/etc/psm/agent.json"
)

var cores = map[string]bool{"xray": true, "sing-box": true, "mihomo": true}

var protocols = map[string]bool{
	"reality": true, "vision": true, "xhttp": true, "ss2022": true, "trojan": true,
	"vmess": true, "socks": true, "hysteria2": true, "anytls": true, "snell": true,
	"vless": true, "tuic": true, "wireguard": true,
}

var (
	// a tag never starts with "-": psm would read "--show-secrets" as an option
	tagRe  = regexp.MustCompile(`^[A-Za-z0-9][A-Za-z0-9._-]{0,47}$`)
	hostRe = regexp.MustCompile(`^([A-Za-z0-9-]{1,63}\.)*[A-Za-z0-9-]{1,63}$|^[0-9a-fA-F:.]+$`)
)

// ── config ────────────────────────────────────────────────────────────────────

type config struct {
	Panel     string `json:"panel"`                // https://psm.example.com
	Token     string `json:"token"`                // this server's agent token
	PSM       string `json:"psm,omitempty"`        // the psm command, /usr/local/bin/psm by default
	AllowHTTP bool   `json:"allow_http,omitempty"` // local testing only
}

func checkPanelURL(raw string, allowHTTP bool) (string, error) {
	u, err := url.Parse(strings.TrimRight(raw, "/"))
	if err != nil || u.Host == "" || u.RawQuery != "" || u.Fragment != "" {
		return "", fmt.Errorf("panel %q: not a URL like https://psm.example.com", raw)
	}
	if u.Scheme != "https" && !(u.Scheme == "http" && allowHTTP) {
		return "", fmt.Errorf("panel %q: must be https://", raw)
	}
	return u.String(), nil
}

func loadConfig(path string) (*config, error) {
	raw, err := os.ReadFile(path)
	if err != nil {
		return nil, err
	}
	var c config
	if err := json.Unmarshal(raw, &c); err != nil {
		return nil, fmt.Errorf("%s: %w", path, err)
	}
	if c.Panel, err = checkPanelURL(c.Panel, c.AllowHTTP); err != nil {
		return nil, err
	}
	if len(c.Token) < 32 {
		return nil, errors.New("token: missing or too short; run psm-agent join")
	}
	if c.PSM == "" {
		c.PSM = "/usr/local/bin/psm"
	}
	return &c, nil
}

// saveConfig writes the config readable by root only, replacing it atomically.
func saveConfig(path string, c *config) error {
	raw, _ := json.MarshalIndent(c, "", "  ")
	if err := os.MkdirAll(filepath.Dir(path), 0o755); err != nil {
		return err
	}
	tmp := path + ".tmp"
	if err := os.WriteFile(tmp, append(raw, '\n'), 0o600); err != nil {
		return err
	}
	return os.Rename(tmp, path)
}

// ── talking to the panel ─────────────────────────────────────────────────────

var client = &http.Client{Timeout: requestTimeout}

// post sends a JSON body to the panel and decodes the JSON answer into out.
func post(ctx context.Context, panel, path, bearer string, body, out any) error {
	raw, _ := json.Marshal(body)
	req, err := http.NewRequestWithContext(ctx, http.MethodPost, panel+path, bytes.NewReader(raw))
	if err != nil {
		return err
	}
	req.Header.Set("Content-Type", "application/json")
	req.Header.Set("User-Agent", "psm-agent/"+agentVersion)
	if bearer != "" {
		req.Header.Set("Authorization", "Bearer "+bearer)
	}
	resp, err := client.Do(req)
	if err != nil {
		return err
	}
	defer resp.Body.Close()
	data, err := io.ReadAll(io.LimitReader(resp.Body, maxResponse))
	if err != nil {
		return err
	}
	if resp.StatusCode != http.StatusOK {
		var e struct {
			Error struct{ Message string } `json:"error"`
		}
		_ = json.Unmarshal(data, &e)
		return &httpError{status: resp.StatusCode, message: e.Error.Message}
	}
	return json.Unmarshal(data, out)
}

type httpError struct {
	status  int
	message string
}

func (e *httpError) Error() string { return fmt.Sprintf("panel answered %d: %s", e.status, e.message) }

// join trades a one-time join token for this server's agent token.
func join(ctx context.Context, cfgPath, panel, joinToken string, allowHTTP bool) error {
	panel, err := checkPanelURL(panel, allowHTTP)
	if err != nil {
		return err
	}
	host, _ := os.Hostname()
	var resp struct {
		AgentToken string                `json:"agent_token"`
		Server     struct{ Name string } `json:"server"`
	}
	req := map[string]string{"join_token": joinToken, "hostname": host, "agent_version": agentVersion}
	if err := post(ctx, panel, "/api/agent/join", "", req, &resp); err != nil {
		return err
	}
	if len(resp.AgentToken) < 32 {
		return errors.New("the panel returned no agent token")
	}
	if err := saveConfig(cfgPath, &config{Panel: panel, Token: resp.AgentToken, AllowHTTP: allowHTTP}); err != nil {
		return err
	}
	log.Printf("joined the panel as %s; config in %s", resp.Server.Name, cfgPath)
	return nil
}

// ── tasks ─────────────────────────────────────────────────────────────────────

type task struct {
	ID       int64           `json:"id"`
	Kind     string          `json:"kind"`
	Core     string          `json:"core,omitempty"`
	Protocol string          `json:"protocol,omitempty"`
	Tag      string          `json:"tag,omitempty"`
	Data     json.RawMessage `json:"data,omitempty"`
	Server   string          `json:"server,omitempty"` // the address in exported links
	Format   string          `json:"format,omitempty"` // uri | surge
}

type result struct {
	TaskID int64           `json:"task_id"`
	OK     bool            `json:"ok"`
	Output json.RawMessage `json:"output,omitempty"`
	Link   string          `json:"link,omitempty"`
	Error  string          `json:"error,omitempty"`
}

// runner runs psm with the given arguments (and stdin, when not nil).
type runner func(ctx context.Context, stdin []byte, args ...string) (stdout, stderr []byte, err error)

func execRunner(bin string) runner {
	return func(ctx context.Context, stdin []byte, args ...string) ([]byte, []byte, error) {
		cmd := exec.CommandContext(ctx, bin, args...)
		cmd.Env = append(os.Environ(), "PSM_LANG=en", "LANG=C.UTF-8", "TERM=dumb")
		if stdin != nil {
			cmd.Stdin = bytes.NewReader(stdin)
		}
		var out, errOut bytes.Buffer
		cmd.Stdout, cmd.Stderr = &out, &errOut
		err := cmd.Run()
		return out.Bytes(), errOut.Bytes(), err
	}
}

type agent struct {
	cfg      *config
	run      runner
	hostname string
	pending  []result // results not yet delivered to the panel
}

func rejected(t task, why string) result {
	return result{TaskID: t.ID, Error: "rejected by psm-agent: " + why}
}

// checkNode validates a task's core, protocol and (when wanted) tag.
func checkNode(t task, withTag bool) string {
	switch {
	case !cores[t.Core]:
		return "unknown core " + t.Core
	case !protocols[t.Protocol]:
		return "unknown protocol " + t.Protocol
	case withTag && !tagRe.MatchString(t.Tag):
		return "bad tag " + t.Tag
	}
	return ""
}

// nodeData checks that a task's settings are one JSON object of sane size.
func nodeData(t task) (map[string]any, string) {
	if len(t.Data) == 0 || len(t.Data) > maxTaskData {
		return nil, "missing or oversized node settings"
	}
	var obj map[string]any
	if err := json.Unmarshal(t.Data, &obj); err != nil || obj == nil {
		return nil, "node settings are not a JSON object"
	}
	return obj, ""
}

// psm runs one command; on failure the error is psm's own last line.
func (a *agent) psm(ctx context.Context, stdin []byte, args ...string) ([]byte, error) {
	ctx, cancel := context.WithTimeout(ctx, commandTimeout)
	defer cancel()
	out, errOut, err := a.run(ctx, stdin, args...)
	if err != nil {
		if msg := lastLine(errOut); msg != "" {
			return nil, errors.New(msg)
		}
		return nil, err
	}
	return out, nil
}

func (a *agent) export(ctx context.Context, t task) (string, error) {
	format := t.Format
	if format == "" {
		format = "uri"
	}
	if format != "uri" && format != "surge" {
		return "", errors.New("rejected by psm-agent: bad export format " + format)
	}
	if t.Server == "" || len(t.Server) > 253 || !hostRe.MatchString(t.Server) {
		return "", errors.New("rejected by psm-agent: bad server address")
	}
	out, err := a.psm(ctx, nil, "node", "export", t.Core, t.Protocol, t.Tag, "--format", format, "--server", t.Server)
	return strings.TrimSpace(string(out)), err
}

// execute runs one task and says how it went. A task that fails the checks
// never reaches psm.
func (a *agent) execute(ctx context.Context, t task) result {
	r := result{TaskID: t.ID}
	switch t.Kind {
	case "node.add":
		if why := checkNode(t, false); why != "" {
			return rejected(t, why)
		}
		obj, why := nodeData(t)
		if why != "" {
			return rejected(t, why)
		}
		tag, _ := obj["tag"].(string)
		if !tagRe.MatchString(tag) {
			return rejected(t, "bad tag "+tag)
		}
		if p, _ := obj["port"].(float64); p != float64(int(p)) || p < 1 || p > 65535 {
			return rejected(t, "bad port")
		}
		out, err := a.psm(ctx, t.Data, "node", "add", t.Core, t.Protocol, "--input", "-", "--json")
		if err != nil {
			r.Error = err.Error()
			return r
		}
		r.OK, r.Output = true, jsonOrNil(out)
		if t.Server != "" { // the client link, for the panel's subscription
			t.Tag = tag
			if link, err := a.export(ctx, t); err == nil {
				r.Link = link
			} else {
				log.Printf("task %d: node added, export failed: %v", t.ID, err)
			}
		}
	case "node.update":
		if why := checkNode(t, true); why != "" {
			return rejected(t, why)
		}
		if _, why := nodeData(t); why != "" {
			return rejected(t, why)
		}
		out, err := a.psm(ctx, t.Data, "node", "update", t.Core, t.Protocol, t.Tag, "--input", "-", "--json")
		if err != nil {
			r.Error = err.Error()
			return r
		}
		r.OK, r.Output = true, jsonOrNil(out)
	case "node.delete":
		if why := checkNode(t, true); why != "" {
			return rejected(t, why)
		}
		out, err := a.psm(ctx, nil, "node", "delete", t.Core, t.Protocol, t.Tag, "--yes", "--if-exists", "--json")
		if err != nil {
			r.Error = err.Error()
			return r
		}
		r.OK, r.Output = true, jsonOrNil(out)
	case "node.export":
		if why := checkNode(t, true); why != "" {
			return rejected(t, why)
		}
		link, err := a.export(ctx, t)
		if err != nil {
			r.Error = err.Error()
			return r
		}
		r.OK, r.Link = true, link
	case "status":
		out, err := a.psm(ctx, nil, "node", "list", "--json")
		if err != nil {
			r.Error = err.Error()
			return r
		}
		r.OK, r.Output = true, jsonOrNil(out)
	default:
		return rejected(t, "unsupported task kind "+t.Kind)
	}
	return r
}

func jsonOrNil(b []byte) json.RawMessage {
	if json.Valid(b) {
		return json.RawMessage(bytes.TrimSpace(b))
	}
	return nil
}

func lastLine(b []byte) string {
	lines := strings.Split(strings.TrimSpace(string(b)), "\n")
	return strings.TrimSpace(lines[len(lines)-1])
}

// ── the sync loop ─────────────────────────────────────────────────────────────

// step is one sync: deliver pending results, take and run new tasks. It says
// how long to wait before the next one. Results survive a failed sync.
func (a *agent) step(ctx context.Context) (time.Duration, error) {
	var resp struct {
		Interval int    `json:"interval"`
		Tasks    []task `json:"tasks"`
	}
	req := map[string]any{"agent_version": agentVersion, "hostname": a.hostname, "results": a.pending}
	if a.pending == nil {
		req["results"] = []result{}
	}
	if err := post(ctx, a.cfg.Panel, "/api/agent/sync", a.cfg.Token, req, &resp); err != nil {
		return 0, err
	}
	a.pending = nil
	for _, t := range resp.Tasks {
		r := a.execute(ctx, t)
		log.Printf("task %d %s %s/%s: ok=%v %s", t.ID, t.Kind, t.Core, t.Protocol, r.OK, r.Error)
		a.pending = append(a.pending, r)
	}
	if len(a.pending) > 0 {
		return 0, nil // report right away
	}
	interval := time.Duration(resp.Interval) * time.Second
	if interval < 3*time.Second || interval > 5*time.Minute {
		interval = defaultInterval
	}
	return interval, nil
}

func (a *agent) loop(ctx context.Context) {
	backoff := 5 * time.Second
	for {
		wait, err := a.step(ctx)
		if err != nil {
			var he *httpError
			if errors.As(err, &he) && he.status == http.StatusUnauthorized {
				log.Printf("the panel refused this agent's token; run psm-agent join again (%v)", err)
				wait = 5 * time.Minute
			} else {
				log.Printf("sync failed: %v", err)
				wait = backoff
				backoff = min(backoff*2, time.Minute)
			}
		} else {
			backoff = 5 * time.Second
		}
		select {
		case <-ctx.Done():
			return
		case <-time.After(wait):
		}
	}
}

func main() {
	log.SetFlags(log.LstdFlags)
	if len(os.Args) > 1 && (os.Args[1] == "-version" || os.Args[1] == "--version" || os.Args[1] == "version") {
		fmt.Println(agentVersion)
		return
	}
	if len(os.Args) < 2 {
		fmt.Fprintln(os.Stderr, "usage: psm-agent join -panel URL -token JOIN_TOKEN | psm-agent run | psm-agent version")
		os.Exit(2)
	}
	ctx, stop := signal.NotifyContext(context.Background(), os.Interrupt, syscall.SIGTERM)
	defer stop()

	switch os.Args[1] {
	case "join":
		fs := flag.NewFlagSet("join", flag.ExitOnError)
		cfgPath := fs.String("config", defaultConfig, "config file to write")
		panel := fs.String("panel", "", "the panel's address, https://…")
		token := fs.String("token", "", "the one-time join token from the install command")
		allowHTTP := fs.Bool("allow-http", false, "accept an http:// panel (local testing only)")
		_ = fs.Parse(os.Args[2:])
		if *panel == "" || *token == "" {
			log.Fatal("psm-agent join: -panel and -token are required")
		}
		if err := join(ctx, *cfgPath, *panel, *token, *allowHTTP); err != nil {
			log.Fatalf("psm-agent join: %v", err)
		}
	case "run":
		fs := flag.NewFlagSet("run", flag.ExitOnError)
		cfgPath := fs.String("config", defaultConfig, "config file")
		_ = fs.Parse(os.Args[2:])
		cfg, err := loadConfig(*cfgPath)
		if err != nil {
			log.Fatalf("psm-agent: %v", err)
		}
		host, _ := os.Hostname()
		log.Printf("psm-agent %s syncing with %s", agentVersion, cfg.Panel)
		(&agent{cfg: cfg, run: execRunner(cfg.PSM), hostname: host}).loop(ctx)
	default:
		log.Fatalf("psm-agent: unknown command %q", os.Args[1])
	}
}
