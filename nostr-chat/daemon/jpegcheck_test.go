package main

import "testing"

func TestJpegExtFallback(t *testing.T) {
	got := detectContentType("a.jpeg", []byte{0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11})
	t.Logf("detectContentType(a.jpeg, nonguessable) = %q", got)
	if got != "image/jpeg" {
		t.Fatalf("got %q want image/jpeg", got)
	}
}
