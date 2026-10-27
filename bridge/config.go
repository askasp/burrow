package main

import (
	"encoding/json"
	"errors"
	"fmt"
	"io/fs"
	"os"
	"path/filepath"
	"sync"
)

// Folder is one folder Peon may use; Write lets it change files there too.
type Folder struct {
	Path  string `json:"path"`
	Write bool   `json:"write"`
}

// Config lives in the user's config folder (~/.config/burrow-bridge on
// Linux, ~/Library/Application Support/burrow-bridge on a Mac,
// %AppData%\burrow-bridge on Windows), readable only by the user.
type Config struct {
	Server   string   `json:"server"`
	Token    string   `json:"token,omitempty"`
	Computer int      `json:"computer,omitempty"`
	Name     string   `json:"name,omitempty"`
	Folders  []Folder `json:"folders"`
}

// The running bridge and a `burrow-bridge allow` in another terminal both
// write the file; within this process, one at a time.
var configMu sync.Mutex

func configPath() (string, error) {
	if p := os.Getenv("BURROW_BRIDGE_CONFIG"); p != "" {
		return p, nil
	}
	dir, err := os.UserConfigDir()
	if err != nil {
		return "", err
	}
	return filepath.Join(dir, "burrow-bridge", "config.json"), nil
}

func loadConfig() (*Config, error) {
	path, err := configPath()
	if err != nil {
		return nil, err
	}
	cfg := &Config{Folders: []Folder{}}
	data, err := os.ReadFile(path)
	if errors.Is(err, fs.ErrNotExist) {
		return cfg, nil
	}
	if err != nil {
		return nil, err
	}
	if err := json.Unmarshal(data, cfg); err != nil {
		return nil, fmt.Errorf("%s: %w", path, err)
	}
	if cfg.Folders == nil {
		cfg.Folders = []Folder{}
	}
	return cfg, nil
}

func (c *Config) save() error {
	path, err := configPath()
	if err != nil {
		return err
	}
	if err := os.MkdirAll(filepath.Dir(path), 0o700); err != nil {
		return err
	}
	data, err := json.MarshalIndent(c, "", "  ")
	if err != nil {
		return err
	}
	tmp := path + ".tmp"
	if err := os.WriteFile(tmp, data, 0o600); err != nil {
		return err
	}
	return os.Rename(tmp, path)
}

// addFolder shares an existing folder, or changes how it's shared.
func (c *Config) addFolder(path string, write bool) (Folder, error) {
	abs, err := filepath.Abs(expandHome(path))
	if err != nil {
		return Folder{}, err
	}
	info, err := os.Stat(abs)
	if err != nil {
		return Folder{}, err
	}
	if !info.IsDir() {
		return Folder{}, fmt.Errorf("%s is not a folder", abs)
	}

	folder := Folder{Path: abs, Write: write}
	for i, f := range c.Folders {
		if samePath(f.Path, abs) {
			c.Folders[i] = folder
			return folder, nil
		}
	}
	c.Folders = append(c.Folders, folder)
	return folder, nil
}

func (c *Config) removeFolder(path string) bool {
	abs, err := filepath.Abs(expandHome(path))
	if err != nil {
		return false
	}
	for i, f := range c.Folders {
		if samePath(f.Path, abs) {
			c.Folders = append(c.Folders[:i], c.Folders[i+1:]...)
			return true
		}
	}
	return false
}
