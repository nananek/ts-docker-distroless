# seccomp/tailscale.json

Moby の既定 seccomp プロファイルを元に、`blocklist.txt` の syscall を
すべての allow ルールから削除したもの。手で編集せず、
`scripts/update-seccomp.sh` で再生成する。

- 元: `moby/profiles@6fe7deb1b9fb7c0397a4593480d7d22b9ee8caef` の
  `seccomp/default.json`
- 差分: `blocklist.txt`

`tailscale.json` はイメージ内の `/etc/tailscale/seccomp.json` にも入る。
イメージの `sandbox-exec` は SSH に必要な syscall だけを独自に落とすので、
このプロファイルは追加の防御層として使う。

```bash
docker run --security-opt seccomp=./seccomp/tailscale.json ...
```

Kubernetes では `localhostProfile` にホストへ配置したこのファイルを指定する。
