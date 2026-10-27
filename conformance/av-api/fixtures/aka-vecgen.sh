#!/bin/sh
# 適合試験のクライアント A・B と試験用の加入者を aka-vecgen に入れる。
#
# 使い方: aka-vecgen.sh <出力ディレクトリ> <av-conformance のコマンド> <aka-vecgen のコマンド…>
#   出力ディレクトリには、クライアント A・B の証明書と鍵（client-a.pem、client-b.pem）を書く。
#   av-conformance のコマンドは、試験用の加入者の表（-fixtures）を出すのに使う（表の正本は fixture/fixture.go）。
#   aka-vecgen のコマンドは、Valkey に届く環境変数（VECGEN_VALKEY_ADDR など）を付けて動かせること。
#   例: aka-vecgen.sh out ./av-conformance ./aka-vecgen
#       aka-vecgen.sh out ./av-conformance docker compose exec -T aka-vecgen /aka-vecgen
#
# 加入者の状態（-state）は aka-vecgen の段階 2-1 で足すコマンドの引数。それより前の aka-vecgen では動かない。
# クライアント A のネットワーク名は既定（WLAN）のまま。
set -eu

if [ $# -lt 3 ]; then
	echo "使い方: $0 <出力ディレクトリ> <av-conformance のコマンド> <aka-vecgen のコマンド…>" >&2
	exit 2
fi
out=$1
conformance=$2
shift 2
mkdir -p "$out"

# クライアントを作って登録し、払い出されたクライアントID を返す。
add_client() {
	"$@" client gen-cert -name "av-conformance-$client_name" > "$out/client-$client_name.pem"
	"$@" client add -name "av-conformance-$client_name" -cert - < "$out/client-$client_name.pem" |
		sed -n 's/^client \([0-9][0-9]*\) added.*/\1/p'
}

client_name=a
id_a=$(add_client "$@")
client_name=b
id_b=$(add_client "$@")
if [ -z "$id_a" ] || [ -z "$id_b" ]; then
	echo "クライアントID を読めなかった" >&2
	exit 1
fi
echo "クライアント A: ID $id_a、クライアント B: ID $id_b（B はどの加入者にも許可しない）"

"$conformance" -fixtures > "$out/fixtures.tsv"
while IFS="$(printf '\t')" read -r imsi k opc amf state allow_a; do
	clients=""
	if [ "$allow_a" = "true" ]; then
		clients=$id_a
	fi
	"$@" subscriber add -imsi "$imsi" -ki "$k" -opc "$opc" -amf "$amf" -state "$state" -clients "$clients" < /dev/null
done < "$out/fixtures.tsv"
echo "試験用の加入者を $(wc -l < "$out/fixtures.tsv") 件入れた"
