// scaleload は段階 6 の規模の試験（概要 §18.13 の S6-3〜S6-5、確認事項 L6-1〜L6-9）の道具。README.md を参照。
//
//	scaleload csv -seed <種> -kind vecgen|radius -from <番号> -to <番号>     一括投入の CSV を標準出力へ
//	scaleload serve -aps <aps.json> -seed <種> -out <ディレクトリ> [...]      AP をつないで操作の口で待つ（負荷をかける）
//	scaleload report <out のディレクトリ>                                      まとめを表にする
//	scaleload imsi <番号>                                                     番号の IMSI
package main

import (
	"bufio"
	"encoding/json"
	"flag"
	"fmt"
	"os"
	"strconv"
	"time"
)

func main() {
	if len(os.Args) < 2 {
		usage()
	}
	var err error
	switch os.Args[1] {
	case "csv":
		fs := flag.NewFlagSet("csv", flag.ExitOnError)
		seed := fs.String("seed", "", "種のファイル（32 バイト）")
		kind := fs.String("kind", "", "vecgen か radius")
		from := fs.Int("from", 0, "IMSI の番号の始め")
		to := fs.Int("to", 0, "IMSI の番号の終わり（含む）")
		_ = fs.Parse(os.Args[2:])
		if *from <= 0 || *to < *from || *to-*from >= 10000 {
			err = fmt.Errorf("番号の範囲は 1 以上、1 回 1 万件まで（一括投入の上限）")
			break
		}
		var s []byte
		if s, err = readSeed(*seed); err != nil {
			break
		}
		w := bufio.NewWriter(os.Stdout)
		if err = writeCSV(w, *kind, s, *from, *to); err == nil {
			err = w.Flush()
		}
	case "serve":
		fs := flag.NewFlagSet("serve", flag.ExitOnError)
		aps := fs.String("aps", "aps.json", "AP の一覧")
		seed := fs.String("seed", "seed.bin", "種のファイル（32 バイト）")
		out := fs.String("out", "out", "記録を書くディレクトリ（windows.jsonl・summary.json）")
		listen := fs.String("listen", "127.0.0.1:9900", "操作の口（手元だけ）")
		dial := fs.Float64("dial-rate", 20, "接続を張る毎秒の数")
		timeout := fs.Duration("timeout", 10*time.Second, "1 回の要求の応答を待つ時間")
		maxIn := fs.Int("max-inflight", 4000, "同時に進める認証の上限")
		interim := fs.Duration("interim", 10*time.Minute, "セッションの Interim の間隔")
		_ = fs.Parse(os.Args[2:])
		err = serve(*aps, *seed, *out, *listen, *dial, *timeout, *interim, *maxIn)
	case "report":
		if len(os.Args) < 3 {
			usage()
		}
		err = report(os.Args[2])
	case "imsi":
		if len(os.Args) < 3 {
			usage()
		}
		var n int
		if n, err = strconv.Atoi(os.Args[2]); err == nil {
			fmt.Println(imsiOf(n))
		}
	default:
		usage()
	}
	if err != nil {
		fmt.Fprintln(os.Stderr, "scaleload:", err)
		os.Exit(1)
	}
}

func usage() {
	fmt.Fprintln(os.Stderr, "使い方: scaleload csv|serve|report|imsi ...（verify/scale/README.md）")
	os.Exit(2)
}

// report は summary.json を表にする（遅延は秒）。
func report(dir string) error {
	b, err := os.ReadFile(dir + "/summary.json")
	if err != nil {
		return err
	}
	var ls []labelSummary
	if err := json.Unmarshal(b, &ls); err != nil {
		return err
	}
	fmt.Printf("%-10s %8s %8s %8s %6s %6s %6s %6s %6s %7s %7s %7s %7s %7s %7s %7s\n",
		"場面", "秒", "始めた", "Accept", "Reject", "時間切", "切断", "誤り", "始めず", "TPS", "p50", "p95", "p99", "最大", "acct送", "acct失")
	for _, l := range ls {
		c := l.Counts
		fmt.Printf("%-10s %8.0f %8d %8d %6d %6d %6d %6d %6d %7.2f %7.3f %7.3f %7.3f %7.3f %7d %7d\n",
			l.Label, l.Seconds, c.Started, c.Accept, c.Reject, c.Timeout, c.Closed, c.Error, c.SkipNoConn+c.SkipLimit+c.SkipBusy,
			l.TPS, l.Latency.P50, l.Latency.P95, l.Latency.P99, l.Latency.Max, c.AcctSent, c.AcctTimeout+c.AcctError)
	}
	return nil
}
