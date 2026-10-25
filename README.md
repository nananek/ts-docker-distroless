# tailscale-distroless

Tailscale の nightly ビルドを `gcr.io/distroless/static` に載せ、
ghcr.io へ毎日 push するイメージ。

- base: `gcr.io/distroless/static` (shell なし)
- Tailscale: 最新の `ghcr.io/tailscale/tailscale:unstable-vX.Y.Z`
- root で実行する (nonroot 版はない)
- Tailscale SSH は seccomp で開始できない
- userspace networking のみ

## nightly の扱い

Tailscale は `nightly` というタグを publish していない。main からの nightly は
`ghcr.io/tailscale/tailscale:unstable-vX.Y.Z` として並ぶ。`:unstable` は更新が
遅れることがあるので使わない。

`scripts/latest-unstable-tag.sh` が GHCR のタグを列挙し、`unstable-v*` の最新を返す。
`Dockerfile` の `TAILSCALE_IMAGE` はデフォルトを持たない。`make image` と nightly
workflow が必ずタグを渡すので、固定バージョンに落ちることはない。

nightly workflow は毎日 03:17 UTC に走り、次のタグを push する。

- `nightly`
- `nightly-YYYYMMDD`
- `unstable-vX.Y.Z`
- `sha-xxxxxxx`

## なぜ root か

tailscaled は state と local API socket を root で所有し、ネットワーク設定も
root 前提で扱う。nonroot 版は作らない。

## Tailscale SSH を成立させない仕組み

2 層で止めている。

1. イメージ内の `/usr/local/bin/sandbox-exec` が `containerboot` の前に
   `PR_SET_NO_NEW_PRIVS` と seccomp を設定する。`setgroups`、`setuid`、
   `setgid`、`setreuid`、`setregid`、`setresuid`、`setresgid`、`setfsuid`、
   `setfsgid`、`ptrace`、`process_vm_readv`、`process_vm_writev`、`kcmp`、
   `pidfd_getfd`、`process_madvise` を EPERM にする。
   `ssh/tailssh/incubator.go` の `doDropPrivileges` は root セッションでも
   `setgroups` を必ず呼ぶ。`tailscale up --ssh` が成功してサーバが待ち受けても、
   SSH セッションの子プロセスは権限を落とせず開始しない。
2. `seccomp/tailscale.json` は Docker の既定 allowlist から `ptrace`、
   `process_vm_*`、`mount`、`unshare`、`bpf` などを削った追加の防御層。
   `--security-opt seccomp=...` で適用する。

`setgroups`、`setgid`、`setuid` は 2 のプロファイルには入れていない。runc は
`no-new-privileges` が無い場合、`setupUser()` より前に seccomp を設定するため、
ここでこれらを塞ぐとコンテナ自体が起動しない。`sandbox-exec` は runc の後に
動くので、SSH 用の 3 つはそちらで塞いでいる。

distroless 側には `/bin/sh` も `/sbin/nologin` もない。root の login shell は
`/etc/passwd` 上 `/sbin/nologin` だが、そのバイナリ自体が存在しない。

`tailscale up --ssh` 自体は成功する。セッションだけが張れない。

## 使い方

```bash
docker run -d --name tailscale \
  --restart unless-stopped \
  -e TS_AUTHKEY=tskey-auth-... \
  -v tailscale-state:/var/lib/tailscale \
  --cap-drop=ALL \
  --read-only \
  --tmpfs /tmp:rw,noexec,nosuid,size=64m \
  --tmpfs /var/run/tailscale:rw,noexec,nosuid,size=1m \
  --security-opt no-new-privileges:true \
  --security-opt seccomp=./seccomp/tailscale.json \
  ghcr.io/OWNER/ts-docker-distroless:nightly
```

`--security-opt seccomp=` はホスト上のファイルを読む。リポジトリの
`seccomp/tailscale.json` を指定する。イメージ内にも
`/etc/tailscale/seccomp.json` として入っているが、それ自体は自動適用されない。

CLI は shell がないので、バイナリを直接指定する。

```bash
docker exec tailscale /usr/local/bin/tailscale --socket=/tmp/tailscaled.sock status
docker exec tailscale /usr/local/bin/tailscale --socket=/tmp/tailscaled.sock ip
```

Compose は `compose.yaml` を参照。アプリを sidecar にする場合は、アプリ側に
`network_mode: "service:tailscale"` を指定する。

`--cap-drop=ALL` は userspace networking の基本動作には不要な capability を
落としている。`tailscale serve` で 1024 番未満を待ち受ける場合だけ
`--cap-add=NET_BIND_SERVICE` を足す。

`TS_AUTHKEY` は環境変数なので `docker inspect` や `/proc/1/environ` から見える。
短命の auth key を使う。

## ビルド

```bash
make image          # 最新の unstable-v* を解決して build
make test           # build + smoke test
make check          # seccomp と Go の静的チェック
```

`make` を使わない場合:

```bash
docker build \
  --build-arg TAILSCALE_IMAGE=ghcr.io/tailscale/tailscale:$(./scripts/latest-unstable-tag.sh) \
  -t ts-docker-distroless:dev .
```

バージョンを固定したい場合だけ、明示的に渡す。

```bash
# 例: 2026-10-25 の nightly に固定する
TAILSCALE_TAG=unstable-v1.105.99 make image
```

## 制限

- userspace networking のみ。`TS_USERSPACE=false` は非対応。distroless に
  iptables/iproute2 がなく、TUN モードの netfilter 設定ができない。
- root のみ。
- shell なし。`docker exec` では実行ファイルのパスを指定する。
- 低ポートを待ち受けるには `NET_BIND_SERVICE` が要る。
- Tailscale Inc. とは無関係。

## seccomp プロファイル

`seccomp/tailscale.json` は Moby の既定プロファイルから
`seccomp/blocklist.txt` の syscall を削って生成している。手で編集しない。

```bash
./scripts/update-seccomp.sh
./scripts/check-seccomp.sh
```

元の Moby プロファイルの revision は `scripts/update-seccomp.sh` に固定してある。

## CI

- `.github/workflows/ci.yml`: seccomp の検証、`go vet`、イメージ build、
  probe による seccomp の実効性確認、tailscaled の起動確認。
- `.github/workflows/nightly.yml`: linux/amd64、linux/arm64、linux/arm/v7 を
  build し、provenance と SBOM 付きで ghcr.io へ push する。
