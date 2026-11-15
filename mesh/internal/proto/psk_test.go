package proto

import (
	"bytes"
	"crypto/rand"
	"testing"

	"golang.org/x/crypto/curve25519"
)

func TestSealOpenPSKRoundtrip(t *testing.T) {
	hubPriv := make([]byte, 32)
	_, _ = rand.Read(hubPriv)
	hubPub, err := curve25519.X25519(hubPriv, curve25519.Basepoint)
	if err != nil {
		t.Fatal(err)
	}
	psk := make([]byte, 32)
	_, _ = rand.Read(psk)
	sealed, err := SealPSKForHub(psk, hubPub)
	if err != nil {
		t.Fatal(err)
	}
	got, err := OpenPSKFromHub(sealed, hubPriv)
	if err != nil {
		t.Fatal(err)
	}
	if !bytes.Equal(got, psk) {
		t.Fatal("psk mismatch after roundtrip")
	}
	// Wrong key must fail.
	other := make([]byte, 32)
	_, _ = rand.Read(other)
	if _, err := OpenPSKFromHub(sealed, other); err == nil {
		t.Fatal("expected failure with wrong hub key")
	}
}
