// nativedemo is a test/demo binary that runs one end of a native file
// transfer, mirroring how the real product runs: the receiver is a separate
// long-running process. Used by the hermetic e2e tests (which start a local
// DERP and exec this binary for both endpoints) and for manual demos.
package main

import (
	"context"
	"encoding/json"
	"flag"
	"fmt"
	"log"
	"os"
	"os/signal"
	"path/filepath"
	"syscall"
	"time"

	"tailscale.com/types/key"

	"omarchy-tailcat/tailcat"
)

func main() {
	if len(os.Args) < 2 {
		log.Fatal("usage: nativedemo recv|send ...")
	}
	switch os.Args[1] {
	case "recv":
		recv()
	case "send":
		send()
	default:
		log.Fatalf("unknown subcommand %q", os.Args[1])
	}
}

// recv starts a native file receiver, prints its conn blob as JSON on stdout,
// and auto-accepts offers into outdir. Blocks until killed.
func recv() {
	fs := flag.NewFlagSet("recv", flag.ExitOnError)
	derpMapURL := fs.String("derp-map-url", "", "DERP map URL")
	outdir := fs.String("outdir", ".", "destination directory")
	fs.Parse(os.Args[2:])

	recv, blob, err := tailcat.StartReceiver(context.Background(), key.NodePrivate{},
		tailcat.ReceiverOptions{DERPMapURL: *derpMapURL},
		tailcat.ReceiveOptions{
			Decide: func(in tailcat.IncomingFile) (string, bool) {
				fmt.Fprintf(os.Stderr, "offer %s (%d bytes) from %s -> %s\n", in.Name, in.Size, in.Sender, filepath.Join(*outdir, in.Name))
				return filepath.Join(*outdir, in.Name), true
			},
		})
	if err != nil {
		log.Fatalf("StartReceiver: %v", err)
	}
	defer recv.Close()
	out := map[string]string{"blob": blob}
	b, _ := json.Marshal(out)
	fmt.Println(string(b))
	os.Stdout.Sync()

	sig := make(chan os.Signal, 1)
	signal.Notify(sig, syscall.SIGINT, syscall.SIGTERM)
	<-sig
}

// send dials the receiver named by blob and sends the given file.
func send() {
	fs := flag.NewFlagSet("send", flag.ExitOnError)
	derpMapURL := fs.String("derp-map-url", "", "DERP map URL")
	name := fs.String("name", "", "display name (default: base of path)")
	fs.Parse(os.Args[2:])
	args := fs.Args()
	if len(args) < 2 {
		log.Fatal("usage: nativedemo send <blob> <file>")
	}
	blob, path := args[0], args[1]

	ctx, cancel := context.WithTimeout(context.Background(), 60*time.Second)
	defer cancel()
	res, err := tailcat.SendFileToToken(ctx, blob, *derpMapURL, path, *name, nil)
	out := map[string]any{"ok": err == nil}
	if err != nil {
		out["error"] = err.Error()
	} else {
		out["bytes"] = res.Bytes
		out["sha256"] = res.SHA256
	}
	b, _ := json.Marshal(out)
	fmt.Println(string(b))
	if err != nil {
		os.Exit(1)
	}
}
