// web.go — local web console for file transfer.
//
// `omarchy-tailcat web [--listen=127.0.0.1:8080] [--recv-dir=~/Downloads]`
// serves a small HTML/JS page on loopback only. It drives the upstream
// `tailcat` CLI (recv drop-box + cp) — no native tailcat library — so it
// stays on the slim backend. Tokens are never logged or rendered fully.
package main

import (
	"encoding/json"
	"fmt"
	"io"
	"net"
	"net/http"
	"os"
	"os/exec"
	"path/filepath"
	"regexp"
	"sort"
	"strconv"
	"strings"
	"sync"
	"syscall"
	"time"

	"omarchy-tailcat/config"
)

// addrRe matches the address line tailcat recv prints.
var addrRe = regexp.MustCompile(`new address:\s*(\S+)`)

type recvFile struct {
	Name    string `json:"name"`
	Size    int64  `json:"size"`
	ModTime string `json:"modTime"`
}

type sendJob struct {
	mu      sync.Mutex
	Path    string    `json:"path"`
	Target  string    `json:"target"`
	Status  string    `json:"status"` // running | done | error
	Detail  string    `json:"detail,omitempty"`
	Started time.Time `json:"started"`
	Done    time.Time `json:"done,omitempty"`
}

type webServer struct {
	recvDir string

	mu       sync.Mutex
	recvCmd  *exec.Cmd
	recvAddr string

	sendMu sync.Mutex
	send   *sendJob
}

// tailcatBin returns the tailcat CLI path.
func tailcatBin() string {
	if v := os.Getenv("TAILCAT_BIN"); v != "" {
		return v
	}
	return "tailcat"
}

func webCmd(args []string) int {
	if len(args) > 0 {
		switch args[0] {
		case "start":
			return webDaemonStart(args[1:])
		case "stop":
			return webDaemonStop()
		case "status":
			out(webDaemonStatus())
			return 0
		case "restart":
			webDaemonStop()
			return webDaemonStart(args[1:])
		}
	}
	// Front-run server (also the daemon child process).
	listen, recvDir, err := parseWebArgs(args)
	if err != nil {
		return errOut(err)
	}
	return webServe(listen, recvDir)
}

// parseWebArgs extracts --listen/--port and --recv-dir flags.
func parseWebArgs(args []string) (listen, recvDir string, err error) {
	listen = "127.0.0.1:8080"
	recvDir = filepath.Join(os.Getenv("HOME"), "Downloads")
	for i := 0; i < len(args); i++ {
		switch {
		case args[i] == "--listen" && i+1 < len(args):
			listen = args[i+1]
			i++
		case strings.HasPrefix(args[i], "--listen="):
			listen = strings.TrimPrefix(args[i], "--listen=")
		case args[i] == "--port" && i+1 < len(args):
			listen = "127.0.0.1:" + args[i+1]
			i++
		case strings.HasPrefix(args[i], "--port="):
			listen = "127.0.0.1:" + strings.TrimPrefix(args[i], "--port=")
		case args[i] == "--recv-dir" && i+1 < len(args):
			recvDir = args[i+1]
			i++
		case strings.HasPrefix(args[i], "--recv-dir="):
			recvDir = strings.TrimPrefix(args[i], "--recv-dir=")
		default:
			return "", "", fmt.Errorf("unknown web arg: %s (args: --listen=<addr:port> --port=<n> --recv-dir=<dir>)", args[i])
		}
	}
	return listen, recvDir, nil
}

// webServe runs the HTTP file-transfer console in the foreground.
func webServe(listen, recvDir string) int {
	if err := os.MkdirAll(recvDir, 0o755); err != nil {
		return errOut(err)
	}

	s := &webServer{recvDir: recvDir}
	mux := http.NewServeMux()
	mux.HandleFunc("/", s.index)
	mux.HandleFunc("/api/recv/start", s.apiRecvStart)
	mux.HandleFunc("/api/recv/status", s.apiRecvStatus)
	mux.HandleFunc("/api/recv/stop", s.apiRecvStop)
	mux.HandleFunc("/api/recv/dl", s.apiRecvDownload)
	mux.HandleFunc("/api/recv/rm", s.apiRecvRemove)
	mux.HandleFunc("/api/send", s.apiSend)
	mux.HandleFunc("/api/send/status", s.apiSendStatus)

	srv := &http.Server{Addr: listen, Handler: mux}
	fmt.Fprintf(os.Stderr, "Tailcat web console: http://%s\n", listen)
	fmt.Fprintf(os.Stderr, "Receive dir: %s\n", recvDir)
	if err := srv.ListenAndServe(); err != nil && err != http.ErrServerClosed {
		return errOut(err)
	}
	return 0
}

// ---- web daemon management (web start/stop/status) ------------------------

type webState struct {
	PID       int    `json:"pid"`
	Port      int    `json:"port"`
	RecvDir   string `json:"recvDir"`
	StartedAt string `json:"startedAt,omitempty"`
}

func webStatePath() string { return filepath.Join(config.Dir(), "web.json") }

func loadWebState() (*webState, error) {
	b, err := os.ReadFile(webStatePath())
	if err != nil {
		return nil, err
	}
	var st webState
	if err := json.Unmarshal(b, &st); err != nil {
		return nil, err
	}
	return &st, nil
}

func saveWebState(st webState) error {
	b, _ := json.MarshalIndent(st, "", "  ")
	if err := os.MkdirAll(config.Dir(), 0o700); err != nil {
		return err
	}
	return os.WriteFile(webStatePath(), b, 0o600)
}

func pidAlive(pid int) bool {
	if pid <= 0 {
		return false
	}
	return syscall.Kill(pid, 0) == nil
}

func portListening(port int) bool {
	c, err := net.DialTimeout("tcp", fmt.Sprintf("127.0.0.1:%d", port), 300*time.Millisecond)
	if err != nil {
		return false
	}
	c.Close()
	return true
}

func webDaemonStatus() map[string]any {
	st, _ := loadWebState()
	running := st != nil && pidAlive(st.PID)
	port := 8080
	recvDir := filepath.Join(os.Getenv("HOME"), "Downloads")
	if st != nil {
		port = st.Port
		recvDir = st.RecvDir
	}
	return map[string]any{
		"running": running,
		"url":     fmt.Sprintf("http://127.0.0.1:%d", port),
		"port":    port,
		"recvDir": recvDir,
	}
}

func webDaemonStart(args []string) int {
	listen, recvDir, err := parseWebArgs(args)
	if err != nil {
		return errOut(err)
	}
	_, portStr, err := net.SplitHostPort(listen)
	if err != nil {
		return errOut(fmt.Errorf("bad listen address %q: %w", listen, err))
	}
	port, _ := strconv.Atoi(portStr)

	if st, _ := loadWebState(); st != nil && pidAlive(st.PID) {
		out(webDaemonStatus())
		return 0
	}

	exe, err := os.Executable()
	if err != nil {
		return errOut(err)
	}
	logf, err := os.OpenFile(filepath.Join(config.Dir(), "web.log"), os.O_CREATE|os.O_WRONLY|os.O_APPEND, 0o600)
	if err != nil {
		return errOut(err)
	}
	defer logf.Close()

	cmd := exec.Command(exe, "web", "--listen="+listen, "--recv-dir="+recvDir)
	cmd.SysProcAttr = &syscall.SysProcAttr{Setsid: true}
	cmd.Stdout = logf
	cmd.Stderr = logf
	if err := cmd.Start(); err != nil {
		return errOut(err)
	}
	if err := saveWebState(webState{PID: cmd.Process.Pid, Port: port, RecvDir: recvDir, StartedAt: time.Now().Format(time.RFC3339)}); err != nil {
		return errOut(err)
	}

	deadline := time.Now().Add(4 * time.Second)
	for time.Now().Before(deadline) {
		if pidAlive(cmd.Process.Pid) && portListening(port) {
			out(webDaemonStatus())
			return 0
		}
		time.Sleep(200 * time.Millisecond)
	}
	_ = syscall.Kill(cmd.Process.Pid, syscall.SIGKILL)
	_ = os.Remove(webStatePath())
	return fail("error", "web server failed to start", "see "+filepath.Join(config.Dir(), "web.log"))
}

func webDaemonStop() int {
	st, _ := loadWebState()
	if st != nil && pidAlive(st.PID) {
		_ = syscall.Kill(st.PID, syscall.SIGTERM)
		for i := 0; i < 10; i++ {
			if !pidAlive(st.PID) {
				break
			}
			time.Sleep(200 * time.Millisecond)
		}
		if pidAlive(st.PID) {
			_ = syscall.Kill(st.PID, syscall.SIGKILL)
		}
	}
	_ = os.Remove(webStatePath())
	out(webDaemonStatus())
	return 0
}

// ---- helpers -------------------------------------------------------------

func jsonOut(w http.ResponseWriter, v any) {
	w.Header().Set("Content-Type", "application/json")
	_ = json.NewEncoder(w).Encode(v)
}

func shortToken(t string) string {
	if strings.HasPrefix(t, "tc") && len(t) > 12 {
		return "tc…" + t[len(t)-4:]
	}
	return t
}

// recvRunning reports whether the recv child is still alive.
func (s *webServer) recvRunning() bool {
	s.mu.Lock()
	defer s.mu.Unlock()
	return s.recvCmd != nil && s.recvCmd.Process != nil && s.recvCmd.ProcessState == nil
}

// startRecv launches `tailcat recv <dir>` and waits for its address.
func (s *webServer) startRecv() (string, error) {
	s.mu.Lock()
	if s.recvCmd != nil && s.recvCmd.Process != nil && s.recvCmd.ProcessState == nil {
		addr := s.recvAddr
		s.mu.Unlock()
		return addr, nil
	}
	cmd := exec.Command(tailcatBin(), "recv", s.recvDir)
	cmd.Dir = s.recvDir
	stdout, err := cmd.StdoutPipe()
	if err != nil {
		s.mu.Unlock()
		return "", err
	}
	stderr, err := cmd.StderrPipe()
	if err != nil {
		s.mu.Unlock()
		return "", err
	}
	if err := cmd.Start(); err != nil {
		s.mu.Unlock()
		return "", err
	}
	s.recvCmd = cmd
	s.recvAddr = ""
	s.mu.Unlock()

	// Drain both pipes; the address line may land on stdout or stderr.
	drain := func(r io.Reader) {
		buf := make([]byte, 0, 4096)
		tmp := make([]byte, 1024)
		for {
			n, err := r.Read(tmp)
			if n > 0 {
				buf = append(buf, tmp[:n]...)
				if len(buf) > 65536 {
					buf = buf[len(buf)-4096:]
				}
				if m := addrRe.FindSubmatch(buf); m != nil {
					s.mu.Lock()
					if s.recvAddr == "" {
						s.recvAddr = string(m[1])
					}
					s.mu.Unlock()
				}
			}
			if err != nil {
				return
			}
		}
	}
	go drain(stdout)
	go drain(stderr)
	go func() { _ = cmd.Wait() }()

	deadline := time.Now().Add(15 * time.Second)
	for {
		s.mu.Lock()
		a := s.recvAddr
		s.mu.Unlock()
		if a != "" {
			return a, nil
		}
		if time.Now().After(deadline) {
			return "", fmt.Errorf("no address from tailcat recv (is tailcat installed?)")
		}
		time.Sleep(200 * time.Millisecond)
	}
}

func (s *webServer) stopRecv() {
	s.mu.Lock()
	cmd := s.recvCmd
	s.recvCmd = nil
	s.recvAddr = ""
	s.mu.Unlock()
	if cmd != nil && cmd.Process != nil {
		_ = cmd.Process.Kill()
		_ = cmd.Wait()
	}
}

func (s *webServer) listRecvDir() []recvFile {
	entries, err := os.ReadDir(s.recvDir)
	if err != nil {
		return nil
	}
	var out []recvFile
	for _, e := range entries {
		if e.IsDir() {
			continue
		}
		info, err := e.Info()
		if err != nil {
			continue
		}
		out = append(out, recvFile{
			Name:    e.Name(),
			Size:    info.Size(),
			ModTime: info.ModTime().Format("2006-01-02 15:04"),
		})
	}
	sort.Slice(out, func(i, j int) bool { return out[i].ModTime > out[j].ModTime })
	return out
}

// ---- HTTP handlers --------------------------------------------------------

func (s *webServer) index(w http.ResponseWriter, r *http.Request) {
	w.Header().Set("Content-Type", "text/html; charset=utf-8")
	_, _ = io.WriteString(w, htmlPage)
}

func (s *webServer) apiRecvStart(w http.ResponseWriter, r *http.Request) {
	if r.Method != http.MethodPost {
		jsonOut(w, map[string]string{"error": "POST required"})
		return
	}
	addr, err := s.startRecv()
	if err != nil {
		jsonOut(w, map[string]string{"error": err.Error()})
		return
	}
	jsonOut(w, map[string]any{"running": true, "addr": addr, "short": shortToken(addr)})
}

func (s *webServer) apiRecvStatus(w http.ResponseWriter, r *http.Request) {
	s.mu.Lock()
	addr := s.recvAddr
	s.mu.Unlock()
	jsonOut(w, map[string]any{
		"running": s.recvRunning(),
		"addr":    addr,
		"short":   shortToken(addr),
		"dir":     s.recvDir,
		"files":   s.listRecvDir(),
	})
}

func (s *webServer) apiRecvStop(w http.ResponseWriter, r *http.Request) {
	if r.Method != http.MethodPost {
		jsonOut(w, map[string]string{"error": "POST required"})
		return
	}
	s.stopRecv()
	jsonOut(w, map[string]bool{"running": false})
}

func (s *webServer) apiRecvDownload(w http.ResponseWriter, r *http.Request) {
	name := filepath.Base(r.URL.Query().Get("name"))
	if name == "" || name == "." || name == ".." {
		http.Error(w, "bad name", http.StatusBadRequest)
		return
	}
	p := filepath.Join(s.recvDir, name)
	f, err := os.Open(p)
	if err != nil {
		http.Error(w, "not found", http.StatusNotFound)
		return
	}
	defer f.Close()
	w.Header().Set("Content-Disposition", "attachment; filename=\""+name+"\"")
	_, _ = io.Copy(w, f)
}

func (s *webServer) apiRecvRemove(w http.ResponseWriter, r *http.Request) {
	if r.Method != http.MethodPost {
		jsonOut(w, map[string]string{"error": "POST required"})
		return
	}
	name := filepath.Base(r.URL.Query().Get("name"))
	if name == "" || name == "." || name == ".." {
		jsonOut(w, map[string]string{"error": "bad name"})
		return
	}
	err := os.Remove(filepath.Join(s.recvDir, name))
	jsonOut(w, map[string]any{"ok": err == nil, "error": errString(err)})
}

func (s *webServer) apiSend(w http.ResponseWriter, r *http.Request) {
	if r.Method != http.MethodPost {
		jsonOut(w, map[string]string{"error": "POST required"})
		return
	}
	path := r.FormValue("path")
	target := strings.TrimSpace(r.FormValue("target"))
	if path == "" || target == "" {
		jsonOut(w, map[string]string{"error": "path and target required"})
		return
	}
	if _, err := os.Stat(path); err != nil {
		jsonOut(w, map[string]string{"error": "local file not found: " + path})
		return
	}

	s.sendMu.Lock()
	if s.send != nil && s.send.Status == "running" {
		s.sendMu.Unlock()
		jsonOut(w, map[string]string{"error": "a send is already running"})
		return
	}
	job := &sendJob{Path: path, Target: target, Status: "running", Started: time.Now()}
	s.send = job
	s.sendMu.Unlock()

	go func() {
		// scp-style copy over the tailcat tunnel: tailcat cp <file> <addr>:
		cmd := exec.Command(tailcatBin(), "cp", path, target+":")
		out, err := cmd.CombinedOutput()
		detail := strings.TrimSpace(string(out))
		job.mu.Lock()
		job.Done = time.Now()
		if err != nil {
			job.Status = "error"
			job.Detail = detail + " " + errString(err)
		} else {
			job.Status = "done"
			job.Detail = detail
		}
		job.mu.Unlock()
	}()
	jsonOut(w, map[string]any{"started": true, "path": path, "target": shortToken(target)})
}

func (s *webServer) apiSendStatus(w http.ResponseWriter, r *http.Request) {
	s.sendMu.Lock()
	job := s.send
	s.sendMu.Unlock()
	if job == nil {
		jsonOut(w, map[string]any{"running": false, "job": nil})
		return
	}
	job.mu.Lock()
	defer job.mu.Unlock()
	jsonOut(w, map[string]any{
		"running": job.Status == "running",
		"job": map[string]any{
			"path":   filepath.Base(job.Path),
			"target": shortToken(job.Target),
			"status": job.Status,
			"detail": job.Detail,
			"done":   job.Done.Format("15:04:05"),
		},
	})
}

func errString(err error) string {
	if err == nil {
		return ""
	}
	return err.Error()
}

const htmlPage = `<!DOCTYPE html>
<html lang="en">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width,initial-scale=1">
<title>Tailcat files</title>
<style>
  :root { color-scheme: dark; }
  * { box-sizing: border-box; }
  body { margin: 0; font: 14px/1.5 system-ui, sans-serif; background: #16161a; color: #d4d4d4; }
  .wrap { max-width: 760px; margin: 0 auto; padding: 24px; }
  h1 { font-size: 20px; margin: 0 0 4px; color: #eee; }
  .sub { color: #888; margin-bottom: 20px; font-size: 13px; }
  .tabs { display: flex; gap: 8px; margin-bottom: 16px; }
  .tab { padding: 8px 18px; border-radius: 8px; cursor: pointer; background: #222; color: #aaa; }
  .tab.active { background: #4c8bf5; color: #fff; }
  .card { background: #1d1d22; border: 1px solid #2a2a32; border-radius: 10px; padding: 16px; margin-bottom: 16px; }
  .row { display: flex; gap: 8px; align-items: center; flex-wrap: wrap; }
  input[type=text] { flex: 1; min-width: 200px; background: #111114; border: 1px solid #333; color: #ddd; border-radius: 6px; padding: 8px 10px; font-size: 14px; }
  button { background: #2a2a32; border: 1px solid #3a3a44; color: #ddd; border-radius: 6px; padding: 8px 14px; cursor: pointer; font-size: 14px; }
  button:hover { background: #33333c; }
  button.primary { background: #4c8bf5; border-color: #4c8bf5; color: #fff; }
  button.primary:hover { background: #3d7ae0; }
  button.danger { color: #e07a7a; }
  .addr { font-family: monospace; background: #000; border: 1px solid #333; padding: 10px; border-radius: 6px; word-break: break-all; color: #8be0a0; }
  .status { color: #8be0a0; font-size: 13px; }
  .err { color: #e07a7a; font-size: 13px; }
  table { width: 100%; border-collapse: collapse; }
  th, td { text-align: left; padding: 8px 6px; border-bottom: 1px solid #26262e; font-size: 13px; }
  th { color: #888; font-weight: 500; }
  td .a { color: #7aa7f0; text-decoration: none; margin-right: 10px; }
  .empty { color: #666; font-size: 13px; }
  .hint { color: #777; font-size: 12px; margin-top: 6px; }
</style>
</head>
<body>
<div class="wrap">
  <h1>Tailcat files</h1>
  <div class="sub">Local file-transfer console — drives <code>tailcat recv</code> (receive) and <code>tailcat cp</code> (send) over your own tunnel. Loopback only.</div>

  <div class="tabs">
    <div class="tab active" id="tabRecv" onclick="showTab('recv')">Receive</div>
    <div class="tab" id="tabSend" onclick="showTab('send')">Send</div>
  </div>

  <!-- RECEIVE -->
  <div id="paneRecv">
    <div class="card">
      <div class="row">
        <button id="recvBtn" class="primary" onclick="recvToggle()">Start receiving</button>
        <span id="recvStatus" class="status">idle</span>
      </div>
      <div class="hint" id="recvDirLine"></div>
      <div class="addr" id="recvAddr" style="display:none; margin-top:10px"></div>
      <div class="row" style="margin-top:10px" id="recvCopyRow" hidden>
        <button onclick="copyAddr()">Copy address</button>
        <span class="hint">Send this address to the peer; they run: tailcat cp FILE &lt;addr&gt;:</span>
      </div>
    </div>
    <div class="card">
      <div style="font-weight:600; margin-bottom:8px; color:#ccc">Received files</div>
      <div id="recvFiles"><span class="empty">Nothing here yet.</span></div>
    </div>
  </div>

  <!-- SEND -->
  <div id="paneSend" style="display:none">
    <div class="card">
      <div class="row">
        <input type="text" id="sendPath" placeholder="Local file path, e.g. /home/me/report.pdf">
      </div>
      <div class="row" style="margin-top:10px">
        <input type="text" id="sendTarget" placeholder="Peer recv address (tc…) or DNS name">
        <button class="primary" id="sendBtn" onclick="doSend()">Send</button>
      </div>
      <div id="sendResult" style="margin-top:10px"></div>
      <div class="hint">Peer must have a receiver running: tailcat recv &lt;dir&gt;</div>
    </div>
  </div>
</div>

<script>
var recvAddr = "";
var recvOn = false;
function showTab(name) {
  document.getElementById('tabRecv').classList.toggle('active', name==='recv');
  document.getElementById('tabSend').classList.toggle('active', name==='send');
  document.getElementById('paneRecv').style.display = name==='recv' ? '' : 'none';
  document.getElementById('paneSend').style.display = name==='send' ? '' : 'none';
  if (name==='recv') poll();
}
function el(id){ return document.getElementById(id); }
function esc(s){ var d=document.createElement('div'); d.textContent=s||''; return d.innerHTML; }
function copyAddr(){ if(recvAddr) navigator.clipboard.writeText(recvAddr).then(function(){ flash(); }); }
function flash(){ var b=document.querySelector('#recvCopyRow button'); b.textContent='Copied ✓'; setTimeout(function(){ b.textContent='Copy address'; },1200); }

function recvToggle(){
  if (recvOn) {
    fetch('/api/recv/stop',{method:'POST'}).then(function(){ poll(); });
  } else {
    fetch('/api/recv/start',{method:'POST'}).then(function(r){return r.json();}).then(function(d){
      if (d.error){ el('recvStatus').textContent='Error: '+d.error; return; }
      recvAddr=d.addr; recvOn=true;
      el('recvAddr').textContent=d.addr; el('recvAddr').style.display='';
      el('recvCopyRow').hidden=false;
      poll();
    });
  }
}

function renderRecv(d){
  el('recvStatus').textContent = d.running ? '● receiving' : 'idle';
  el('recvDirLine').textContent = 'Receiving into: ' + d.dir;
  if (d.running && d.addr && !recvOn){ recvAddr=d.addr; recvOn=true; el('recvAddr').textContent=d.addr; el('recvAddr').style.display=''; el('recvCopyRow').hidden=false; }
  el('recvBtn').textContent = d.running ? 'Stop receiving' : 'Start receiving';
  el('recvBtn').className = d.running ? 'danger' : 'primary';
  var box=el('recvFiles');
  if (!d.files || !d.files.length){ box.innerHTML='<span class="empty">Nothing here yet.</span>'; return; }
  var h='<table><tr><th>Name</th><th>Size</th><th>Time</th><th></th></tr>';
  d.files.forEach(function(f){
    h+='<tr><td>'+esc(f.name)+'</td><td>'+fmtSize(f.size)+'</td><td>'+esc(f.modTime)+'</td>'+
       '<td><a class="a" href="/api/recv/dl?name='+encodeURIComponent(f.name)+'">download</a>'+
       '<a class="a" style="color:#e07a7a" href="#" onclick="rmFile(\''+encodeURIComponent(f.name)+'\');return false">delete</a></td></tr>';
  });
  box.innerHTML=h+'</table>';
}
function rmFile(name){ fetch('/api/recv/rm?name='+name,{method:'POST'}).then(function(){ poll(); }); }
function fmtSize(n){ if(n<1024) return n+' B'; if(n<1048576) return (n/1024).toFixed(1)+' KB'; return (n/1048576).toFixed(1)+' MB'; }

function poll(){
  fetch('/api/recv/status').then(function(r){return r.json();}).then(renderRecv).catch(function(){});
  if (sendPolling) pollSend();
}

var sendPolling=false;
function doSend(){
  var path=el('sendPath').value.trim(), target=el('sendTarget').value.trim();
  if(!path||!target){ el('sendResult').innerHTML='<div class="err">Path and target required.</div>'; return; }
  var body=new URLSearchParams(); body.append('path',path); body.append('target',target);
  el('sendBtn').disabled=true; el('sendResult').innerHTML='<div class="status">Sending…</div>';
  sendPolling=true;
  fetch('/api/send',{method:'POST',body:body}).then(function(r){return r.json();}).then(function(d){
    if(d.error){ el('sendResult').innerHTML='<div class="err">'+esc(d.error)+'</div>'; el('sendBtn').disabled=false; sendPolling=false; return; }
    pollSend();
  });
}
function pollSend(){
  fetch('/api/send/status').then(function(r){return r.json();}).then(function(d){
    if(!d.job){ el('sendResult').innerHTML='<span class="empty">No send in progress.</span>'; el('sendBtn').disabled=false; sendPolling=false; return; }
    var j=d.job;
    if(j.status==='running'){ el('sendResult').innerHTML='<div class="status">Sending '+esc(j.path)+' → '+esc(j.target)+'…</div>'; setTimeout(pollSend,1000); }
    else if(j.status==='done'){ el('sendResult').innerHTML='<div class="status">✓ Sent '+esc(j.path)+' → '+esc(j.target)+' ('+esc(j.done)+')</div>'; el('sendBtn').disabled=false; sendPolling=false; }
    else { el('sendResult').innerHTML='<div class="err">✗ Send failed: '+esc(j.detail)+'</div>'; el('sendBtn').disabled=false; sendPolling=false; }
  }).catch(function(){ setTimeout(pollSend,1000); });
}

setInterval(function(){ if(!document.hidden) poll(); }, 2000);
poll();
</script>
</body>
</html>`
