package suite

import (
	"strings"
	"testing"

	"github.com/oyaguma3/aka-mvpset/conformance/av-api/fixture"
)

func statusOf(results []Result) map[string]Status {
	m := map[string]Status{}
	for _, r := range results {
		m[r.ID] = r.Status
	}
	return m
}

func logResults(t *testing.T, results []Result) {
	t.Helper()
	for _, r := range results {
		t.Logf("%s %s %s", r.ID, r.Status, r.Title)
		for _, n := range r.Notes {
			t.Logf("    %s", n)
		}
	}
}

// TestCompliantServer は、契約どおりの偽物ですべての項目が通ることを確かめる。
func TestCompliantServer(t *testing.T) {
	cfg := startFake(t, "")
	results := Run(t.Context(), cfg)
	if len(results) != len(cases) {
		t.Fatalf("結果が %d 件（%d 件を期待）", len(results), len(cases))
	}
	for _, r := range results {
		if r.Status != Pass {
			logResults(t, results)
			t.Fatalf("%s が %s", r.ID, r.Status)
		}
	}
}

// TestBlackBox は、黒箱では鍵を使う項目を行わず、残りが通ることを確かめる。
func TestBlackBox(t *testing.T) {
	cfg := startFake(t, "")
	cfg.BlackBox = true
	cfg.ActiveIMSI = fixture.ActiveSub.IMSI
	cfg.UnknownIMSI = fixture.UnknownIMSI
	got := statusOf(Run(t.Context(), cfg))
	for id, want := range map[string]Status{"C1": Pass, "C2": Skip, "C3": Skip, "C4": Pass, "C5": Skip, "C6": Pass, "C7": Skip, "C8": Pass, "C9": Pass, "C10": Pass, "C11": Pass} {
		if got[id] != want {
			t.Errorf("%s が %s（%s を期待）", id, got[id], want)
		}
	}
}

// TestDetectsBugs は、契約から外れた偽物で、その項目が FAIL になることを確かめる（試験が誤りを見逃さないこと）。
func TestDetectsBugs(t *testing.T) {
	for _, c := range []struct {
		bug, failCase, note string
	}{
		{bugNotFound404, "C6", "登録されていない IMSI"},
		{bugNoCacheControl, "C11", "Cache-Control"},
		{bugAdvanceOnReject, "C6", "SQN が進んだ"},
		{bugWrongPrime, "C3", "ckPrime"},
	} {
		t.Run(c.bug, func(t *testing.T) {
			cfg := startFake(t, c.bug)
			results := Run(t.Context(), cfg)
			for _, r := range results {
				if r.ID != c.failCase {
					continue
				}
				if r.Status != Fail {
					logResults(t, results)
					t.Fatalf("%s が %s（FAIL を期待）", r.ID, r.Status)
				}
				if !strings.Contains(strings.Join(r.Notes, "\n"), c.note) {
					t.Errorf("%s の記録に %q がない: %v", r.ID, c.note, r.Notes)
				}
			}
		})
	}
}

// TestSelectCases は、行う項目を選べることを確かめる。
func TestSelectCases(t *testing.T) {
	cfg := startFake(t, "")
	cfg.Cases = []string{"C2", "C8"}
	results := Run(t.Context(), cfg)
	if len(results) != 2 || results[0].ID != "C2" || results[1].ID != "C8" {
		t.Fatalf("結果が %v", results)
	}
}
