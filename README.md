# selfsteal-media

selfsteal 一键安装脚本 + 伪装站媒体包。

## 一条命令安装（在全新 VPS 上执行）

```bash
curl -fsSL -o selfsteal-install.sh https://raw.githubusercontent.com/whitejia007/selfsteal-media/main/selfsteal-install.sh && bash selfsteal-install.sh
```

先下载再执行（不要用 `bash <(curl ...)` 管道方式，会导致 se 命令部署失败）。

## 内容

- `selfsteal-install.sh` — 一键安装脚本（主文件）
- Release `media` — 伪装站媒体包（302MB，安装时自动询问拉取）

## 媒体包直链

https://github.com/whitejia007/selfsteal-media/releases/download/media/selfsteal-media.tar.gz
