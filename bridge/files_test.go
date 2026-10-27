package main

import (
	"encoding/json"
	"os"
	"path/filepath"
	"strings"
	"testing"
)

// setup shares two folders, one read-only and one read-write, in a config
// of its own.
func setup(t *testing.T) (ro, rw string) {
	t.Helper()
	dir := t.TempDir()
	t.Setenv("BURROW_BRIDGE_CONFIG", filepath.Join(dir, "config.json"))
	ro, rw = filepath.Join(dir, "ro"), filepath.Join(dir, "rw")
	os.MkdirAll(ro, 0o755)
	os.MkdirAll(rw, 0o755)
	os.WriteFile(filepath.Join(ro, "a.txt"), []byte("one\ntwo\nthree\n"), 0o644)
	os.WriteFile(filepath.Join(dir, "secret.txt"), []byte("no"), 0o644)

	cfg, _ := loadConfig()
	cfg.addFolder(ro, false)
	cfg.addFolder(rw, true)
	if err := cfg.save(); err != nil {
		t.Fatal(err)
	}
	return ro, rw
}

func callTool(t *testing.T, method string, params map[string]any) (map[string]any, error) {
	t.Helper()
	raw, _ := json.Marshal(params)
	result, err := call(method, raw)
	if err != nil {
		return nil, err
	}
	data, _ := json.Marshal(result)
	var out map[string]any
	json.Unmarshal(data, &out)
	return out, nil
}

func TestReadsInsideSharedFolders(t *testing.T) {
	ro, _ := setup(t)
	out, err := callTool(t, "read", map[string]any{"path": filepath.Join(ro, "a.txt"), "offset": 2, "limit": 1})
	if err != nil {
		t.Fatal(err)
	}
	if out["content"] != "two\n" {
		t.Fatalf("content = %q", out["content"])
	}
}

func TestRefusesPathsOutside(t *testing.T) {
	ro, _ := setup(t)
	for _, path := range []string{
		filepath.Join(filepath.Dir(ro), "secret.txt"),
		filepath.Join(ro, "..", "secret.txt"),
		"secret.txt",
	} {
		if _, err := callTool(t, "read", map[string]any{"path": path}); err == nil {
			t.Errorf("read %s: want refused", path)
		}
	}
}

func TestRefusesSymlinksOut(t *testing.T) {
	ro, _ := setup(t)
	link := filepath.Join(ro, "out")
	if err := os.Symlink(filepath.Dir(ro), link); err != nil {
		t.Skip("no symlinks here")
	}
	if _, err := callTool(t, "read", map[string]any{"path": filepath.Join(link, "secret.txt")}); err == nil {
		t.Fatal("read through a symlink out: want refused")
	}
}

func TestWritesOnlyWhereAllowed(t *testing.T) {
	ro, rw := setup(t)
	if _, err := callTool(t, "write", map[string]any{"path": filepath.Join(ro, "b.txt"), "content": "x"}); err == nil ||
		!strings.Contains(err.Error(), "read-only") {
		t.Fatalf("write in read-only folder: err = %v", err)
	}

	path := filepath.Join(rw, "new", "b.txt")
	if _, err := callTool(t, "write", map[string]any{"path": path, "content": "hello world"}); err != nil {
		t.Fatal(err)
	}
	if _, err := callTool(t, "edit", map[string]any{"path": path, "old": "world", "new": "Peon"}); err != nil {
		t.Fatal(err)
	}
	if data, _ := os.ReadFile(path); string(data) != "hello Peon" {
		t.Fatalf("file = %q", data)
	}
}

func TestDeletesNeitherSharedFoldersNorFullOnes(t *testing.T) {
	_, rw := setup(t)
	os.WriteFile(filepath.Join(rw, "c.txt"), []byte("c"), 0o644)
	if _, err := callTool(t, "delete", map[string]any{"path": rw}); err == nil {
		t.Fatal("deleting the shared folder: want refused")
	}
	if _, err := callTool(t, "delete", map[string]any{"path": filepath.Join(rw, "c.txt")}); err != nil {
		t.Fatal(err)
	}
}

func TestSearchFindsNamesAndText(t *testing.T) {
	ro, _ := setup(t)
	out, err := callTool(t, "search", map[string]any{"path": ro, "name": "*.txt", "text": "TWO"})
	if err != nil {
		t.Fatal(err)
	}
	matches := out["matches"].([]any)
	if len(matches) != 1 || matches[0].(map[string]any)["line"] != 2.0 {
		t.Fatalf("matches = %v", matches)
	}
}

func TestServerURL(t *testing.T) {
	cfg := &Config{Server: "https://paired.example"}
	cases := map[string][]string{
		"https://paired.example": nil,
		"https://given.example":  {"given.example/"},
		"http://localhost:4000":  {"--server", "http://localhost:4000"},
	}
	for want, args := range cases {
		if got := serverURL(args, cfg); got != want {
			t.Errorf("serverURL(%v) = %q, want %q", args, got, want)
		}
	}
}
