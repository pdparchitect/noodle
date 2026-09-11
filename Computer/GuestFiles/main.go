// Noodle's file transport runs only inside the Linux guest. Standard library only.
package main

import (
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"os"
	"os/signal"
	"path/filepath"
	"strconv"
	"strings"
	"syscall"
	"unsafe"
)

type entry struct {
	Name     string `json:"name"`
	Kind     string `json:"kind"`
	Size     int64  `json:"size"`
	Modified int64  `json:"modified"`
	Version  string `json:"version"`
}

func metadata(info os.FileInfo) entry {
	kind := "other"
	if info.Mode().IsRegular() {
		kind = "file"
	}
	if info.IsDir() {
		kind = "directory"
	}
	if info.Mode()&os.ModeSymlink != 0 {
		kind = "symlink"
	}
	s := info.Sys().(*syscall.Stat_t)
	return entry{info.Name(), kind, info.Size(), info.ModTime().Unix(), fmt.Sprintf("%d:%d:%d:%d:%d", s.Dev, s.Ino, info.Size(), info.ModTime().UnixNano(), s.Ctim.Nsec)}
}

func path(value string) (string, error) {
	if !filepath.IsAbs(value) || strings.ContainsRune(value, 0) {
		return "", errors.New("invalid absolute path")
	}
	return filepath.Clean(value), nil
}

// O_NONBLOCK prevents a file swapped for a FIFO from hanging at open; fstat
// validates the opened object, rather than trusting an earlier directory entry.
func regular(name, version string, limit int64) (*os.File, error) {
	fd, err := syscall.Open(name, syscall.O_RDONLY|syscall.O_NOFOLLOW|syscall.O_NONBLOCK|syscall.O_CLOEXEC, 0)
	if err != nil {
		return nil, err
	}
	f := os.NewFile(uintptr(fd), name)
	info, err := f.Stat()
	if err == nil && (!info.Mode().IsRegular() || info.Size() < 0 || info.Size() > limit) {
		err = errors.New("file cannot be previewed or transferred")
	}
	if err == nil && version != "" && metadata(info).Version != version {
		err = errors.New("file changed; refresh and try again")
	}
	if err != nil {
		f.Close()
		return nil, err
	}
	return f, nil
}

// Atomic no-replace publication, including directories. No check-then-rename race.
func rename(old, new string) error {
	a, err := syscall.BytePtrFromString(old)
	if err != nil {
		return err
	}
	b, err := syscall.BytePtrFromString(new)
	if err != nil {
		return err
	}
	_, _, errno := syscall.Syscall6(syscall.SYS_RENAMEAT2, ^uintptr(99), uintptr(unsafe.Pointer(a)), ^uintptr(99), uintptr(unsafe.Pointer(b)), 1, 0)
	if errno != 0 {
		return errno
	}
	return nil
}

func write(name string, source io.Reader, size int64) error {
	f, err := os.CreateTemp(filepath.Dir(name), ".noodle-upload-")
	if err != nil {
		return err
	}
	defer os.Remove(f.Name())
	defer f.Close()
	// A cancelled host operation terminates this helper; remove unpublished bytes.
	stop := make(chan os.Signal, 1)
	signal.Notify(stop, syscall.SIGTERM, syscall.SIGINT)
	defer signal.Stop(stop)
	done := make(chan struct{})
	defer close(done)
	go func() {
		select {
		case <-stop:
			os.Remove(f.Name())
			os.Exit(1)
		case <-done:
		}
	}()
	n, err := io.Copy(f, io.LimitReader(source, size+1))
	if err != nil {
		return err
	}
	if n != size {
		return errors.New("incomplete or oversized transfer")
	}
	if err = f.Sync(); err != nil {
		return err
	}
	if err = f.Close(); err != nil {
		return err
	}
	return rename(f.Name(), name)
}

func run(args []string) error {
	if len(args) < 2 {
		return errors.New("missing operation or path")
	}
	name, err := path(args[1])
	if err != nil {
		return err
	}
	switch args[0] {
	case "list":
		f, err := os.Open(name)
		if err != nil {
			return err
		}
		defer f.Close()
		items, err := f.ReadDir(5001)
		if err != nil && err != io.EOF {
			return err
		}
		if len(items) > 5000 {
			return errors.New("folder exceeds the 5,000-item browsing limit")
		}
		entries := make([]entry, 0, len(items))
		for _, item := range items {
			info, err := item.Info()
			if err == nil {
				entries = append(entries, metadata(info))
			}
		}
		return json.NewEncoder(os.Stdout).Encode(entries)
	case "read", "copy":
		if len(args) != 4 {
			return errors.New("missing file version or limit/destination")
		}
		limit := int64(8 << 30)
		if args[0] == "read" {
			limit, err = strconv.ParseInt(args[3], 10, 64)
			if err != nil || limit < 0 || limit > 8<<30 {
				return errors.New("invalid transfer limit")
			}
		}
		f, err := regular(name, args[2], limit)
		if err != nil {
			return err
		}
		defer f.Close()
		info, err := f.Stat()
		if err != nil {
			return err
		}
		if args[0] == "copy" {
			dest, err := path(args[3])
			if err != nil {
				return err
			}
			return write(dest, f, info.Size())
		}
		n, err := io.Copy(os.Stdout, io.LimitReader(f, limit+1))
		if err != nil {
			return err
		}
		after, err := f.Stat()
		if err != nil {
			return err
		}
		if n != info.Size() || metadata(after).Version != metadata(info).Version {
			return errors.New("file changed during transfer")
		}
		return nil
	case "write":
		if len(args) != 3 {
			return errors.New("missing transfer size")
		}
		size, err := strconv.ParseInt(args[2], 10, 64)
		if err != nil || size < 0 || size > 8<<30 {
			return errors.New("invalid transfer size")
		}
		return write(name, os.Stdin, size)
	case "mkdir":
		return os.Mkdir(name, 0755)
	case "rename":
		if len(args) != 3 {
			return errors.New("missing destination")
		}
		dest, err := path(args[2])
		if err != nil {
			return err
		}
		return rename(name, dest)
	case "remove":
		if name == "/" {
			return errors.New("cannot remove root")
		}
		return os.Remove(name) // Never recursive; symlinks themselves are removed.
	default:
		return errors.New("unsupported operation")
	}
}

func main() {
	if err := run(os.Args[1:]); err != nil {
		fmt.Fprintln(os.Stderr, err)
		os.Exit(1)
	}
}
