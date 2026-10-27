package main

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"net/http"
	"os"
	"runtime"
	"strings"
	"time"

	"github.com/coder/websocket"
)

// Burrow closes the link with this code when the computer was removed there.
const closeRemoved = websocket.StatusCode(4001)

var errRemoved = errors.New("Burrow removed this computer. Run burrow-bridge login to pair it again")

// run keeps this computer linked to Burrow, pairing it first if needed,
// and reconnects whenever the link drops.
func run(args []string) error {
	cfg, err := loadConfig()
	if err != nil {
		return err
	}
	if cfg.Token == "" || (len(args) > 0 && serverURL(args, cfg) != cfg.Server) {
		if err := login(args); err != nil {
			return err
		}
		if cfg, err = loadConfig(); err != nil {
			return err
		}
	}
	if len(cfg.Folders) == 0 {
		fmt.Println("Peon can't see any folder yet. Share one with Add folder… in Burrow, or: burrow-bridge allow ~/Documents")
	}

	wait := time.Second
	for {
		started := time.Now()
		err := serve(cfg)
		if errors.Is(err, errRemoved) {
			return err
		}
		if time.Since(started) > time.Minute {
			wait = time.Second
		}
		fmt.Fprintf(os.Stderr, "Lost Burrow (%v). Trying again in %s.\n", err, wait)
		time.Sleep(wait)
		wait = min(wait*2, 30*time.Second)
	}
}

// serve is one connection: it says hello, then runs Burrow's calls, each
// in its own goroutine, until the link drops.
func serve(cfg *Config) error {
	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()

	conn, resp, err := websocket.Dial(ctx, socketURL(cfg.Server), &websocket.DialOptions{
		HTTPHeader: http.Header{
			"Authorization": {"Bearer " + cfg.Token},
			"User-Agent":    {"burrow-bridge/" + version},
		},
	})
	if resp != nil && resp.StatusCode == http.StatusUnauthorized {
		return errRemoved
	}
	if err != nil {
		return err
	}
	defer conn.CloseNow()
	conn.SetReadLimit(32 << 20)

	folders := cfg.Folders
	err = send(ctx, conn, map[string]any{
		"type":    "hello",
		"os":      runtime.GOOS,
		"arch":    runtime.GOARCH,
		"version": version,
		"folders": folders,
		"pick":    canPick(),
	})
	if err != nil {
		return err
	}
	fmt.Printf("Connected to %s as %q.\n", cfg.Server, cfg.Name)

	go keepAlive(ctx, conn)
	go watchFolders(ctx, conn, folders)

	for {
		_, data, err := conn.Read(ctx)
		if err != nil {
			if websocket.CloseStatus(err) == closeRemoved {
				return errRemoved
			}
			return err
		}
		var msg struct {
			Type   string          `json:"type"`
			ID     int64           `json:"id"`
			Method string          `json:"method"`
			Params json.RawMessage `json:"params"`
		}
		if json.Unmarshal(data, &msg) != nil || msg.Type != "call" {
			continue
		}
		go func() {
			result, err := call(msg.Method, msg.Params)
			reply := map[string]any{"type": "reply", "id": msg.ID}
			if err != nil {
				reply["error"] = err.Error()
			} else {
				reply["result"] = result
			}
			logCall(msg.Method, msg.Params, err)
			send(ctx, conn, reply)
		}()
	}
}

func send(ctx context.Context, conn *websocket.Conn, msg any) error {
	data, err := json.Marshal(msg)
	if err != nil {
		return err
	}
	return conn.Write(ctx, websocket.MessageText, data)
}

// keepAlive pings Burrow, so proxies keep the link open and a dead one is
// noticed; a ping that gets no answer closes it (and run reconnects).
func keepAlive(ctx context.Context, conn *websocket.Conn) {
	ticker := time.NewTicker(25 * time.Second)
	defer ticker.Stop()
	for {
		select {
		case <-ctx.Done():
			return
		case <-ticker.C:
			pingCtx, cancel := context.WithTimeout(ctx, 15*time.Second)
			err := conn.Ping(pingCtx)
			cancel()
			if err != nil {
				conn.Close(websocket.StatusGoingAway, "no pong")
				return
			}
		}
	}
}

// watchFolders tells Burrow when the shared folders change here (say, by a
// `burrow-bridge allow` in another terminal).
func watchFolders(ctx context.Context, conn *websocket.Conn, sent []Folder) {
	last, _ := json.Marshal(sent)
	ticker := time.NewTicker(2 * time.Second)
	defer ticker.Stop()
	for {
		select {
		case <-ctx.Done():
			return
		case <-ticker.C:
			configMu.Lock()
			cfg, err := loadConfig()
			configMu.Unlock()
			if err != nil {
				continue
			}
			now, _ := json.Marshal(cfg.Folders)
			if string(now) != string(last) {
				if send(ctx, conn, map[string]any{"type": "folders", "folders": cfg.Folders}) == nil {
					last = now
				}
			}
		}
	}
}

func socketURL(server string) string {
	switch {
	case strings.HasPrefix(server, "https://"):
		server = "wss://" + strings.TrimPrefix(server, "https://")
	case strings.HasPrefix(server, "http://"):
		server = "ws://" + strings.TrimPrefix(server, "http://")
	}
	return server + "/bridge/socket"
}

// logCall prints what Peon did here, so the person at the computer can follow.
func logCall(method string, params json.RawMessage, err error) {
	var p map[string]any
	json.Unmarshal(params, &p)
	what := method
	for _, key := range []string{"path", "from", "to", "name", "text"} {
		if v, ok := p[key].(string); ok && v != "" {
			what += " " + v
		}
	}
	line := time.Now().Format("15:04:05") + "  " + what
	if err != nil {
		line += "  (refused: " + err.Error() + ")"
	}
	fmt.Println(line)
}
