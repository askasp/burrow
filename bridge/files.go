package main

import (
	"bytes"
	"encoding/json"
	"errors"
	"fmt"
	"io/fs"
	"os"
	"path/filepath"
	"runtime"
	"strings"
	"time"
)

const (
	maxRead      = 2 << 20
	maxEntries   = 2000
	maxMatches   = 200
	defaultLines = 2000
)

// Folders Peon's searches and deep listings don't walk into.
var skipDirs = map[string]bool{".git": true, "node_modules": true, "_build": true, "deps": true}

var errCancelled = errors.New("the folder picker was closed without picking a folder")

// call runs one tool Burrow asks for. Every path goes through resolve, which
// keeps it inside the folders the config allows (read again each call, so a
// `burrow-bridge allow` in another terminal counts at once).
func call(method string, params json.RawMessage) (any, error) {
	configMu.Lock()
	cfg, err := loadConfig()
	configMu.Unlock()
	if err != nil {
		return nil, err
	}

	switch method {
	case "folders":
		return map[string]any{"folders": cfg.Folders}, nil
	case "list":
		var p struct {
			Path  string `json:"path"`
			Depth int    `json:"depth"`
		}
		if err := decode(params, &p); err != nil {
			return nil, err
		}
		return list(cfg, p.Path, p.Depth)
	case "read":
		var p struct {
			Path   string `json:"path"`
			Offset int    `json:"offset"`
			Limit  int    `json:"limit"`
		}
		if err := decode(params, &p); err != nil {
			return nil, err
		}
		return read(cfg, p.Path, p.Offset, p.Limit)
	case "search":
		var p struct {
			Path string `json:"path"`
			Name string `json:"name"`
			Text string `json:"text"`
		}
		if err := decode(params, &p); err != nil {
			return nil, err
		}
		return search(cfg, p.Path, p.Name, p.Text)
	case "write":
		var p struct {
			Path    string `json:"path"`
			Content string `json:"content"`
		}
		if err := decode(params, &p); err != nil {
			return nil, err
		}
		return write(cfg, p.Path, p.Content)
	case "edit":
		var p struct {
			Path string `json:"path"`
			Old  string `json:"old"`
			New  string `json:"new"`
			All  bool   `json:"all"`
		}
		if err := decode(params, &p); err != nil {
			return nil, err
		}
		return edit(cfg, p.Path, p.Old, p.New, p.All)
	case "move":
		var p struct {
			From string `json:"from"`
			To   string `json:"to"`
		}
		if err := decode(params, &p); err != nil {
			return nil, err
		}
		return move(cfg, p.From, p.To)
	case "delete":
		var p struct {
			Path string `json:"path"`
		}
		if err := decode(params, &p); err != nil {
			return nil, err
		}
		return remove(cfg, p.Path)
	case "pick_folder":
		var p struct {
			Write bool `json:"write"`
		}
		if err := decode(params, &p); err != nil {
			return nil, err
		}
		return pick(p.Write)
	case "forget_folder":
		var p struct {
			Path string `json:"path"`
		}
		if err := decode(params, &p); err != nil {
			return nil, err
		}
		return forgetFolder(p.Path)
	default:
		return nil, fmt.Errorf("unknown method %q (this Burrow Bridge is version %s)", method, version)
	}
}

func decode(params json.RawMessage, v any) error {
	if len(params) == 0 {
		return nil
	}
	return json.Unmarshal(params, v)
}

// resolve turns a path from Peon into the real path it names (symlinks
// followed) and the allowed folder that holds it, or refuses it.
func resolve(cfg *Config, path string, needWrite bool) (string, Folder, error) {
	if path == "" {
		return "", Folder{}, errors.New("no path given")
	}
	path = expandHome(path)
	if !filepath.IsAbs(path) {
		return "", Folder{}, fmt.Errorf("%s: use a full path, like %s", path, example(cfg))
	}
	real, err := realPath(filepath.Clean(path))
	if err != nil {
		return "", Folder{}, err
	}

	for _, f := range cfg.Folders {
		root, err := realPath(f.Path)
		if err != nil || !within(real, root) {
			continue
		}
		if needWrite && !f.Write {
			return "", Folder{}, fmt.Errorf("%s is read-only for Peon on this computer", f.Path)
		}
		return real, f, nil
	}

	if len(cfg.Folders) == 0 {
		return "", Folder{}, errors.New("this computer shares no folders yet")
	}
	return "", Folder{}, fmt.Errorf("%s is outside the folders this computer shares (%s)", path, folderList(cfg))
}

// realPath follows symlinks in the part of path that exists and adds the
// rest, so a file that doesn't exist yet is checked by where it would go.
func realPath(path string) (string, error) {
	rest := ""
	cur := path
	for {
		real, err := filepath.EvalSymlinks(cur)
		if err == nil {
			return filepath.Join(real, rest), nil
		}
		if !errors.Is(err, fs.ErrNotExist) {
			return "", err
		}
		parent := filepath.Dir(cur)
		if parent == cur {
			return path, nil
		}
		rest = filepath.Join(filepath.Base(cur), rest)
		cur = parent
	}
}

func within(path, root string) bool {
	if caseInsensitive() {
		path, root = strings.ToLower(path), strings.ToLower(root)
	}
	rel, err := filepath.Rel(root, path)
	if err != nil {
		return false
	}
	return rel != ".." && !strings.HasPrefix(rel, ".."+string(filepath.Separator)) && !filepath.IsAbs(rel)
}

func samePath(a, b string) bool {
	if caseInsensitive() {
		return strings.EqualFold(filepath.Clean(a), filepath.Clean(b))
	}
	return filepath.Clean(a) == filepath.Clean(b)
}

// Windows and (by default) macOS file systems ignore case.
func caseInsensitive() bool { return runtime.GOOS == "windows" || runtime.GOOS == "darwin" }

func expandHome(path string) string {
	if path == "~" || strings.HasPrefix(path, "~/") || strings.HasPrefix(path, `~\`) {
		if home, err := os.UserHomeDir(); err == nil {
			return filepath.Join(home, path[1:])
		}
	}
	return path
}

func folderList(cfg *Config) string {
	paths := make([]string, len(cfg.Folders))
	for i, f := range cfg.Folders {
		paths[i] = f.Path
	}
	return strings.Join(paths, ", ")
}

func example(cfg *Config) string {
	if len(cfg.Folders) > 0 {
		return filepath.Join(cfg.Folders[0].Path, "notes.txt")
	}
	return "~/Documents/notes.txt"
}

type entry struct {
	Path     string    `json:"path"`
	Type     string    `json:"type"`
	Size     int64     `json:"size,omitempty"`
	Modified time.Time `json:"modified"`
}

// list lists a folder, depth levels down (1 to 4). Without a path it lists
// the shared folders.
func list(cfg *Config, path string, depth int) (any, error) {
	if path == "" {
		return map[string]any{"folders": cfg.Folders}, nil
	}
	dir, _, err := resolve(cfg, path, false)
	if err != nil {
		return nil, err
	}
	depth = min(max(depth, 1), 4)

	entries := []entry{}
	truncated := false
	err = filepath.WalkDir(dir, func(p string, d fs.DirEntry, err error) error {
		if err != nil || p == dir {
			return err
		}
		rel, _ := filepath.Rel(dir, p)
		level := strings.Count(rel, string(filepath.Separator)) + 1
		if len(entries) >= maxEntries {
			truncated = true
			return fs.SkipAll
		}
		entries = append(entries, toEntry(rel, d))
		if d.IsDir() && (level >= depth || skipDirs[d.Name()]) {
			return fs.SkipDir
		}
		return nil
	})
	if err != nil {
		return nil, err
	}
	return map[string]any{"path": dir, "entries": entries, "truncated": truncated}, nil
}

func toEntry(rel string, d fs.DirEntry) entry {
	e := entry{Path: rel, Type: "file"}
	switch {
	case d.Type()&fs.ModeSymlink != 0:
		e.Type = "link"
	case d.IsDir():
		e.Type = "dir"
	}
	if info, err := d.Info(); err == nil {
		e.Modified = info.ModTime().UTC()
		if !d.IsDir() {
			e.Size = info.Size()
		}
	}
	return e
}

// read returns a text file's lines from offset (1-based), at most limit.
func read(cfg *Config, path string, offset, limit int) (any, error) {
	file, _, err := resolve(cfg, path, false)
	if err != nil {
		return nil, err
	}
	info, err := os.Stat(file)
	if err != nil {
		return nil, err
	}
	if info.IsDir() {
		return nil, fmt.Errorf("%s is a folder: list it instead", file)
	}
	if info.Size() > maxRead*8 {
		return nil, fmt.Errorf("%s is %d MB, too big to read", file, info.Size()>>20)
	}
	data, err := os.ReadFile(file)
	if err != nil {
		return nil, err
	}
	if binary(data) {
		return map[string]any{"path": file, "binary": true, "size": info.Size()}, nil
	}

	lines := strings.SplitAfter(string(data), "\n")
	offset = max(offset, 1)
	if limit <= 0 {
		limit = defaultLines
	}
	from := min(offset-1, len(lines))
	to := min(from+limit, len(lines))
	content := strings.Join(lines[from:to], "")
	truncated := to < len(lines)
	if len(content) > maxRead {
		content, truncated = content[:maxRead], true
	}
	return map[string]any{
		"path":      file,
		"content":   content,
		"from_line": from + 1,
		"lines":     len(lines),
		"truncated": truncated,
	}, nil
}

func binary(data []byte) bool { return bytes.IndexByte(data[:min(len(data), 8000)], 0) >= 0 }

type match struct {
	Path string `json:"path"`
	Line int    `json:"line,omitempty"`
	Text string `json:"text,omitempty"`
}

// search finds files under path whose name matches the glob name, and,
// with text, the lines that have it (case doesn't matter).
func search(cfg *Config, path, name, text string) (any, error) {
	if name == "" && text == "" {
		return nil, errors.New("give a name pattern, a text, or both")
	}
	dir, _, err := resolve(cfg, path, false)
	if err != nil {
		return nil, err
	}
	if _, err := filepath.Match(name, ""); err != nil {
		return nil, fmt.Errorf("name pattern %q: %w", name, err)
	}
	needle := strings.ToLower(text)

	matches := []match{}
	truncated := false
	err = filepath.WalkDir(dir, func(p string, d fs.DirEntry, err error) error {
		if err != nil {
			return nil
		}
		if d.IsDir() {
			if p != dir && skipDirs[d.Name()] {
				return fs.SkipDir
			}
			return nil
		}
		if name != "" {
			if ok, _ := filepath.Match(name, d.Name()); !ok {
				return nil
			}
		}
		rel, _ := filepath.Rel(dir, p)
		if text == "" {
			matches = append(matches, match{Path: rel})
		} else {
			matches = append(matches, grep(p, rel, needle)...)
		}
		if len(matches) >= maxMatches {
			matches, truncated = matches[:maxMatches], true
			return fs.SkipAll
		}
		return nil
	})
	if err != nil {
		return nil, err
	}
	return map[string]any{"path": dir, "matches": matches, "truncated": truncated}, nil
}

func grep(path, rel, needle string) []match {
	info, err := os.Stat(path)
	if err != nil || info.Size() > maxRead {
		return nil
	}
	data, err := os.ReadFile(path)
	if err != nil || binary(data) {
		return nil
	}
	var found []match
	for i, line := range strings.Split(string(data), "\n") {
		if strings.Contains(strings.ToLower(line), needle) {
			found = append(found, match{Path: rel, Line: i + 1, Text: clip(strings.TrimSpace(line), 200)})
		}
	}
	return found
}

func clip(s string, n int) string {
	if len(s) <= n {
		return s
	}
	return s[:n] + "…"
}

func write(cfg *Config, path, content string) (any, error) {
	file, _, err := resolve(cfg, path, true)
	if err != nil {
		return nil, err
	}
	mode, created := fs.FileMode(0o644), true
	if info, err := os.Stat(file); err == nil {
		if info.IsDir() {
			return nil, fmt.Errorf("%s is a folder", file)
		}
		mode, created = info.Mode().Perm(), false
	}
	if err := os.MkdirAll(filepath.Dir(file), 0o755); err != nil {
		return nil, err
	}
	if err := os.WriteFile(file, []byte(content), mode); err != nil {
		return nil, err
	}
	return map[string]any{"path": file, "bytes": len(content), "created": created}, nil
}

// edit replaces old with new in a file: old must be there exactly once,
// unless all is set.
func edit(cfg *Config, path, old, new string, all bool) (any, error) {
	if old == "" {
		return nil, errors.New("old text is empty")
	}
	file, _, err := resolve(cfg, path, true)
	if err != nil {
		return nil, err
	}
	info, err := os.Stat(file)
	if err != nil {
		return nil, err
	}
	data, err := os.ReadFile(file)
	if err != nil {
		return nil, err
	}
	text := string(data)
	n := strings.Count(text, old)
	switch {
	case n == 0:
		return nil, fmt.Errorf("the old text isn't in %s", file)
	case n > 1 && !all:
		return nil, fmt.Errorf("the old text is in %s %d times: give more of it, or set all", file, n)
	}
	if err := os.WriteFile(file, []byte(strings.ReplaceAll(text, old, new)), info.Mode().Perm()); err != nil {
		return nil, err
	}
	return map[string]any{"path": file, "replaced": n}, nil
}

func move(cfg *Config, from, to string) (any, error) {
	src, _, err := resolve(cfg, from, true)
	if err != nil {
		return nil, err
	}
	dst, _, err := resolve(cfg, to, true)
	if err != nil {
		return nil, err
	}
	if _, err := os.Lstat(dst); err == nil {
		return nil, fmt.Errorf("%s already exists", dst)
	}
	if err := os.MkdirAll(filepath.Dir(dst), 0o755); err != nil {
		return nil, err
	}
	if err := os.Rename(src, dst); err != nil {
		return nil, err
	}
	return map[string]any{"from": src, "to": dst}, nil
}

// remove deletes a file, or a folder only when it's empty.
func remove(cfg *Config, path string) (any, error) {
	file, folder, err := resolve(cfg, path, true)
	if err != nil {
		return nil, err
	}
	if root, err := realPath(folder.Path); err == nil && samePath(file, root) {
		return nil, fmt.Errorf("%s is a shared folder itself", file)
	}
	if err := os.Remove(file); err != nil {
		if info, statErr := os.Stat(file); statErr == nil && info.IsDir() {
			return nil, fmt.Errorf("%s is a folder that isn't empty", file)
		}
		return nil, err
	}
	return map[string]any{"path": file}, nil
}

// pick asks the person at this computer for a folder to share.
func pick(write bool) (any, error) {
	path, err := pickFolder(write)
	if err != nil {
		return nil, err
	}
	configMu.Lock()
	defer configMu.Unlock()
	cfg, err := loadConfig()
	if err != nil {
		return nil, err
	}
	folder, err := cfg.addFolder(path, write)
	if err != nil {
		return nil, err
	}
	if err := cfg.save(); err != nil {
		return nil, err
	}
	return map[string]any{"folder": folder, "folders": cfg.Folders}, nil
}

func forgetFolder(path string) (any, error) {
	configMu.Lock()
	defer configMu.Unlock()
	cfg, err := loadConfig()
	if err != nil {
		return nil, err
	}
	if !cfg.removeFolder(path) {
		return nil, fmt.Errorf("%s isn't shared", path)
	}
	if err := cfg.save(); err != nil {
		return nil, err
	}
	return map[string]any{"folders": cfg.Folders}, nil
}
