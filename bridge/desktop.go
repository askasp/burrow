package main

import (
	"errors"
	"os"
	"os/exec"
	"runtime"
	"strings"
)

// pickFolder shows the system's folder picker, saying what Peon may do in
// the folder picked. On Linux it needs zenity or kdialog; canPick says
// whether one is there.
func pickFolder(write bool) (string, error) {
	pickPrompt := "Pick a folder Peon (Burrow) may read"
	if write {
		pickPrompt = "Pick a folder Peon (Burrow) may read and change"
	}
	var cmd *exec.Cmd
	switch runtime.GOOS {
	case "darwin":
		cmd = exec.Command("osascript", "-e", `POSIX path of (choose folder with prompt "`+pickPrompt+`")`)
	case "windows":
		cmd = exec.Command("powershell", "-NoProfile", "-STA", "-Command",
			`Add-Type -AssemblyName System.Windows.Forms; `+
				`$d = New-Object System.Windows.Forms.FolderBrowserDialog; `+
				`$d.Description = '`+pickPrompt+`'; `+
				`if ($d.ShowDialog() -eq 'OK') { $d.SelectedPath }`)
	default:
		if path, err := exec.LookPath("zenity"); err == nil {
			cmd = exec.Command(path, "--file-selection", "--directory", "--title="+pickPrompt)
		} else if path, err := exec.LookPath("kdialog"); err == nil {
			home, _ := os.UserHomeDir()
			cmd = exec.Command(path, "--getexistingdirectory", home, "--title", pickPrompt)
		} else {
			return "", errors.New("no folder picker here (install zenity), or run: burrow-bridge allow FOLDER")
		}
	}

	out, err := cmd.Output()
	path := strings.TrimSpace(string(out))
	if path == "" {
		// Every picker exits non-zero, or prints nothing, when cancelled.
		return "", errCancelled
	}
	if err != nil {
		return "", err
	}
	return path, nil
}

func canPick() bool {
	switch runtime.GOOS {
	case "darwin", "windows":
		return true
	default:
		_, zenity := exec.LookPath("zenity")
		_, kdialog := exec.LookPath("kdialog")
		return zenity == nil || kdialog == nil
	}
}

// openBrowser opens url in the default browser, if there is one.
func openBrowser(url string) {
	var cmd *exec.Cmd
	switch runtime.GOOS {
	case "darwin":
		cmd = exec.Command("open", url)
	case "windows":
		cmd = exec.Command("rundll32", "url.dll,FileProtocolHandler", url)
	default:
		cmd = exec.Command("xdg-open", url)
	}
	if cmd.Start() == nil {
		go cmd.Wait()
	}
}
