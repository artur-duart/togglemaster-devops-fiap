package main

import (
	"strings"
	"testing"
)

func TestHashAPIKey(t *testing.T) {
	t.Run("deterministico", func(t *testing.T) {
		if hashAPIKey("same-input") != hashAPIKey("same-input") {
			t.Errorf("hashAPIKey nao e deterministico: mesma entrada gerou saidas diferentes")
		}
	})

	t.Run("valor conhecido (golden)", func(t *testing.T) {
		want := "2cf24dba5fb0a30e26e83b2ac5b9e29e1b161e5c1fa7425e73043362938b9824"
		if got := hashAPIKey("hello"); got != want {
			t.Errorf("hashAPIKey(\"hello\") = %s, want %s", got, want)
		}
	})

	t.Run("entradas diferentes geram hashes diferentes", func(t *testing.T) {
		if hashAPIKey("a") == hashAPIKey("b") {
			t.Errorf("entradas diferentes geraram o mesmo hash")
		}
	})
}

func TestGenerateAPIKey(t *testing.T) {
	key, err := generateAPIKey()
	if err != nil {
		t.Fatalf("generateAPIKey retornou erro: %v", err)
	}

	if !strings.HasPrefix(key, "tm_key_") {
		t.Errorf("chave sem prefixo esperado: %s", key)
	}

	if len(key) != 71 {
		t.Errorf("tamanho da chave = %d, want 71", len(key))
	}

	t.Run("duas chamadas sao unicas", func(t *testing.T) {
		key2, _ := generateAPIKey()
		if key == key2 {
			t.Errorf("duas chamadas geraram a mesma chave: aleatoriedade quebrada")
		}
	})
}
