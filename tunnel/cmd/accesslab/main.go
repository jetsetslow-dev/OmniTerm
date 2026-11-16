// accesslab is a contract fake from our reading of cloudflared, not a Cloudflare service.
package main

import (
	"flag"
	"log"
	"net/http"
	"os"
	"time"

	"github.com/jetsetslow-dev/omniterm/tunnel/internal/accessfake"
)

func main() {
	state := flag.String("state", "/state", "fixture TLS directory")
	target := flag.String("target", "direct:2222", "controlled SSH fixture")
	idle := flag.Duration("idle", accessfake.Idle, "close a WebSocket silent for this long")
	flag.Parse()
	id, secret := os.Getenv("OMNITERM_TEST_ACCESS_ID"), os.Getenv("OMNITERM_TEST_ACCESS_SECRET")
	if id == "" || secret == "" {
		log.Fatal("fixture token missing")
	}
	server := &http.Server{Addr: ":443", Handler: accessfake.Handler(*target, id, secret, *idle), ReadHeaderTimeout: 5 * time.Second}
	log.Print("Cloudflare Access contract fixture ready")
	// Never log incoming requests or token material.
	if err := server.ListenAndServeTLS(*state+"/server.crt", *state+"/server.key"); err != nil {
		log.Fatal("fixture TLS listener stopped")
	}
}
