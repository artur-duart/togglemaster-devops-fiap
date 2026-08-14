package main

import "testing"

func TestGetDeterministicBucket(t *testing.T) {
	t.Run("deterministico", func(t *testing.T) {
		if getDeterministicBucket("user-x") != getDeterministicBucket("user-x") {
			t.Errorf("mesma entrada gerou buckets diferentes")
		}
	})

	t.Run("dentro da faixa 0-99", func(t *testing.T) {
		for _, in := range []string{"a", "abc", "test", "user-123flag-x", ""} {
			if b := getDeterministicBucket(in); b < 0 || b > 99 {
				t.Errorf("bucket(%q) = %d, fora da faixa 0-99", in, b)
			}
		}
	})

	t.Run("valores conhecidos (golden)", func(t *testing.T) {
		golden := map[string]int{
			"abc":  38,
			"test": 5,
		}
		for in, want := range golden {
			if got := getDeterministicBucket(in); got != want {
				t.Errorf("bucket(%q) = %d, want %d", in, got, want)
			}
		}
	})
}
