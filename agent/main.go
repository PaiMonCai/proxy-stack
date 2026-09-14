// psm-agent connects a server to the PSM panel.
//
// It opens no port, not even on loopback: it makes one HTTPS request to the
// panel at a time, which carries the results of its last tasks (and, every
// ten minutes, the traffic counters) and brings back new ones, then waits as
// long as the panel says (30 s when idle, 3 s while there is work). Each task
// is run as a psm command with its arguments passed as an argv array (never
// through a shell) and checked against allowlists first, so the panel can make
// the server do nothing the psm command line cannot.
//
// Tasks: node.add (installing the core first when the server has never run
// it), node.update, node.delete, node.export, standalone.install and
// standalone.remove (Snell / ss-rust), traffic.set, traffic.reset,
// traffic.report (send the counters with the next sync), status.
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
	"strconv"
	"strings"
	"syscall"
	"time"
)

const agentVersion = "0.4.0"

const (
	commandTimeout  = 120 * time.Second // one psm command
	installTimeout  = 15 * time.Minute  // installing a core or a standalone server
	requestTimeout  = 30 * time.Second  // one request to the panel
	maxTaskData     = 64 << 10          // a task's node settings
	maxResponse     = 1 << 20           // a response from the panel
	maxReport       = 512 << 10         // a status report sent to the panel
	defaultInterval = 30 * time.Second  // the panel says how long to wait; this is the fallback
	trafficEvery    = 10 * time.Minute  // how often the traffic counters go to the panel
	versionEvery    = time.Hour         // how often PSM's version is looked up again
	maxLimitBytes   = 1 << 53           // a traffic limit (8 PiB)
	defaultConfig   = "/etc/psm/agent.json"
)

var cores = map[string]bool{"xray": true, "sing-box": true, "mihomo": true}

var protocols = map[string]bool{
	"reality": true, "vision": true, "xhttp": true, "ss2022": true, "trojan": true,
	"vmess": true, "socks": true, "hysteria2": true, "anytls": true, "snell": true,
	"vless": true, "tuic": true, "wireguard": true,
}

// the standalone servers (`psm standalone`)
var standalones = map[string]bool{"snell": true, "ss2022": true}

var ssMethods = map[string]bool{
	"2022-blake3-aes-128-gcm": true, "2022-blake3-aes-256-gcm": true, "2022-blake3-chacha20-poly1305": true,
}

var snellVersions = map[string]bool{"4": true, "5": true, "6": true}

var (
	// a tag never starts with "-": psm would read "--show-secrets" as an option
	tagRe  = regexp.MustCompile(`^[A-Za-z0-9][A-Za-z0-9._-]{0,47}$`)
	hostRe = regexp.MustCompile(`^([A-Za-z0-9-]{1,63}\.)*[A-Za-z0-9-]{1,63}$|^[0-9a-fA-F:.]+$`)
	pskRe  = regexp.MustCompile(`^[A-Za-z0-9+/=_][A-Za-z0-9+/=_-]{7,127}$`)
	keyRe  = regexp.MustCompile(`^[A-Za-z0-9+/]{16,86}={0,2}$`)
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
	ID         int64           `json:"id"`
	Kind       string          `json:"kind"`
	Core       string          `json:"core,omitempty"`
	Protocol   string          `json:"protocol,omitempty"` // PSM's protocol; snell / ss2022 for standalone.*
	Tag        string          `json:"tag,omitempty"`      // the node's tag (its name in the panel)
	Data       json.RawMessage `json:"data,omitempty"`     // node settings
	Server     string          `json:"server,omitempty"`   // the address in exported links
	Format     string          `json:"format,omitempty"`   // uri | surge
	LimitBytes int64           `json:"limit_bytes,omitempty"`
	ResetDay   int             `json:"reset_day,omitempty"`
}

type result struct {
	TaskID   int64           `json:"task_id"`
	OK       bool            `json:"ok"`
	Output   json.RawMessage `json:"output,omitempty"`
	Link     string          `json:"link,omitempty"`
	Outbound json.RawMessage `json:"outbound,omitempty"` // the node as a sing-box client outbound
	Error    string          `json:"error,omitempty"`
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
	cfg         *config
	run         runner
	hostname    string
	pending     []result  // results not yet delivered to the panel
	lastTraffic time.Time // when the traffic counters last went to the panel
	psmVersion  string
	versionAt   time.Time
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

func goodPort(v any) (int, bool) {
	p, ok := v.(float64)
	return int(p), ok && p == float64(int(p)) && p >= 1 && p <= 65535
}

// text reads a setting that may have been sent as a string or a number.
func text(obj map[string]any, key string) string {
	switch v := obj[key].(type) {
	case string:
		return v
	case float64:
		return strconv.FormatFloat(v, 'f', -1, 64)
	}
	return ""
}

// standaloneArgs turns a standalone.install task into the psm arguments.
func standaloneArgs(t task) ([]string, string) {
	obj, why := nodeData(t)
	if why != "" {
		return nil, why
	}
	port, ok := goodPort(obj["port"])
	if !ok {
		return nil, "bad port"
	}
	args := []string{"standalone", "install", t.Protocol, "--port", strconv.Itoa(port), "--json"}
	switch t.Protocol {
	case "snell":
		v := text(obj, "version")
		if v == "" {
			v = "5"
		}
		if !snellVersions[v] {
			return nil, "bad Snell version " + v
		}
		args = append(args, "--version", v)
		if psk := text(obj, "psk"); psk != "" {
			if !pskRe.MatchString(psk) {
				return nil, "bad PSK"
			}
			args = append(args, "--psk", psk)
		}
	case "ss2022":
		m := text(obj, "method")
		if m == "" {
			m = "2022-blake3-aes-128-gcm"
		}
		if !ssMethods[m] {
			return nil, "bad method " + m
		}
		args = append(args, "--method", m)
		if pw := text(obj, "password"); pw != "" {
			if !keyRe.MatchString(pw) {
				return nil, "bad password (a base64 key)"
			}
			args = append(args, "--password", pw)
		}
	}
	return args, ""
}

// psm runs one command; on failure the error is psm's own last line.
func (a *agent) psm(ctx context.Context, stdin []byte, args ...string) ([]byte, error) {
	return a.psmFor(ctx, commandTimeout, stdin, args...)
}

func (a *agent) psmFor(ctx context.Context, timeout time.Duration, stdin []byte, args ...string) ([]byte, error) {
	ctx, cancel := context.WithTimeout(ctx, timeout)
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

// jsonPart runs a read-only command and returns its JSON output, or null. psm
// doctor exits non-zero when a check fails, yet its report is still wanted.
func (a *agent) jsonPart(ctx context.Context, args ...string) json.RawMessage {
	ctx, cancel := context.WithTimeout(ctx, commandTimeout)
	defer cancel()
	out, _, _ := a.run(ctx, nil, args...)
	out = bytes.TrimSpace(out)
	if len(out) == 0 || !json.Valid(out) {
		return json.RawMessage("null")
	}
	return json.RawMessage(out)
}

// export returns a node's client link and, when sing-box has a client
// outbound for it, that outbound. standalone: the standalone server named by
// t.Protocol, shown in links as PSM-<tag>.
func (a *agent) export(ctx context.Context, t task, standalone bool) (string, json.RawMessage, error) {
	format := t.Format
	if format == "" {
		format = "uri"
	}
	if format != "uri" && format != "surge" {
		return "", nil, errors.New("rejected by psm-agent: bad export format " + format)
	}
	if t.Server == "" || len(t.Server) > 253 || !hostRe.MatchString(t.Server) {
		return "", nil, errors.New("rejected by psm-agent: bad server address")
	}
	base := []string{"node", "export", t.Core, t.Protocol, t.Tag}
	if standalone {
		base = []string{"standalone", "export", t.Protocol, "--name", "PSM-" + t.Tag}
	}
	with := func(f string) []string {
		return append(append([]string{}, base...), "--format", f, "--server", t.Server)
	}
	out, err := a.psm(ctx, nil, with(format)...)
	if err != nil {
		return "", nil, err
	}
	var ob json.RawMessage
	if sb, err := a.psm(ctx, nil, with("singbox")...); err == nil {
		if sb = bytes.TrimSpace(sb); len(sb) > 0 && json.Valid(sb) {
			ob = json.RawMessage(sb)
		}
	}
	return strings.TrimSpace(string(out)), ob, nil
}

// status gathers what the panel shows for a server.
func (a *agent) status(ctx context.Context) json.RawMessage {
	raw, _ := json.Marshal(map[string]any{
		"psm_version":   a.version(ctx, true),
		"agent_version": agentVersion,
		"cores":         a.jsonPart(ctx, "core", "list", "--json"),
		"doctor":        a.jsonPart(ctx, "doctor", "--json"),
		"nodes":         a.jsonPart(ctx, "node", "list", "--json"),
		"traffic":       a.jsonPart(ctx, "traffic", "list", "--json"),
		"snell":         a.jsonPart(ctx, "standalone", "show", "snell", "--json"),
		"ss2022":        a.jsonPart(ctx, "standalone", "show", "ss2022", "--json"),
	})
	if len(raw) > maxReport {
		raw, _ = json.Marshal(map[string]any{"error": "status report too large"})
	}
	return raw
}

// execute runs one task and says how it went. A task that fails the checks
// never reaches psm.
func (a *agent) execute(ctx context.Context, t task) result {
	r := result{TaskID: t.ID}
	fail := func(err error) result { r.Error = err.Error(); return r }
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
		if _, ok := goodPort(obj["port"]); !ok {
			return rejected(t, "bad port")
		}
		// a server that has never run this core gets it first
		if _, err := a.psmFor(ctx, installTimeout, nil, "core", "install", t.Core, "--if-missing", "--json"); err != nil {
			return fail(fmt.Errorf("installing %s: %w", t.Core, err))
		}
		out, err := a.psm(ctx, t.Data, "node", "add", t.Core, t.Protocol, "--input", "-", "--json")
		if err != nil {
			return fail(err)
		}
		r.OK, r.Output = true, jsonOrNil(out)
		if t.Server != "" { // the client link, for the panel's subscription
			t.Tag = tag
			if link, ob, err := a.export(ctx, t, false); err == nil {
				r.Link, r.Outbound = link, ob
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
			return fail(err)
		}
		r.OK, r.Output = true, jsonOrNil(out)
		if t.Server != "" {
			if link, ob, err := a.export(ctx, t, false); err == nil {
				r.Link, r.Outbound = link, ob
			}
		}
	case "node.delete":
		if why := checkNode(t, true); why != "" {
			return rejected(t, why)
		}
		out, err := a.psm(ctx, nil, "node", "delete", t.Core, t.Protocol, t.Tag, "--yes", "--if-exists", "--json")
		if err != nil {
			return fail(err)
		}
		r.OK, r.Output = true, jsonOrNil(out)
	case "node.export":
		if why := checkNode(t, true); why != "" {
			return rejected(t, why)
		}
		link, ob, err := a.export(ctx, t, false)
		if err != nil {
			return fail(err)
		}
		r.OK, r.Link, r.Outbound = true, link, ob
	case "standalone.install":
		if !standalones[t.Protocol] {
			return rejected(t, "not a standalone server: "+t.Protocol)
		}
		if !tagRe.MatchString(t.Tag) {
			return rejected(t, "bad tag "+t.Tag)
		}
		args, why := standaloneArgs(t)
		if why != "" {
			return rejected(t, why)
		}
		out, err := a.psmFor(ctx, installTimeout, nil, args...)
		if err != nil {
			return fail(err)
		}
		r.OK, r.Output = true, jsonOrNil(out)
		if t.Server != "" {
			if link, ob, err := a.export(ctx, t, true); err == nil {
				r.Link, r.Outbound = link, ob
			} else {
				log.Printf("task %d: %s installed, export failed: %v", t.ID, t.Protocol, err)
			}
		}
	case "standalone.remove":
		if !standalones[t.Protocol] {
			return rejected(t, "not a standalone server: "+t.Protocol)
		}
		out, err := a.psmFor(ctx, installTimeout, nil, "standalone", "remove", t.Protocol, "--yes", "--json")
		if err != nil {
			return fail(err)
		}
		r.OK, r.Output = true, jsonOrNil(out)
	case "traffic.set":
		if !tagRe.MatchString(t.Tag) {
			return rejected(t, "bad tag "+t.Tag)
		}
		if t.LimitBytes < 0 || t.LimitBytes > maxLimitBytes {
			return rejected(t, "bad traffic limit")
		}
		if t.ResetDay < 0 || t.ResetDay > 28 {
			return rejected(t, "bad reset day")
		}
		args := []string{"traffic", "set", t.Tag, "--limit-bytes", strconv.FormatInt(t.LimitBytes, 10), "--json"}
		if t.ResetDay > 0 {
			args = append(args, "--reset-day", strconv.Itoa(t.ResetDay))
		}
		out, err := a.psm(ctx, nil, args...)
		if err != nil {
			return fail(err)
		}
		r.OK, r.Output = true, jsonOrNil(out)
		a.lastTraffic = time.Time{} // the next sync carries the counters
	case "traffic.reset":
		if !tagRe.MatchString(t.Tag) {
			return rejected(t, "bad tag "+t.Tag)
		}
		out, err := a.psm(ctx, nil, "traffic", "reset", t.Tag, "--json")
		if err != nil {
			return fail(err)
		}
		r.OK, r.Output = true, jsonOrNil(out)
		a.lastTraffic = time.Time{}
	case "traffic.report": // the panel's 流量 page asks for the counters now
		a.lastTraffic = time.Time{}
		r.OK = true
	case "status":
		r.OK, r.Output = true, a.status(ctx)
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

// version is PSM's version ("2026-09-15 abc1234"), looked up once an hour.
func (a *agent) version(ctx context.Context, fresh bool) string {
	if fresh || time.Since(a.versionAt) >= versionEvery {
		if out, err := a.psm(ctx, nil, "version"); err == nil {
			a.psmVersion = strings.TrimSpace(string(out))
		}
		a.versionAt = time.Now()
	}
	return a.psmVersion
}

// ── the sync loop ─────────────────────────────────────────────────────────────

// step is one sync: deliver pending results (and, when due, the traffic
// counters), take and run new tasks. It says how long to wait before the next
// one. Results survive a failed sync.
func (a *agent) step(ctx context.Context) (time.Duration, error) {
	var resp struct {
		Interval int    `json:"interval"`
		Tasks    []task `json:"tasks"`
	}
	req := map[string]any{"agent_version": agentVersion, "hostname": a.hostname, "results": a.pending}
	if a.pending == nil {
		req["results"] = []result{}
	}
	if v := a.version(ctx, false); v != "" {
		req["psm_version"] = v
	}
	trafficDue := time.Since(a.lastTraffic) >= trafficEvery
	if trafficDue {
		if tr := a.jsonPart(ctx, "traffic", "list", "--json"); string(tr) != "null" {
			req["traffic"] = tr
		}
	}
	if err := post(ctx, a.cfg.Panel, "/api/agent/sync", a.cfg.Token, req, &resp); err != nil {
		return 0, err
	}
	a.pending = nil
	if trafficDue {
		a.lastTraffic = time.Now()
	}
	for _, t := range resp.Tasks {
		r := a.execute(ctx, t)
		log.Printf("task %d %s %s/%s %s: ok=%v %s", t.ID, t.Kind, t.Core, t.Protocol, t.Tag, r.OK, r.Error)
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
