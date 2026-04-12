package main

// launcher — Genreport service manager + single-port reverse proxy.
//
// On startup it:
//   1. Reads APP_PORT from genreport.conf (written by configwriter).
//   2. Starts the .NET API and Go service as child processes.
//   3. Listens on :APP_PORT and reverse-proxies inbound traffic:
//        /api/*  →  .NET API      (localhost:5001)
//        /hub/*  →  .NET SignalR  (localhost:5001)
//        /go/*   →  Go service    (localhost:12334)
//        /*      →  React static  ({install_dir}/web)
//
// Internal ports are NEVER exposed to the user — they are hardcoded constants.

import (
	"bufio"
	"context"
	"log"
	"net/http"
	"net/http/httputil"
	"net/url"
	"os"
	"os/exec"
	"os/signal"
	"path/filepath"
	"runtime"
	"strings"
	"syscall"
	"time"
)

// ── Internal service ports (hardcoded — never user-facing) ────────────────────
const (
	internalDotnetPort = "5001"
	internalGoPort     = "12334"
)

const defaultAppPort = "2905"

func main() {
	dir := installDir()
	appPort := readAppPort(filepath.Join(dir, "genreport.conf"))

	log.Printf("[genreport] launcher v1 starting — http://localhost:%s", appPort)

	// ── Start child processes ─────────────────────────────────────────────────
	children := startServices(dir)

	// Give services time to bind before accepting traffic
	log.Println("[genreport] waiting for services to initialise...")
	time.Sleep(3 * time.Second)

	// ── Reverse proxy mux ─────────────────────────────────────────────────────
	mux := http.NewServeMux()

	dotnetProxy := newReverseProxy("http://localhost:" + internalDotnetPort)
	goProxy     := newReverseProxy("http://localhost:" + internalGoPort)

	mux.Handle("/api/", dotnetProxy)                                                      // .NET REST API
	mux.Handle("/hub/", dotnetProxy)                                                      // .NET SignalR hubs
	mux.Handle("/go/",  http.StripPrefix("/go", goProxy))                                 // Go service
	mux.Handle("/",     http.FileServer(http.Dir(filepath.Join(dir, "web"))))             // React SPA

	srv := &http.Server{
		Addr:         ":" + appPort,
		Handler:      mux,
		ReadTimeout:  60 * time.Second,
		WriteTimeout: 120 * time.Second,
	}

	// ── Graceful shutdown ─────────────────────────────────────────────────────
	quit := make(chan os.Signal, 1)
	signal.Notify(quit, syscall.SIGINT, syscall.SIGTERM)

	go func() {
		<-quit
		log.Println("[genreport] shutdown signal received")

		ctx, cancel := context.WithTimeout(context.Background(), 10*time.Second)
		defer cancel()
		srv.Shutdown(ctx)

		stopAll(children)
	}()

	log.Printf("[genreport] listening on http://localhost:%s", appPort)
	if err := srv.ListenAndServe(); err != nil && err != http.ErrServerClosed {
		log.Fatalf("[genreport] server error: %v", err)
	}
}

// ── Service management ────────────────────────────────────────────────────────

func startServices(dir string) []*exec.Cmd {
	var cmds []*exec.Cmd

	// .NET API — launcher sets ASPNETCORE_URLS so the API never needs to know
	// the external port.
	dotnetDll := filepath.Join(dir, "dotnet", "Genreport.Api.dll")
	dotnetCmd := exec.Command(dotnetBin(dir), dotnetDll)
	dotnetCmd.Env = append(os.Environ(),
		"ASPNETCORE_URLS=http://localhost:"+internalDotnetPort,
		"ASPNETCORE_ENVIRONMENT=Production",
	)
	dotnetCmd.Stdout = os.Stdout
	dotnetCmd.Stderr = os.Stderr

	// Go service — reads its own .env for DB, SMTP, R2 etc.
	goServiceBin := filepath.Join(dir, "go", goServiceBinName())
	goCmd := exec.Command(goServiceBin)
	goCmd.Dir = filepath.Join(dir, "go")
	goCmd.Stdout = os.Stdout
	goCmd.Stderr = os.Stderr

	for _, cmd := range []*exec.Cmd{dotnetCmd, goCmd} {
		if err := cmd.Start(); err != nil {
			log.Printf("[genreport] warning: could not start %s: %v", cmd.Path, err)
			continue
		}
		log.Printf("[genreport] started %s (pid %d)", filepath.Base(cmd.Path), cmd.Process.Pid)
		cmds = append(cmds, cmd)
	}

	return cmds
}

func stopAll(cmds []*exec.Cmd) {
	for _, cmd := range cmds {
		if cmd.Process == nil {
			continue
		}
		log.Printf("[genreport] stopping %s (pid %d)", filepath.Base(cmd.Path), cmd.Process.Pid)
		if runtime.GOOS == "windows" {
			cmd.Process.Kill()
		} else {
			cmd.Process.Signal(syscall.SIGTERM)
		}
	}
}

// dotnetBin returns the path to the dotnet runtime, preferring a bundled copy.
func dotnetBin(dir string) string {
	bundled := filepath.Join(dir, "dotnet", "dotnet")
	if runtime.GOOS == "windows" {
		bundled += ".exe"
	}
	if _, err := os.Stat(bundled); err == nil {
		return bundled
	}
	// Fall back to system dotnet
	if runtime.GOOS == "windows" {
		return "dotnet.exe"
	}
	return "dotnet"
}

func goServiceBinName() string {
	if runtime.GOOS == "windows" {
		return "goservice.exe"
	}
	return "goservice"
}

// ── Reverse proxy ─────────────────────────────────────────────────────────────

func newReverseProxy(target string) http.Handler {
	u, _ := url.Parse(target)
	proxy := httputil.NewSingleHostReverseProxy(u)
	proxy.ErrorHandler = func(w http.ResponseWriter, r *http.Request, err error) {
		log.Printf("[genreport] proxy error %s: %v", r.URL.Path, err)
		http.Error(w, `{"error":"service temporarily unavailable"}`, http.StatusServiceUnavailable)
	}
	return proxy
}

// ── Config ────────────────────────────────────────────────────────────────────

// installDir resolves the directory containing the launcher executable.
func installDir() string {
	exe, err := os.Executable()
	if err != nil {
		return "."
	}
	return filepath.Dir(exe)
}

// readAppPort reads APP_PORT from genreport.conf (key=value format).
// Falls back to defaultAppPort if the file is missing or the key is absent.
func readAppPort(confPath string) string {
	f, err := os.Open(confPath)
	if err != nil {
		log.Printf("[genreport] genreport.conf not found, using default port %s", defaultAppPort)
		return defaultAppPort
	}
	defer f.Close()

	scanner := bufio.NewScanner(f)
	for scanner.Scan() {
		line := strings.TrimSpace(scanner.Text())
		if strings.HasPrefix(line, "#") || !strings.Contains(line, "=") {
			continue
		}
		parts := strings.SplitN(line, "=", 2)
		if strings.TrimSpace(parts[0]) == "APP_PORT" {
			val := strings.Trim(strings.TrimSpace(parts[1]), `"`)
			if val != "" {
				return val
			}
		}
	}
	return defaultAppPort
}
