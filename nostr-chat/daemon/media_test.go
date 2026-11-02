package main

import (
	"bytes"
	"os"
	"path/filepath"
	"testing"

	"fiatjaf.com/nostr"
)

// Encrypt → write ciphertext → decrypt-in-place must round-trip to the
// original bytes and verify the ox hash.
func TestEncryptDecryptRoundTrip(t *testing.T) {
	dir := t.TempDir()
	src := filepath.Join(dir, "img.png")
	// Real PNG magic bytes so http.DetectContentType sniffs image/png
	// instead of text/plain — detectContentType only falls back to the
	// extension on application/octet-stream.
	data := append([]byte("\x89PNG\r\n\x1a\n"), bytes.Repeat([]byte{0}, 5000)...)
	if err := os.WriteFile(src, data, 0o600); err != nil {
		t.Fatal(err)
	}

	enc, err := encryptFile(src)
	if err != nil {
		t.Fatal(err)
	}
	if enc.Mime != "image/png" {
		t.Fatalf("mime = %q, want image/png", enc.Mime)
	}
	if bytes.Equal(enc.Ciphertext, data) {
		t.Fatal("ciphertext equals plaintext")
	}

	// Simulate the download side: write ciphertext to disk, decrypt in
	// place using the tags a kind-15 rumor would carry.
	dst := filepath.Join(dir, "dl")
	if err := os.WriteFile(dst, enc.Ciphertext, 0o600); err != nil {
		t.Fatal(err)
	}
	tags := nostr.Tags{
		{"encryption-algorithm", "aes-gcm"},
		{"decryption-key", enc.KeyHex},
		{"decryption-nonce", enc.NonceHex},
		{"ox", enc.OxHex},
	}
	if err := decryptFileInPlace(dst, tags); err != nil {
		t.Fatal(err)
	}
	got, _ := os.ReadFile(dst)
	if !bytes.Equal(got, data) {
		t.Fatalf("round-trip mismatch: got %d bytes, want %d", len(got), len(data))
	}
}

func TestDecryptRejectsBadOx(t *testing.T) {
	dir := t.TempDir()
	src := filepath.Join(dir, "x")
	os.WriteFile(src, []byte("hello"), 0o600)
	enc, _ := encryptFile(src)

	dst := filepath.Join(dir, "dl")
	os.WriteFile(dst, enc.Ciphertext, 0o600)
	tags := nostr.Tags{
		{"encryption-algorithm", "aes-gcm"},
		{"decryption-key", enc.KeyHex},
		{"decryption-nonce", enc.NonceHex},
		{"ox", "deadbeef"}, // wrong
	}
	if err := decryptFileInPlace(dst, tags); err == nil {
		t.Fatal("expected ox mismatch error")
	}
}

// detectContentType must trust magic bytes, sniff SVG (http.DetectContentType
// calls it text/xml), and fall back to the extension table when sniffing
// gives up — including for .svg, which Go >=1.23 dropped from the built-in
// mime table unless "mime/builtin" is imported.
func TestDetectContentType(t *testing.T) {
	nonSniffable := []byte("\x00\x01\x02\x03\x04\x05\x06\x07\x08\x09\x0A\x0B")
	tests := []struct {
		name string
		path string
		data []byte
		want string
	}{
		{
			name: "png magic",
			path: "a.png",
			data: append([]byte("\x89PNG\r\n\x1a\n"), bytes.Repeat([]byte{0}, 5000)...),
			want: "image/png",
		},
		{
			name: "jpeg magic",
			path: "a.jpg",
			data: append([]byte("\xFF\xD8\xFF\xE0"), bytes.Repeat([]byte{0}, 5000)...),
			want: "image/jpeg",
		},
		{
			name: "svg content beats xml sniff",
			path: "a.svg",
			data: []byte(`<?xml version="1.0"?><svg xmlns="http://www.w3.org/2000/svg" width="10" height="10"/>`),
			want: "image/svg+xml",
		},
		{
			name: "svg by extension when unsniffable",
			path: "a.svg",
			data: nonSniffable,
			want: "image/svg+xml",
		},
		{
			name: "no extension no magic",
			path: "noext",
			data: nonSniffable,
			want: "application/octet-stream",
		},
	}
	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			if got := detectContentType(tt.path, tt.data); got != tt.want {
				t.Errorf("detectContentType(%q) = %q, want %q", tt.path, got, tt.want)
			}
		})
	}
}
