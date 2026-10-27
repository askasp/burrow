package main

import (
	"bytes"
	"encoding/json"
	"errors"
	"fmt"
	"net/http"
	"os"
	"runtime"
	"strings"
	"time"
)

// login pairs this computer with a Burrow, like `gh auth login`: Burrow
// shows a short code, the person approves it there (logged in), and this
// computer gets a token of its own, which Burrow can take back.
func login(args []string) error {
	configMu.Lock()
	defer configMu.Unlock()
	cfg, err := loadConfig()
	if err != nil {
		return err
	}
	srv := serverURL(args, cfg)
	if srv == "" {
		return errors.New("which Burrow? Run: burrow-bridge login https://your.burrow")
	}

	name, _ := os.Hostname()
	var start struct {
		DeviceCode string `json:"device_code"`
		UserCode   string `json:"user_code"`
		URL        string `json:"url"`
		Interval   int    `json:"interval"`
		ExpiresIn  int    `json:"expires_in"`
	}
	body := map[string]any{"name": name, "os": runtime.GOOS, "arch": runtime.GOARCH, "version": version}
	if _, err := postJSON(srv+"/bridge/pair", body, &start); err != nil {
		return fmt.Errorf("couldn't reach %s: %w", srv, err)
	}

	fmt.Printf("\nApprove this computer in Burrow:\n\n    %s\n\nBurrow shows the code %s there too.\n\n", start.URL, start.UserCode)
	openBrowser(start.URL)

	interval := time.Duration(max(start.Interval, 1)) * time.Second
	deadline := time.Now().Add(time.Duration(start.ExpiresIn) * time.Second)
	for time.Now().Before(deadline) {
		time.Sleep(interval)
		var done struct {
			Token    string `json:"token"`
			Computer int    `json:"computer"`
			Name     string `json:"name"`
		}
		status, err := postJSON(srv+"/bridge/pair/token", map[string]any{"device_code": start.DeviceCode}, &done)
		switch {
		case err != nil && status == 0:
			// Burrow didn't answer this time; ask again.
		case status == http.StatusAccepted:
		case status == http.StatusOK:
			cfg.Server, cfg.Token, cfg.Computer, cfg.Name = srv, done.Token, done.Computer, done.Name
			if err := cfg.save(); err != nil {
				return err
			}
			fmt.Printf("Paired as %q.\n", done.Name)
			return nil
		default:
			return fmt.Errorf("pairing ended: %w. Run burrow-bridge login again", err)
		}
	}
	return errors.New("nobody approved the code in time. Run burrow-bridge login again")
}

// serverURL is the Burrow to use: the one named on the command line, else
// $BURROW_SERVER, else the one this computer is paired with, else the one
// the binary came from.
func serverURL(args []string, cfg *Config) string {
	srv := ""
	for i, a := range args {
		switch {
		case strings.HasPrefix(a, "--server="):
			srv = strings.TrimPrefix(a, "--server=")
		case a == "--server" && i+1 < len(args):
			srv = args[i+1]
		case !strings.HasPrefix(a, "-") && (i == 0 || args[i-1] != "--server"):
			srv = a
		}
	}
	for _, s := range []string{os.Getenv("BURROW_SERVER"), cfg.Server, server} {
		if srv == "" {
			srv = s
		}
	}
	if srv == "" {
		return ""
	}
	if !strings.Contains(srv, "://") {
		srv = "https://" + srv
	}
	return strings.TrimRight(srv, "/")
}

// postJSON posts body and decodes a 2xx answer into out. On any other
// status the error is Burrow's message.
func postJSON(url string, body, out any) (int, error) {
	data, err := json.Marshal(body)
	if err != nil {
		return 0, err
	}
	req, err := http.NewRequest(http.MethodPost, url, bytes.NewReader(data))
	if err != nil {
		return 0, err
	}
	req.Header.Set("Content-Type", "application/json")
	req.Header.Set("User-Agent", "burrow-bridge/"+version)
	resp, err := (&http.Client{Timeout: 20 * time.Second}).Do(req)
	if err != nil {
		return 0, err
	}
	defer resp.Body.Close()

	if resp.StatusCode/100 != 2 {
		var e struct {
			Error string `json:"error"`
		}
		if json.NewDecoder(resp.Body).Decode(&e) != nil || e.Error == "" {
			e.Error = resp.Status
		}
		return resp.StatusCode, errors.New(e.Error)
	}
	if resp.StatusCode == http.StatusNoContent || resp.StatusCode == http.StatusAccepted {
		return resp.StatusCode, nil
	}
	return resp.StatusCode, json.NewDecoder(resp.Body).Decode(out)
}
