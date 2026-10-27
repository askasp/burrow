// Burrow Bridge lets Peon, in Burrow's Computer chats, work on this
// computer: on the files in the folders you allow, nothing else. It
// connects out to Burrow over a websocket, so no port opens here, and it
// checks every path itself, so Burrow can't reach past those folders.
package main

import (
	"errors"
	"fmt"
	"os"
	"strings"
)

// Set at build time by the Burrow the binary comes from:
// -ldflags "-X main.server=https://… -X main.version=…".
var (
	server  = ""
	version = "dev"
)

const usageText = `Burrow Bridge: lets Peon work on files on this computer, in folders you allow.

Usage:
  burrow-bridge                     connect to Burrow (logs in the first time)
  burrow-bridge login [URL]         pair this computer with a Burrow
  burrow-bridge allow FOLDER        let Peon read FOLDER
  burrow-bridge allow --write FOLDER
                                    let Peon read and change FOLDER
  burrow-bridge forget FOLDER       stop sharing FOLDER
  burrow-bridge folders             list the folders Peon may use
  burrow-bridge logout              unpair this computer
  burrow-bridge version
`

func main() {
	args := os.Args[1:]
	cmd := "run"
	if len(args) > 0 && !strings.HasPrefix(args[0], "-") {
		cmd, args = args[0], args[1:]
	}

	var err error
	switch cmd {
	case "run":
		err = run(args)
	case "login":
		err = login(args)
	case "logout":
		err = logout()
	case "allow":
		err = allow(args)
	case "forget":
		err = forget(args)
	case "folders":
		err = printFolders()
	case "version":
		fmt.Println(version)
	case "help":
		fmt.Print(usageText)
	default:
		fmt.Fprint(os.Stderr, usageText)
		os.Exit(2)
	}

	if err != nil {
		fmt.Fprintln(os.Stderr, "burrow-bridge:", err)
		os.Exit(1)
	}
}

func allow(args []string) error {
	write := false
	var paths []string
	for _, a := range args {
		if a == "--write" || a == "-w" {
			write = true
		} else {
			paths = append(paths, a)
		}
	}
	if len(paths) != 1 {
		return errors.New("usage: burrow-bridge allow [--write] FOLDER")
	}

	cfg, err := loadConfig()
	if err != nil {
		return err
	}
	folder, err := cfg.addFolder(paths[0], write)
	if err != nil {
		return err
	}
	if err := cfg.save(); err != nil {
		return err
	}
	fmt.Printf("Peon may now %s %s\n", access(folder), folder.Path)
	return nil
}

func forget(args []string) error {
	if len(args) != 1 {
		return errors.New("usage: burrow-bridge forget FOLDER")
	}
	cfg, err := loadConfig()
	if err != nil {
		return err
	}
	if !cfg.removeFolder(args[0]) {
		return fmt.Errorf("%s isn't shared", args[0])
	}
	return cfg.save()
}

func printFolders() error {
	cfg, err := loadConfig()
	if err != nil {
		return err
	}
	if len(cfg.Folders) == 0 {
		fmt.Println("No folders yet. Add one: burrow-bridge allow ~/Documents")
	}
	for _, f := range cfg.Folders {
		fmt.Printf("%-12s %s\n", access(f), f.Path)
	}
	return nil
}

func logout() error {
	cfg, err := loadConfig()
	if err != nil {
		return err
	}
	cfg.Token, cfg.Computer, cfg.Name = "", 0, ""
	if err := cfg.save(); err != nil {
		return err
	}
	fmt.Println("Logged out. Remove the computer in Burrow too, under Computers.")
	return nil
}

func access(f Folder) string {
	if f.Write {
		return "read+write"
	}
	return "read"
}
