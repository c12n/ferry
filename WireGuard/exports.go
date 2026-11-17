package main

// The C API WireGuardServer.swift calls. One server at a time. Strings Go returns are malloc'd and
// the caller frees them with TetherWGFree. Keys are 32 raw bytes.

/*
#include <stdlib.h>
#include <stdint.h>
*/
import "C"

import (
	"encoding/json"
	"fmt"
	"net/netip"
	"runtime/debug"
	"strings"
	"sync"
	"unsafe"
)

var (
	mu     sync.Mutex
	server *Server
)

func cerr(err error) *C.char {
	if err == nil {
		return nil
	}
	return C.CString(err.Error())
}

// survive turns a panic into an error message. A panic that leaves an exported function would end
// the whole app, not just the WireGuard server. Call it deferred, with the result to set.
func survive(result **C.char) {
	if r := recover(); r != nil {
		*result = C.CString(fmt.Sprint("wireguard: ", r))
	}
}

// TetherWGStart listens on host:port. Returns nil, or an error message.
//
//export TetherWGStart
func TetherWGStart(host *C.char, port C.int, privateKey *C.uint8_t) (result *C.char) {
	defer survive(&result)
	mu.Lock()
	defer mu.Unlock()
	if host == nil || privateKey == nil {
		return C.CString("no address or key")
	}
	if server != nil {
		server.Close()
		server = nil
	}
	addr, err := netip.ParseAddr(C.GoString(host))
	if err != nil {
		return cerr(err)
	}
	var key [32]byte
	copy(key[:], unsafe.Slice((*byte)(privateKey), 32))
	s, err := Start(addr, int(port), key)
	if err != nil {
		return cerr(err)
	}
	server = s
	return nil
}

//export TetherWGStop
func TetherWGStop() {
	mu.Lock()
	defer mu.Unlock()
	if server == nil {
		return
	}
	s := server
	server = nil
	// A panic that leaves here would end the whole app, see survive. There's no error to return.
	defer func() { _ = recover() }()
	s.Close()
}

// TetherWGSetPeers replaces the devices. keys holds count public keys back to back, addresses is
// their tunnel addresses separated by newlines, in the same order.
//
//export TetherWGSetPeers
func TetherWGSetPeers(keys *C.uint8_t, addresses *C.char, count C.int) (result *C.char) {
	defer survive(&result)
	mu.Lock()
	defer mu.Unlock()
	if count > 0 && (keys == nil || addresses == nil) {
		return C.CString("no keys or addresses")
	}
	if server == nil {
		return nil
	}
	var raw []byte
	if count > 0 {
		raw = unsafe.Slice((*byte)(keys), int(count)*32)
	}
	peers, err := parsePeers(raw, C.GoString(addresses))
	if err != nil {
		return cerr(err)
	}
	return cerr(server.SetPeers(peers))
}

// parsePeers pairs 32-byte keys with newline-separated addresses. A count that doesn't match is an
// error, so a device can't be shown as set up while the server leaves it out.
func parsePeers(keys []byte, addresses string) ([]Peer, error) {
	var lines []string
	if addresses != "" {
		lines = strings.Split(addresses, "\n")
	}
	if len(keys) != 32*len(lines) {
		return nil, fmt.Errorf("%d keys but %d addresses", len(keys)/32, len(lines))
	}
	peers := make([]Peer, 0, len(lines))
	seenKeys := map[[32]byte]bool{}
	seenAddrs := map[netip.Addr]bool{}
	for i, line := range lines {
		a, err := netip.ParseAddr(line)
		if err != nil {
			return nil, err
		}
		var key [32]byte
		copy(key[:], keys[i*32:])
		if seenKeys[key] || seenAddrs[a] {
			return nil, fmt.Errorf("device %d repeats a key or address", i+1)
		}
		seenKeys[key], seenAddrs[a] = true, true
		peers = append(peers, Peer{PublicKey: key, Address: a})
	}
	return peers, nil
}

// policyJSON is one device's policy as Swift sends it, see PeerPolicy in server.go.
type policyJSON struct {
	Address     string `json:"address"`
	NoForward   bool   `json:"noForward"`
	Blocked     bool   `json:"blocked"`
	PausedUntil int64  `json:"pausedUntil"`
	DownBps     uint64 `json:"downBps"`
	UpBps       uint64 `json:"upBps"`
}

// TetherWGSetPolicies replaces the devices' forwarding policies: approval, pauses and caps as
// blocked states, and speed limits. policies is a JSON array of policyJSON.
//
//export TetherWGSetPolicies
func TetherWGSetPolicies(policies *C.char) (result *C.char) {
	defer survive(&result)
	mu.Lock()
	defer mu.Unlock()
	if server == nil {
		return nil
	}
	if policies == nil {
		return C.CString("no policies")
	}
	var decoded []policyJSON
	if err := json.Unmarshal([]byte(C.GoString(policies)), &decoded); err != nil {
		return cerr(err)
	}
	list := make([]PeerPolicy, 0, len(decoded))
	for _, p := range decoded {
		addr, err := netip.ParseAddr(p.Address)
		if err != nil {
			return cerr(err)
		}
		list = append(list, PeerPolicy{Address: addr, NoForward: p.NoForward, Blocked: p.Blocked,
			PausedUntil: p.PausedUntil, DownBps: p.DownBps, UpBps: p.UpBps})
	}
	server.SetPolicies(list)
	return nil
}

// TetherWGClosePeer closes a device's open connections at once.
//
//export TetherWGClosePeer
func TetherWGClosePeer(address *C.char) {
	mu.Lock()
	defer mu.Unlock()
	if server == nil || address == nil {
		return
	}
	defer func() { _ = recover() }() // no error to return, see TetherWGStop
	addr, err := netip.ParseAddr(C.GoString(address))
	if err != nil {
		return
	}
	server.ClosePeer(addr)
}

// TetherWGFreeMemory gives memory the GC has freed back to iOS. Swift calls it on a memory warning.
//
//export TetherWGFreeMemory
func TetherWGFreeMemory() { debug.FreeOSMemory() }

// TetherWGStats returns the counters as JSON, or nil when the server isn't running.
//
//export TetherWGStats
func TetherWGStats() *C.char {
	mu.Lock()
	defer mu.Unlock()
	if server == nil {
		return nil
	}
	b, _ := json.Marshal(server.Stats())
	return C.CString(string(b))
}

//export TetherWGFree
func TetherWGFree(p *C.char) { C.free(unsafe.Pointer(p)) }

func main() {}
