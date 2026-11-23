#!/bin/bash
# =============================================================================
#  selfsteal-install.sh
#  一键部署「偷自己」Reality 节点
#  nginx(回落站) + certbot(真证书) + sing-box(Reality) ，零面板、最小依赖
#
#  用法：
#    bash selfsteal-install.sh                 # 未安装=直接进安装向导；已安装=进管理菜单
#    se / SE                                   # 装完后随时输入，进入管理菜单（自动创建）
#    bash selfsteal-install.sh --status        # 查看状态
#    bash selfsteal-install.sh --link          # 输出客户端链接
#    bash selfsteal-install.sh --uninstall     # 卸载
#    bash selfsteal-install.sh --media [URL]   # 拉取伪装站媒体库（GitHub Release，URL 可选）
#    bash selfsteal-install.sh --media-gen     # 本地 ffmpeg 生成媒体库（低配机不推荐）
#    bash selfsteal-install.sh --write-site    # 只重建伪装站页面（不动节点与证书）
#    sest                                      # 访问统计控制台（菜单 11），私密访客页面见输出
#    bash selfsteal-install.sh --domain a.com --email x@y.com   # 免交互安装
#
#  依赖（脚本自动安装）：nginx certbot curl wget tar jq
#  不装：宝塔 / 3X-UI / PHP / MySQL / Python
# =============================================================================

# ---------- 颜色与输出 ----------
red='\e[31m'; green='\e[32m'; yellow='\e[33m'; blue='\e[34m'
cyan='\e[36m'; gray='\e[90m'; none='\e[0m'
msg()  { echo -e "${cyan}[$(date +%H:%M:%S)]${none} $*"; }
ok()   { echo -e "  ${green}✔${none} $*"; }
warn() { echo -e "  ${yellow}⚠${none} $*"; }
err()  { echo -e "  ${red}✘${none} $*" >&2; }
die()  { err "$*"; exit 1; }
line() { echo -e "${gray}------------------------------------------------------------${none}"; }

# ---------- 全局路径 ----------
SITE_ROOT=/var/www/selfsteal
ACME_ROOT=/var/www/certbot
NGINX_AVAIL=""          # 由 init_nginx_paths 按发行版决定
NGINX_LINK=""
SB_DIR=/opt/sing-box
SB_BIN=$SB_DIR/sing-box
SB_CONF_DIR=/etc/sing-box
SB_CONF=$SB_CONF_DIR/config.json
SB_SVC=/etc/systemd/system/sing-box.service
STATE_FILE=/etc/sing-box/state.env          # 记录 domain/uuid/pubkey，供菜单复用
CERT_HOOK=/etc/letsencrypt/renewal-hooks/deploy/reload-nginx.sh

REALITY_PORT=443
SITE_PORT=8443
MEDIA_RATE=256k      # 伪装站媒体单连接限速，防刷流量
DOMAIN=""
EMAIL=""
UUID=""
PRIV=""
PUB=""
# 落地代理（静态住宅）：多落地共用一个节点端口，按入站用户名分流到不同出口
LP_ENABLED=0
LP_IN_PORT=""
LP_LIST_LOADED=0
declare -a LP_NAMES LP_UUIDS LP_TYPES LP_SERVERS LP_SPORTS LP_USERS LP_PASSES

# ---------- 基础工具 ----------
need_root() { [[ $EUID -eq 0 ]] || die "请用 root 运行（sudo -i 后再执行）"; }

detect_pkg() {
    if   command -v apt-get >/dev/null 2>&1; then PKG=apt
    elif command -v dnf     >/dev/null 2>&1; then PKG=dnf
    elif command -v yum     >/dev/null 2>&1; then PKG=yum
    elif command -v apk     >/dev/null 2>&1; then PKG=apk
    else die "不支持的发行版（需要 apt/dnf/yum/apk）"
    fi
    ok "包管理器: $PKG"
}

pkg_install() {
    case $PKG in
        apt) DEBIAN_FRONTEND=noninteractive apt-get install -y -qq "$@" >/dev/null 2>&1 ;;
        dnf) dnf install -y -q "$@" >/dev/null 2>&1 ;;
        yum) yum install -y -q "$@" >/dev/null 2>&1 ;;
        apk) apk add --no-cache "$@" >/dev/null 2>&1 ;;
    esac
}

pkg_update() {
    case $PKG in
        apt) apt-get update -qq >/dev/null 2>&1 ;;
        dnf) dnf makecache -q >/dev/null 2>&1 ;;
        yum) yum makecache -q >/dev/null 2>&1 ;;
        apk) apk update >/dev/null 2>&1 ;;
    esac
}

# Debian/Ubuntu 用 sites-available + sites-enabled；RHEL/Alpine 用 conf.d
init_nginx_paths() {
    if [[ -d /etc/nginx/sites-available ]]; then
        NGINX_AVAIL=/etc/nginx/sites-available/selfsteal
        NGINX_LINK=/etc/nginx/sites-enabled/selfsteal
    else
        NGINX_AVAIL=/etc/nginx/conf.d/selfsteal.conf
        NGINX_LINK=""
    fi
}

ask() {   # ask "提示" "默认值" -> REPLY
    local p=$1 d=${2:-}
    if [[ -n $d ]]; then
        read -r -p "$(echo -e "${cyan}?${none} $p ${gray}[${d}]${none}: ")" REPLY
        [[ -z $REPLY ]] && REPLY=$d
    else
        read -r -p "$(echo -e "${cyan}?${none} $p: ")" REPLY
    fi
}

confirm() {
    local a
    read -r -p "$(echo -e "${cyan}?${none} $1 ${gray}[y/N]${none}: ")" a
    [[ $a =~ ^[Yy]$ ]]
}

get_public_ip() {
    local ip
    ip=$(curl -4 -fsS --max-time 8 https://api.ipify.org 2>/dev/null)
    [[ -z $ip ]] && ip=$(curl -4 -fsS --max-time 8 https://ipv4.icanhazip.com 2>/dev/null | tr -d '\r')
    [[ -z $ip ]] && ip=$(curl -4 -fsS --max-time 8 https://ifconfig.me 2>/dev/null | tr -d '\r')
    echo "$ip"
}

port_busy() { ss -tln 2>/dev/null | awk '{print $4}' | grep -qE "[:.]$1\$"; }

# ---------- 状态读取 ----------
load_state() {
    [[ -f $STATE_FILE ]] || return 1
    # shellcheck disable=SC1090
    . "$STATE_FILE"
    # shellcheck disable=SC1090
    [[ -n $DOMAIN && -n $UUID ]] || return 1
    return 0
}

# 是否已完成安装
is_installed() {
    [[ -f $STATE_FILE && -f $SB_CONF && -x $SB_BIN ]]
}

# 部署常驻脚本 + se/SE 命令（幂等，每次运行自动更新到最新版本）
ensure_cli() {
    local home=/opt/selfsteal/selfsteal.sh
    mkdir -p /opt/selfsteal
    if [[ "$(readlink -f "$0" 2>/dev/null)" != "$home" && -f "$0" ]]; then
        cp -f "$0" "$home" 2>/dev/null
    fi
    [[ -f $home ]] && chmod +x "$home" && \
        ln -sf "$home" /usr/local/bin/se && \
        ln -sf "$home" /usr/local/bin/SE

    install_stats
}

# 启用 BBR（内核支持才开，幂等）
enable_bbr() {
    modprobe tcp_bbr 2>/dev/null
    if [[ $(sysctl -n net.ipv4.tcp_available_congestion_control 2>/dev/null) == *bbr* ]]; then
        printf 'net.core.default_qdisc=fq\nnet.ipv4.tcp_congestion_control=bbr\n' \
            > /etc/sysctl.d/99-selfsteal-bbr.conf
        sysctl -p /etc/sysctl.d/99-selfsteal-bbr.conf >/dev/null 2>&1
        ok "拥塞控制: $(sysctl -n net.ipv4.tcp_congestion_control) / $(sysctl -n net.core.default_qdisc)"
    else
        warn "内核不支持 BBR，保持 $(sysctl -n net.ipv4.tcp_congestion_control)"
    fi
}

# =============================================================================
#  步骤 1：环境预检
# =============================================================================
step_precheck() {
    line; msg "步骤 1/8  环境预检"; line

    ok "系统: $(. /etc/os-release 2>/dev/null; echo "${PRETTY_NAME:-unknown}")"
    ok "内核: $(uname -r)"

    case $(uname -m) in
        x86_64|amd64) ARCH=amd64 ;;
        aarch64|arm64) ARCH=arm64 ;;
        *) die "仅支持 64 位（amd64/arm64）" ;;
    esac
    ok "架构: $ARCH"

    command -v systemctl >/dev/null 2>&1 || die "需要 systemd（OpenRC 请手动改脚本）"

    if port_busy $REALITY_PORT; then
        if ss -tlnp 2>/dev/null | grep -E "[:.]${REALITY_PORT}\b" | grep -q 'sing-box'; then
            ok "端口 $REALITY_PORT 由本脚本的 sing-box 占用（重新配置模式）"
        else
            err "端口 $REALITY_PORT 已被占用："
            ss -tlnp 2>/dev/null | grep -E "[:.]${REALITY_PORT}\b" | sed 's/^/     /'
            die "请先停掉占用 443 的服务（nginx/caddy/其它节点）"
        fi
    else
        ok "端口 $REALITY_PORT 空闲"
    fi

    if port_busy $SITE_PORT; then
        if ss -tlnp 2>/dev/null | grep -E "[:.]${SITE_PORT}\b" | grep -q 'nginx'; then
            ok "端口 $SITE_PORT 由本脚本的 nginx 占用（重新配置模式）"
        else
            warn "端口 $SITE_PORT 已被其它程序占用"
        fi
    else
        ok "端口 $SITE_PORT 空闲"
    fi

    PUB_IP=$(get_public_ip)
    [[ -z $PUB_IP ]] && die "无法获取本机公网 IP（检查出网）"
    ok "公网 IP: $PUB_IP"
}

# =============================================================================
#  步骤 2：安装依赖
# =============================================================================
step_install_deps() {
    line; msg "步骤 2/8  安装依赖（nginx / certbot / 基础工具）"; line

    local need=()
    for c in curl wget tar jq; do
        command -v $c >/dev/null 2>&1 || need+=("$c")
    done
    command -v nginx  >/dev/null 2>&1 || need+=(nginx)
    command -v certbot >/dev/null 2>&1 || need+=(certbot)

    if [[ ${#need[@]} -gt 0 ]]; then
        msg "需要安装: ${need[*]}"
        pkg_update
        pkg_install "${need[@]}" || die "依赖安装失败，请手动执行包管理器安装"
    fi

    for c in nginx certbot curl wget tar jq; do
        command -v $c >/dev/null 2>&1 || die "依赖缺失: $c"
    done
    ok "依赖就绪: nginx $(nginx -v 2>&1 | grep -oE '[0-9.]+' | head -1) / certbot $(certbot --version 2>&1 | grep -oE '[0-9.]+' | head -1)"

    # nginx 装好后重新判定路径（全新安装时入口处 nginx 还不存在，会误走 conf.d）
    init_nginx_paths

    systemctl enable nginx >/dev/null 2>&1
    systemctl start nginx >/dev/null 2>&1
    ok "nginx 已启动"

    enable_bbr
}

# 清理另一套路径的旧站点配置，防止双份加载
clean_stale_nginx_site() {
    if [[ $NGINX_AVAIL == */sites-available/* ]]; then
        rm -f /etc/nginx/conf.d/selfsteal.conf
    else
        rm -f /etc/nginx/sites-enabled/selfsteal /etc/nginx/sites-available/selfsteal
    fi
}

# =============================================================================
#  步骤 3：收集域名并校验 DNS
# =============================================================================
step_collect_domain() {
    line; msg "步骤 3/8  域名与 DNS 校验"; line

    if [[ -z $DOMAIN ]]; then
        echo -e "  ${gray}要求：域名 A 记录已指向 ${PUB_IP}，且未开启 CDN/代理${none}"
        while :; do
            ask "请输入用于伪装的域名（如 api.example.com）"
            DOMAIN=$(echo "$REPLY" | tr -d ' ' | tr 'A-Z' 'a-z')
            [[ $DOMAIN =~ ^[a-z0-9]([a-z0-9-]*[a-z0-9])?(\.[a-z0-9]([a-z0-9-]*[a-z0-9])?)+$ ]] && break
            err "域名格式不正确"
        done
    fi
    ok "域名: $DOMAIN"

    if [[ -z $EMAIL ]]; then
        ask "证书通知邮箱（可留空，Let's Encrypt 不强制）" ""
        EMAIL=$REPLY
    fi

    msg "解析检查中..."
    local resolved=""
    for i in 1 2 3; do
        resolved=$(getent ahostsv4 "$DOMAIN" 2>/dev/null | awk '{print $1; exit}')
        [[ -n $resolved ]] && break
        sleep 2
    done

    if [[ -z $resolved ]]; then
        err "域名 $DOMAIN 解析不到 A 记录"
        echo -e "  ${gray}请先去 DNS 面板添加：A 记录  ${DOMAIN%%.*}  ->  ${PUB_IP}${none}"
        die "DNS 未生效，退出（生效后重新运行）"
    fi
    ok "解析到: $resolved"

    if [[ $resolved != "$PUB_IP" ]]; then
        err "解析 IP ($resolved) 与本机公网 IP ($PUB_IP) 不一致"
        echo -e "  ${gray}可能原因：① DNS 未生效 ② 开了 CDN/代理（必须关闭）③ IP 填错${none}"
        confirm "仍然继续？（不建议）" || die "已取消"
    else
        ok "DNS 校验通过（指向本机）"
    fi
}

# 影像列表页链到 /video/<slug>.html。媒体文件由 --media 另放，页面必须随脚本生成。
write_video_pages() {
    mkdir -p "$SITE_ROOT/video"
    local slug title date dur size blurb
    while IFS='|' read -r slug title date dur size blurb; do
        [[ -z $slug || $slug == \#* ]] && continue
        cat > "$SITE_ROOT/video/${slug}.html" <<EOF_VPAGE
<!DOCTYPE html>
<html lang="zh-CN">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width,initial-scale=1">
<meta name="description" content="${blurb}">
<title>${title} · 拾光小记</title>
<link rel="icon" href="/favicon.ico">
<link rel="stylesheet" href="/assets/style.css">
</head>
<body>
<header class="site-head">
  <div class="wrap">
    <a class="brand" href="/">拾光小记</a>
    <nav>
      <a href="/">首页</a>
      <a href="/video.html" class="active">影像</a>
      <a href="/wallpaper.html">壁纸</a>
      <a href="/archive.html">随笔</a>
      <a href="/about.html">关于</a>
    </nav>
  </div>
</header>
<main class="wrap">
  <h1 class="page-title">${title}</h1>
  <p class="page-sub">${date} · ${dur} · ${size} · 一次成片，没有剪辑。</p>
  <video class="player" controls playsinline preload="metadata" poster="/media/thumb/${slug}.png">
    <source src="/media/video/${slug}.mp4" type="video/mp4">
  </video>
  <p><a class="btn" href="/media/video/${slug}.mp4" download>下载原片</a></p>
  <p>${blurb}</p>
  <p class="back"><a href="/video.html">← 回影像</a></p>
</main>
<footer class="site-foot">
  <div class="wrap">
    <p>拾光小记 · 影像与随笔 · 2019-2026 · 站点放在一台小机器上，视频没套 CDN，加载慢请体谅。</p>
  </div>
</footer>
</body>
</html>
EOF_VPAGE
    done <<'VIDEOS'
auto-xingxie|星屑 · 生命游戏|2026-11-12|3:00|100 MB|康威生命游戏跑了三分钟。活细胞是暖金，底是深蓝灰，从头放到尾，没有剪。
auto-yuanbao|元胞 · 雨夜 110|2026-11-05|3:00|16 MB|110 号元胞机，调色偏冷。像雨夜里一块自己在长的玻璃。
tushi-erhao|图样 · 色相漫游|2026-10-24|3:00|48 MB|测试图样把色相慢慢转了一圈。本来是对焦用的画面，转着转着倒像一组自己的片子。
fenxing-piaoliu|分形漂流（九十秒）|2026-10-15|1:30|114 MB|曼德博集合往里漂了九十秒。这一支比别的短，文件反而最大，细节都堆在后半段。
jianbian-zhiye|渐变之夜|2026-10-03|3:00|13 MB|螺旋渐变，从深蓝转到赭石再回到纸色。几乎没有形状，就是颜色在走。
chenhun-xian|晨昏线|2026-09-24|3:00|11 MB|圆形渐变，暖金压在蓝灰上。名字取的是昼夜交界那一条线。
VIDEOS
    ok "影像播放页已生成: 6"
}

# =============================================================================
#  步骤 4：生成回落网站（静态）
# =============================================================================
step_write_site() {
    line; msg "步骤 4/8  生成回落网站（生成影像站）"; line

    mkdir -p "$SITE_ROOT" "$SITE_ROOT/posts" "$SITE_ROOT/assets" "$SITE_ROOT/video" "$ACME_ROOT"

    cat > "$SITE_ROOT/assets/style.css" <<EOF_CSS
/* 拾光小记 · 手写的简单样式，不追求漂亮，追求顺眼 */
:root{
  --ink:#2f3336;
  --muted:#7a8288;
  --line:#e7e3da;
  --paper:#faf8f3;
  --accent:#b1623c;
  --accent-dark:#8f4c2e;
}
*{box-sizing:border-box}
html{-webkit-text-size-adjust:100%}
body{
  margin:0;
  background:var(--paper);
  color:var(--ink);
  font:16px/1.85 -apple-system,BlinkMacSystemFont,"Segoe UI","PingFang SC","Hiragino Sans GB","Microsoft YaHei",sans-serif;
}
.wrap{max-width:720px;margin:0 auto;padding:0 20px}

/* 顶栏 */
.site-head{
  border-bottom:1px solid var(--line);
  background:#fffdf8;
}
.site-head .wrap{
  display:flex;align-items:baseline;justify-content:space-between;
  padding-top:22px;padding-bottom:22px;flex-wrap:wrap;gap:8px;
}
.brand{
  font-size:21px;font-weight:700;color:var(--ink);
  text-decoration:none;letter-spacing:1px;
}
.brand::before{content:"✦";color:var(--accent);margin-right:8px;font-size:15px}
.site-head nav a{
  color:var(--muted);text-decoration:none;margin-left:18px;font-size:14.5px;
}
.site-head nav a:hover{color:var(--accent-dark)}
.site-head nav a.active{color:var(--accent-dark);border-bottom:2px solid var(--accent);padding-bottom:2px}

/* 首页 */
.intro{margin:36px 0 8px;font-size:15.5px;color:#4a5054}
.sec-title{
  font-size:14px;color:var(--muted);font-weight:600;
  letter-spacing:2px;text-transform:uppercase;
  border-bottom:1px solid var(--line);padding-bottom:10px;
}
.post-list{list-style:none;padding:0;margin:0}
.post-list li{
  padding:22px 0;border-bottom:1px solid var(--line);
}
.post-list .date{
  font-size:12.5px;color:var(--muted);
  font-variant-numeric:tabular-nums;display:block;margin-bottom:2px;
}
.post-list a{
  color:var(--ink);text-decoration:none;font-size:17.5px;font-weight:600;line-height:1.5;
}
.post-list a:hover{color:var(--accent-dark)}
.excerpt{margin:8px 0 0;color:var(--muted);font-size:14.5px}

/* 页面标题 */
.page-title{font-size:26px;margin:44px 0 4px;letter-spacing:.5px}
.page-sub{color:var(--muted);margin-top:0;font-size:14.5px}
.muted{color:var(--muted)}

/* 归档 */
.year{
  font-size:15px;color:var(--accent-dark);
  margin:32px 0 6px;letter-spacing:1px;
}
.arch-list{list-style:none;padding:0;margin:0}
.arch-list li{
  padding:9px 0;border-bottom:1px dashed var(--line);
  font-size:15px;
}
.arch-list .date{
  color:var(--muted);font-size:13px;margin-right:12px;
  font-variant-numeric:tabular-nums;
}
.arch-list a{color:var(--ink);text-decoration:none}
.arch-list a:hover{color:var(--accent-dark)}

/* 文章 */
.post-title{font-size:25px;line-height:1.45;margin:44px 0 6px}
.post-meta{color:var(--muted);font-size:13.5px;margin:0 0 26px;
  border-bottom:1px solid var(--line);padding-bottom:18px}
article h3{font-size:17.5px;margin:30px 0 8px}
article p{margin:14px 0}
article ul{padding-left:22px}
article li{margin:6px 0}
code{
  background:#efece3;border:1px solid var(--line);border-radius:4px;
  padding:1px 6px;font-size:13.5px;
}
strong{color:var(--accent-dark)}
.back{margin-top:36px}
.back a{color:var(--muted);font-size:14px;text-decoration:none}
.back a:hover{color:var(--accent-dark)}

/* 404 */
.big{font-size:64px;color:var(--accent);margin:60px 0 0;line-height:1}
.notfound p{color:var(--muted)}

/* 底栏 */
.site-foot{
  margin-top:64px;border-top:1px solid var(--line);
  background:#fffdf8;
}
.site-foot p{
  color:var(--muted);font-size:12.5px;
  padding:20px 0;
}

/* ---- 影像卡片 ---- */
.vgrid{
  display:grid;grid-template-columns:repeat(auto-fill,minmax(220px,1fr));
  gap:16px;margin-top:18px;
}
.vcard{
  display:block;text-decoration:none;border:1px solid var(--line);
  background:#fffdf8;border-radius:8px;overflow:hidden;color:var(--ink);
}
.vcard img,.wcard img,.wcell img{
  width:100%;aspect-ratio:16/9;object-fit:cover;display:block;
}
.vcard:hover{border-color:var(--accent)}
.vc-title{
  display:block;padding:10px 12px 2px;font-weight:600;font-size:15px;
}
.vcard:hover .vc-title{color:var(--accent-dark)}
.vc-meta{
  display:block;padding:0 12px 12px;color:var(--muted);font-size:12.5px;
  font-variant-numeric:tabular-nums;
}

/* ---- 壁纸网格 ---- */
.wgrid{
  display:grid;grid-template-columns:repeat(auto-fill,minmax(160px,1fr));
  gap:12px;margin-top:18px;
}
.wgrid.big{grid-template-columns:repeat(auto-fill,minmax(180px,1fr))}
.wcard{display:block;border-radius:8px;overflow:hidden;border:1px solid var(--line)}
.wcard:hover{border-color:var(--accent)}
.wcell{
  display:block;text-decoration:none;border-radius:8px;overflow:hidden;
  border:1px solid var(--line);background:#fffdf8;color:var(--ink);
}
.wcell:hover{border-color:var(--accent)}
.wc-name{display:block;padding:8px 10px 1px;font-weight:600;font-size:14px}
.wc-meta{display:block;padding:0 10px 10px;color:var(--muted);font-size:12px}

/* ---- 播放页 ---- */
.player{
  display:block;width:100%;background:#000;border-radius:8px;margin:18px 0;
}
.btn{
  display:inline-block;background:var(--accent);color:#fff;
  padding:9px 18px;border-radius:6px;text-decoration:none;font-size:14.5px;
}
.btn:hover{background:var(--accent-dark)}

/* ---- 链接行 ---- */
.more{margin:6px 0 40px}
.more a{color:var(--muted);font-size:14px;text-decoration:none}
.more a:hover{color:var(--accent-dark)}
EOF_CSS
    cat > "$SITE_ROOT/index.html" <<EOF_INDEX
<!DOCTYPE html>
<html lang="zh-CN">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width,initial-scale=1">
<meta name="description" content="拾光小记：生成影像、壁纸与随笔。分形、元胞机、渐变，都是代码跑出来的画面。">
<title>拾光小记</title>
<link rel="icon" href="/favicon.ico">
<link rel="stylesheet" href="/assets/style.css">
</head>
<body>
<header class="site-head">
  <div class="wrap">
    <a class="brand" href="/">拾光小记</a>
    <nav>
      <a href="/" class="active">首页</a>
      <a href="/video.html">影像</a>
      <a href="/wallpaper.html">壁纸</a>
      <a href="/archive.html">随笔</a>
      <a href="/about.html">关于</a>
    </nav>
  </div>
</header>
<main class="wrap">
  <section class="intro">
    <p>你好。这里存放我用代码「跑」出来的影像和壁纸——分形、元胞自动机、渐变，每支都是一段一次成片的小实验；偶尔也写点随笔，记咖啡、阳台和山路。</p>
    <p>站点挂在自己一台小机器上，<strong>视频没套 CDN</strong>，第一下加载可能有点慢，愿等则等，不愿等也没关系。</p>
  </section>

  <h2 class="sec-title">最近影像</h2>
  <div class="vgrid">
      <a class="vcard" href="/video/auto-xingxie.html">
        <img src="/media/thumb/auto-xingxie.png" alt="星屑 · 生命游戏封面" loading="lazy">
        <span class="vc-title">星屑 · 生命游戏</span>
        <span class="vc-meta">2026-11-12 · 3:00 · 100 MB</span>
      </a>
      <a class="vcard" href="/video/auto-yuanbao.html">
        <img src="/media/thumb/auto-yuanbao.png" alt="元胞 · 雨夜 110封面" loading="lazy">
        <span class="vc-title">元胞 · 雨夜 110</span>
        <span class="vc-meta">2026-11-05 · 3:00 · 16 MB</span>
      </a>
      <a class="vcard" href="/video/tushi-erhao.html">
        <img src="/media/thumb/tushi-erhao.png" alt="图样 · 色相漫游封面" loading="lazy">
        <span class="vc-title">图样 · 色相漫游</span>
        <span class="vc-meta">2026-10-24 · 3:00 · 48 MB</span>
      </a>
  </div>
  <p class="more"><a href="/video.html">全部 6 支影像 →</a></p>

  <h2 class="sec-title">壁纸精选</h2>
  <div class="wgrid">
      <a class="wcard" href="/wallpaper.html"><img src="/media/thumb/wp-01.png" alt="黎明前" loading="lazy"></a>
      <a class="wcard" href="/wallpaper.html"><img src="/media/thumb/wp-02.png" alt="赭石" loading="lazy"></a>
      <a class="wcard" href="/wallpaper.html"><img src="/media/thumb/wp-03.png" alt="青灰" loading="lazy"></a>
      <a class="wcard" href="/wallpaper.html"><img src="/media/thumb/wp-04.png" alt="暮金" loading="lazy"></a>
  </div>
  <p class="more"><a href="/wallpaper.html">全部 12 张壁纸（1920×1080 PNG） →</a></p>

  <h2 class="sec-title">最近随笔</h2>
  <ul class="post-list">
    <li><span class="date">2026-11-02</span><a href="/posts/tubu-qingdan.html">秋季徒步装备清单：从背包到袜子的笨办法</a></li>
    <li><span class="date">2026-10-12</span><a href="/posts/shouchong-biji.html">手冲咖啡参数笔记：把一件小事重复一百遍</a></li>
  </ul>
  <p class="more"><a href="/archive.html">随笔归档 →</a></p>
</main>
<footer class="site-foot">
  <div class="wrap">
    <p>拾光小记 · 影像与随笔 · 2019-2026 · 站点放在一台小机器上，视频没套 CDN，加载慢请体谅。</p>
  </div>
</footer>
</body>
</html>
EOF_INDEX
    cat > "$SITE_ROOT/video.html" <<EOF_VIDEO
<!DOCTYPE html>
<html lang="zh-CN">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width,initial-scale=1">
<meta name="description" content="生成影像合集：分形、元胞自动机、渐变与测试图样，全部一次成片。">
<title>影像 · 拾光小记</title>
<link rel="icon" href="/favicon.ico">
<link rel="stylesheet" href="/assets/style.css">
</head>
<body>
<header class="site-head">
  <div class="wrap">
    <a class="brand" href="/">拾光小记</a>
    <nav>
      <a href="/">首页</a>
      <a href="/video.html" class="active">影像</a>
      <a href="/wallpaper.html">壁纸</a>
      <a href="/archive.html">随笔</a>
      <a href="/about.html">关于</a>
    </nav>
  </div>
</header>
<main class="wrap">
  <h1 class="page-title">影像</h1>
  <p class="page-sub">共 6 支，均为生成后一次成片，没有剪辑。点开可以在线播，也可以直接下载。</p>
  <div class="vgrid">
    <a class="vcard" href="/video/auto-xingxie.html">
      <img src="/media/thumb/auto-xingxie.png" alt="星屑 · 生命游戏封面" loading="lazy">
      <span class="vc-title">星屑 · 生命游戏</span>
      <span class="vc-meta">2026-11-12 · 3:00 · 100 MB</span>
    </a>
    <a class="vcard" href="/video/auto-yuanbao.html">
      <img src="/media/thumb/auto-yuanbao.png" alt="元胞 · 雨夜 110封面" loading="lazy">
      <span class="vc-title">元胞 · 雨夜 110</span>
      <span class="vc-meta">2026-11-05 · 3:00 · 16 MB</span>
    </a>
    <a class="vcard" href="/video/tushi-erhao.html">
      <img src="/media/thumb/tushi-erhao.png" alt="图样 · 色相漫游封面" loading="lazy">
      <span class="vc-title">图样 · 色相漫游</span>
      <span class="vc-meta">2026-10-24 · 3:00 · 48 MB</span>
    </a>
    <a class="vcard" href="/video/fenxing-piaoliu.html">
      <img src="/media/thumb/fenxing-piaoliu.png" alt="分形漂流（九十秒）封面" loading="lazy">
      <span class="vc-title">分形漂流（九十秒）</span>
      <span class="vc-meta">2026-10-15 · 1:30 · 114 MB</span>
    </a>
    <a class="vcard" href="/video/jianbian-zhiye.html">
      <img src="/media/thumb/jianbian-zhiye.png" alt="渐变之夜封面" loading="lazy">
      <span class="vc-title">渐变之夜</span>
      <span class="vc-meta">2026-10-03 · 3:00 · 13 MB</span>
    </a>
    <a class="vcard" href="/video/chenhun-xian.html">
      <img src="/media/thumb/chenhun-xian.png" alt="晨昏线封面" loading="lazy">
      <span class="vc-title">晨昏线</span>
      <span class="vc-meta">2026-09-24 · 3:00 · 11 MB</span>
    </a>
  </div>
</main>
<footer class="site-foot">
  <div class="wrap">
    <p>拾光小记 · 影像与随笔 · 2019-2026 · 站点放在一台小机器上，视频没套 CDN，加载慢请体谅。</p>
  </div>
</footer>
</body>
</html>
EOF_VIDEO
    cat > "$SITE_ROOT/wallpaper.html" <<EOF_WALL
<!DOCTYPE html>
<html lang="zh-CN">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width,initial-scale=1">
<meta name="description" content="1920×1080 渐变壁纸 12 张，PNG 原图直接下载。">
<title>壁纸 · 拾光小记</title>
<link rel="icon" href="/favicon.ico">
<link rel="stylesheet" href="/assets/style.css">
</head>
<body>
<header class="site-head">
  <div class="wrap">
    <a class="brand" href="/">拾光小记</a>
    <nav>
      <a href="/">首页</a>
      <a href="/video.html">影像</a>
      <a href="/wallpaper.html" class="active">壁纸</a>
      <a href="/archive.html">随笔</a>
      <a href="/about.html">关于</a>
    </nav>
  </div>
</header>
<main class="wrap">
  <h1 class="page-title">壁纸</h1>
  <p class="page-sub">12 张，1920×1080，PNG 原图。点缩略图直接下载原图，桌面和手机都能用。</p>
  <div class="wgrid big">
    <a class="wcell" href="/media/wallpaper/wp-01.png" download>
      <img src="/media/thumb/wp-01.png" alt="壁纸 黎明前" loading="lazy">
      <span class="wc-name">黎明前</span>
      <span class="wc-meta">1920×1080 · PNG</span>
    </a>
    <a class="wcell" href="/media/wallpaper/wp-02.png" download>
      <img src="/media/thumb/wp-02.png" alt="壁纸 赭石" loading="lazy">
      <span class="wc-name">赭石</span>
      <span class="wc-meta">1920×1080 · PNG</span>
    </a>
    <a class="wcell" href="/media/wallpaper/wp-03.png" download>
      <img src="/media/thumb/wp-03.png" alt="壁纸 青灰" loading="lazy">
      <span class="wc-name">青灰</span>
      <span class="wc-meta">1920×1080 · PNG</span>
    </a>
    <a class="wcell" href="/media/wallpaper/wp-04.png" download>
      <img src="/media/thumb/wp-04.png" alt="壁纸 暮金" loading="lazy">
      <span class="wc-name">暮金</span>
      <span class="wc-meta">1920×1080 · PNG</span>
    </a>
    <a class="wcell" href="/media/wallpaper/wp-05.png" download>
      <img src="/media/thumb/wp-05.png" alt="壁纸 苔径" loading="lazy">
      <span class="wc-name">苔径</span>
      <span class="wc-meta">1920×1080 · PNG</span>
    </a>
    <a class="wcell" href="/media/wallpaper/wp-06.png" download>
      <img src="/media/thumb/wp-06.png" alt="壁纸 雾晨" loading="lazy">
      <span class="wc-name">雾晨</span>
      <span class="wc-meta">1920×1080 · PNG</span>
    </a>
    <a class="wcell" href="/media/wallpaper/wp-07.png" download>
      <img src="/media/thumb/wp-07.png" alt="壁纸 焰心" loading="lazy">
      <span class="wc-name">焰心</span>
      <span class="wc-meta">1920×1080 · PNG</span>
    </a>
    <a class="wcell" href="/media/wallpaper/wp-08.png" download>
      <img src="/media/thumb/wp-08.png" alt="壁纸 回声" loading="lazy">
      <span class="wc-name">回声</span>
      <span class="wc-meta">1920×1080 · PNG</span>
    </a>
    <a class="wcell" href="/media/wallpaper/wp-09.png" download>
      <img src="/media/thumb/wp-09.png" alt="壁纸 沙丘" loading="lazy">
      <span class="wc-name">沙丘</span>
      <span class="wc-meta">1920×1080 · PNG</span>
    </a>
    <a class="wcell" href="/media/wallpaper/wp-10.png" download>
      <img src="/media/thumb/wp-10.png" alt="壁纸 深井" loading="lazy">
      <span class="wc-name">深井</span>
      <span class="wc-meta">1920×1080 · PNG</span>
    </a>
    <a class="wcell" href="/media/wallpaper/wp-11.png" download>
      <img src="/media/thumb/wp-11.png" alt="壁纸 胶片" loading="lazy">
      <span class="wc-name">胶片</span>
      <span class="wc-meta">1920×1080 · PNG</span>
    </a>
    <a class="wcell" href="/media/wallpaper/wp-12.png" download>
      <img src="/media/thumb/wp-12.png" alt="壁纸 夜航" loading="lazy">
      <span class="wc-name">夜航</span>
      <span class="wc-meta">1920×1080 · PNG</span>
    </a>
  </div>
</main>
<footer class="site-foot">
  <div class="wrap">
    <p>拾光小记 · 影像与随笔 · 2019-2026 · 站点放在一台小机器上，视频没套 CDN，加载慢请体谅。</p>
  </div>
</footer>
</body>
</html>
EOF_WALL
    cat > "$SITE_ROOT/about.html" <<EOF_ABOUT
<!DOCTYPE html>
<html lang="zh-CN">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width,initial-scale=1">
<meta name="description" content="关于拾光小记：一个存放生成影像、壁纸与随笔的个人小站。">
<title>关于 · 拾光小记</title>
<link rel="icon" href="/favicon.ico">
<link rel="stylesheet" href="/assets/style.css">
</head>
<body>
<header class="site-head">
  <div class="wrap">
    <a class="brand" href="/">拾光小记</a>
    <nav>
      <a href="/">首页</a>
      <a href="/video.html">影像</a>
      <a href="/wallpaper.html">壁纸</a>
      <a href="/archive.html">随笔</a>
      <a href="/about.html" class="active">关于</a>
    </nav>
  </div>
</header>
<main class="wrap">
  <h1 class="page-title">关于</h1>
  <p class="page-sub">这个站，和写这个站的人。</p>

  <h3>先说站</h3>
  <p>「拾光小记」是我的杂物间，三个抽屉：<strong>影像</strong>放我用 FFmpeg 和一点代码跑出来的生成影像——分形、元胞自动机、渐变，都是一次成片、不剪辑的小实验；<strong>壁纸</strong>放 1920×1080 的渐变原图；<strong>随笔</strong>记些慢下来的事，咖啡、阳台、山路和书。</p>
  <p>站点是我自己部署在一台小机器上的，纯静态页面，视频没套 CDN，没有评论功能。想说的话可以发邮件，地址在下面。</p>

  <h3>再说人</h3>
  <p>普通上班族，白天对着屏幕写别人的代码，晚上愿意的话就跑一段自己的渲染。做这些不为别的：看着一帧帧自己长出来的画面，比刷短视频踏实。</p>
  <p>家里的阳台朝东南，有一盆疯长的薄荷；有一个磨豆手冲的小角落，参数记在随笔里；有一柜子没读完的书，和一双越穿越合脚的登山鞋。</p>

  <h3>关于内容使用</h3>
  <p>站内的影像和壁纸都是我自己生成的，想要就拿去当壁纸、当素材，不必问我；<strong>别拿去做违法的事就行</strong>。随笔是我的私货，转载前打个招呼。</p>

  <h3>联系</h3>
  <p>邮件：<code>hi@shiguangnotes.example</code>（把 example 换成你能想到的那个域名，防爬虫，见谅）。</p>
</main>
<footer class="site-foot">
  <div class="wrap">
    <p>拾光小记 · 影像与随笔 · 2019-2026 · 站点放在一台小机器上，视频没套 CDN，加载慢请体谅。</p>
  </div>
</footer>
</body>
</html>
EOF_ABOUT
    cat > "$SITE_ROOT/archive.html" <<EOF_ARCH
<!DOCTYPE html>
<html lang="zh-CN">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width,initial-scale=1">
<meta name="description" content="随笔归档：咖啡、阳台、山路和书。">
<title>随笔归档 · 拾光小记</title>
<link rel="icon" href="/favicon.ico">
<link rel="stylesheet" href="/assets/style.css">
</head>
<body>
<header class="site-head">
  <div class="wrap">
    <a class="brand" href="/">拾光小记</a>
    <nav>
      <a href="/">首页</a>
      <a href="/video.html">影像</a>
      <a href="/wallpaper.html">壁纸</a>
      <a href="/archive.html" class="active">随笔</a>
      <a href="/about.html">关于</a>
    </nav>
  </div>
</header>
<main class="wrap">
  <h1 class="page-title">随笔</h1>
  <p class="page-sub">影像之外记的一些慢事。一共 4 篇，别急，慢慢看。</p>

  <h2 class="year">2026</h2>
  <ul class="arch-list">
    <li><span class="date">11-02</span> <a href="/posts/tubu-qingdan.html">秋季徒步装备清单：从背包到袜子的笨办法</a></li>
    <li><span class="date">10-28</span> <a href="/posts/dushu-biji.html">十月读书记：三本看完，一本弃了</a></li>
    <li><span class="date">10-12</span> <a href="/posts/shouchong-biji.html">手冲咖啡参数笔记：把一件小事重复一百遍</a></li>
    <li><span class="date">09-20</span> <a href="/posts/yangtai-zhiwu.html">阳台植物记录：薄荷疯了，绿萝蔫了</a></li>
  </ul>

  <h2 class="year">2025 及更早</h2>
  <p class="page-sub muted">早年文章搬家的时候没带过来，散落在旧硬盘里。哪天有兴致了再整理，先给它们立个牌位。</p>
</main>
<footer class="site-foot">
  <div class="wrap">
    <p>拾光小记 · 影像与随笔 · 2019-2026 · 站点放在一台小机器上，视频没套 CDN，加载慢请体谅。</p>
  </div>
</footer>
</body>
</html>
EOF_ARCH
    cat > "$SITE_ROOT/404.html" <<EOF_404
<!DOCTYPE html>
<html lang="zh-CN">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width,initial-scale=1">
<meta name="description" content="页面不存在">
<title>404 · 拾光小记</title>
<link rel="icon" href="/favicon.ico">
<link rel="stylesheet" href="/assets/style.css">
</head>
<body>
<header class="site-head">
  <div class="wrap">
    <a class="brand" href="/">拾光小记</a>
    <nav>
      <a href="/">首页</a>
      <a href="/video.html">影像</a>
      <a href="/wallpaper.html">壁纸</a>
      <a href="/archive.html">随笔</a>
      <a href="/about.html">关于</a>
    </nav>
  </div>
</header>
<main class="wrap notfound">
  <p class="big">404</p>
  <h1 class="page-title" style="margin-top:8px">这一页没捡到</h1>
  <p>地址可能敲错了，也可能文件搬家的时候没带过来。</p>
  <p>要不 <a href="/">回首页看看</a>，翻翻 <a href="/video.html">影像</a> 和 <a href="/wallpaper.html">壁纸</a>，或者看看 <a href="/archive.html">随笔</a>？</p>
</main>
<footer class="site-foot">
  <div class="wrap">
    <p>拾光小记 · 影像与随笔 · 2019-2026 · 站点放在一台小机器上，视频没套 CDN，加载慢请体谅。</p>
  </div>
</footer>
</body>
</html>
EOF_404
    cat > "$SITE_ROOT/posts/shouchong-biji.html" <<EOF_P1
<!DOCTYPE html>
<html lang="zh-CN">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width,initial-scale=1">
<meta name="description" content="半年手冲咖啡的参数记录：磨豆、水温、粉水比和绕圈手速，一篇写给自己的参考笔记。">
<title>手冲咖啡参数笔记：把一件小事重复一百遍 · 拾光小记</title>
<link rel="icon" href="/favicon.ico">
<link rel="stylesheet" href="/assets/style.css">
</head>
<body>
<header class="site-head">
  <div class="wrap">
    <a class="brand" href="/">拾光小记</a>
    <nav>
      <a href="/">首页</a>
      <a href="/video.html">影像</a>
      <a href="/wallpaper.html">壁纸</a>
      <a href="/archive.html">随笔</a>
      <a href="/about.html">关于</a>
    </nav>
  </div>
</header>

<main class="wrap">
  <article>
    <h1 class="post-title">手冲咖啡参数笔记：把一件小事重复一百遍</h1>
    <p class="post-meta">2026-10-12 · 约 6 分钟</p>

    <p>接触手冲满半年，冲坏的豆子大概够铺满一个阳台。这篇把我现在固定下来的参数记一遍，给自己复查用。手机备忘录里那份已经乱成一锅粥了。</p>

    <h3>我的常备参数</h3>
    <p>豆子一般用浅中烘，养豆七天以上。基本盘是这样：</p>
    <ul>
      <li>粉量 15g，水 225g，粉水比 1:15；</li>
      <li>研磨度比白砂糖略细一档，我用的是小栗子的 18 格上下浮动两格；</li>
      <li>水温 92°C，天冷的时候往 93°C 靠；</li>
      <li>闷蒸 30g 水等 35 秒，之后分三段注水，每段间隔让它稍微回落。</li>
    </ul>

    <h3>绕圈这件小事</h3>
    <p>看视频都学不会的事，是绕圈的<strong>手速均匀</strong>。我现在的办法是心里默数，大概一秒一圈，注水头不要贴着粉床也不要吊太高。有阵子我冲出来总有一股尖酸，后来发现是注水太猛把边缘的粉墙冲塌了，中间萃取过度。慢下来就好。</p>
    <p>还有滤纸。之前贪便宜买过一批杂牌，纸味重得像在喝纸浆，换了牌子之后世界清净了。润纸这步别偷懒，热水过一遍顺手把分享壶也温了。</p>

    <h3>翻车的几个瞬间</h3>
    <p>一是忘记称水，凭感觉注到天荒地老，出来一杯刷锅水；二是磨完豆忘了拍 grinder 的卡扣，粉仓漏了一桌子；三是冬天开窗冲咖啡，水温掉得比想象快，酸得皱眉。</p>
    <p>总结下来就一句话：参数是死的，手是活的，多冲多喝比什么都强。写完这篇，去把那包危地马拉开了。</p>
  </article>
  <p class="back"><a href="/archive.html">← 回归档</a></p>
</main>

<footer class="site-foot">
  <div class="wrap">
    <p>拾光小记 · 影像与随笔 · 2019-2026 · 站点放在一台小机器上，视频没套 CDN，加载慢请体谅。</p>
  </div>
</footer>
</body>
</html>
EOF_P1
    cat > "$SITE_ROOT/posts/yangtai-zhiwu.html" <<EOF_P2
<!DOCTYPE html>
<html lang="zh-CN">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width,initial-scale=1">
<meta name="description" content="阳台植物记录：搬家换朝向之后，薄荷疯长，绿萝蔫了，植物们重新表态。">
<title>阳台植物记录：薄荷疯了，绿萝蔫了 · 拾光小记</title>
<link rel="icon" href="/favicon.ico">
<link rel="stylesheet" href="/assets/style.css">
</head>
<body>
<header class="site-head">
  <div class="wrap">
    <a class="brand" href="/">拾光小记</a>
    <nav>
      <a href="/">首页</a>
      <a href="/video.html">影像</a>
      <a href="/wallpaper.html">壁纸</a>
      <a href="/archive.html">随笔</a>
      <a href="/about.html">关于</a>
    </nav>
  </div>
</header>

<main class="wrap">
  <article>
    <h1 class="post-title">阳台植物记录：薄荷疯了，绿萝蔫了</h1>
    <p class="post-meta">2026-09-20 · 约 5 分钟</p>

    <p>搬家最大的变化不是房子，是阳台——从朝北换成了朝东南。搬完第一个月，所有植物都开始重新表态，有的表态非常激烈。</p>

    <h3>薄荷：疯长</h3>
    <p>以前在朝北阳台，薄荷长得像个客气人，一个月窜一茬，掐下来泡水勉强够两杯。现在每天早上拉开窗帘，它都和昨天不一样。九月初掐了一大轮做薄荷柠檬水，两周之后又满了。查了下说是每天四小时以上的直射光对它来说正好，加上东南向早上不晒、通风好，等于给它开了自助餐。</p>
    <p>唯一的烦恼是要常掐，不然下部容易木质化。以及，<strong>别信"薄荷特别好养"这句话的一半</strong>——它是好养，但它抢水分的能力也好得很，旁边那盆迷迭香已经被它压得没脾气了。</p>

    <h3>绿萝：蔫</h3>
    <p>绿萝是全家最惨的。它在旧家的朝北阳台住了两年，习惯了低光，如今搬到东南向，头两周叶子直接晒出一圈焦边，蔫得像被班主任批评过。查了资料说是"光适应"，强光对它反而过头。现在的方案是往阳台内侧挪了一米，挂个半遮光的纱帘，早上十点后拉上。三周过去新叶终于正常了，颜色比以前深，也算因祸得福。</p>

    <h3>小结</h3>
    <p>阳台种植这件事，朝向比勤快重要。以前浇水浇得再勤，光照不够就是不够；现在光照管够，反倒是出差三天回来要注意补水。植物不会说话，但它们表态的方式比人直接得多。</p>
    <p>下一步想试试矮生小番茄，等十月底降温再入苗，先立个字据在这里。</p>
  </article>
  <p class="back"><a href="/archive.html">← 回归档</a></p>
</main>

<footer class="site-foot">
  <div class="wrap">
    <p>拾光小记 · 影像与随笔 · 2019-2026 · 站点放在一台小机器上，视频没套 CDN，加载慢请体谅。</p>
  </div>
</footer>
</body>
</html>
EOF_P2
    cat > "$SITE_ROOT/posts/tubu-qingdan.html" <<EOF_P3
<!DOCTYPE html>
<html lang="zh-CN">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width,initial-scale=1">
<meta name="description" content="秋季徒步装备清单：换过三个背包和两次淋雨之后总结的笨办法。">
<title>秋季徒步装备清单：从背包到袜子的笨办法 · 拾光小记</title>
<link rel="icon" href="/favicon.ico">
<link rel="stylesheet" href="/assets/style.css">
</head>
<body>
<header class="site-head">
  <div class="wrap">
    <a class="brand" href="/">拾光小记</a>
    <nav>
      <a href="/">首页</a>
      <a href="/video.html">影像</a>
      <a href="/wallpaper.html">壁纸</a>
      <a href="/archive.html">随笔</a>
      <a href="/about.html">关于</a>
    </nav>
  </div>
</header>

<main class="wrap">
  <article>
    <h1 class="post-title">秋季徒步装备清单：从背包到袜子的笨办法</h1>
    <p class="post-meta">2026-11-02 · 约 7 分钟</p>

    <p>这份清单的含金量在于：它不是从攻略抄的，是花两次淋雨、一双磨破的袜子和三个背包换来的。十月天气说翻脸就翻脸，写下来给自己打包时对照用。</p>

    <h3>背包：够用就好</h3>
    <p>一日线我最终留了个 22L 的。之前先是嫌小换了 28L，结果装满了重得像背了个孩子；又换回 16L，发现雨衣和保温层根本塞不下。22L 刚好：水、雨具、备用中层、一点吃的，还有位置塞下山时脱掉的衣服。<strong>背包这件事没有终点，只有够用。</strong></p>

    <h3>穿衣：洋葱不是比喻</h3>
    <p>秋天走山的正确打开方式是三层：贴身速干（别穿棉 T，湿了不干是真的会冷）、中间薄抓绒、外面压胶冲锋衣。冲锋衣是去年咬牙买的，今年十月那场雨里它值回了票价。出发点冷不要紧，走二十分钟你会感谢自己少穿了。</p>

    <h3>那些小东西</h3>
    <ul>
      <li>袜子比鞋重要，羊毛徒步袜，备一双放包里，过水之后换袜子是人间至乐；</li>
      <li>头灯带一个，去年下山天黑比预期早，手机手电筒照不了路只能照心情；</li>
      <li>保温壶装热水，山顶那一口热茶能原谅整段爬升；</li>
      <li>垃圾袋带两个，一个装自己的垃圾，一个备用——淋雨时它能保住你的干衣服。</li>
    </ul>

    <h3>最后</h3>
    <p>装备清单的意义不是买齐，是出发前五分钟不用动脑。今年还剩一个多月，争取在元旦前把西边那条线走完。到时候再来更新一篇。</p>
  </article>
  <p class="back"><a href="/archive.html">← 回归档</a></p>
</main>

<footer class="site-foot">
  <div class="wrap">
    <p>拾光小记 · 影像与随笔 · 2019-2026 · 站点放在一台小机器上，视频没套 CDN，加载慢请体谅。</p>
  </div>
</footer>
</body>
</html>
EOF_P3
    cat > "$SITE_ROOT/posts/dushu-biji.html" <<EOF_P4
<!DOCTYPE html>
<html lang="zh-CN">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width,initial-scale=1">
<meta name="description" content="十月读书记：三本看完，一本弃了，写点想说的。">
<title>十月读书记：三本看完，一本弃了 · 拾光小记</title>
<link rel="icon" href="/favicon.ico">
<link rel="stylesheet" href="/assets/style.css">
</head>
<body>
<header class="site-head">
  <div class="wrap">
    <a class="brand" href="/">拾光小记</a>
    <nav>
      <a href="/">首页</a>
      <a href="/video.html">影像</a>
      <a href="/wallpaper.html">壁纸</a>
      <a href="/archive.html">随笔</a>
      <a href="/about.html">关于</a>
    </nav>
  </div>
</header>

<main class="wrap">
  <article>
    <h1 class="post-title">十月读书记：三本看完，一本弃了</h1>
    <p class="post-meta">2026-10-28 · 约 8 分钟</p>

    <p>十月过得有点赶，但读书这件事奇怪得很，越忙反而越能挤进去几页——大概因为通勤变长了。这个月四本：三本看完，一本在第 80 页光荣退役。</p>

    <h3>《长夜的独行者》 ★★★★</h3>
    <p>本月的意外之喜。前三十页差点弃掉，中段开始像上坡路走到垭口，一下子全亮了。作者写时间的方式很特别，把三十年的事写得像三天，又把三天写得像三十年。适合秋天晚上一口气读完，然后坐在椅子上发一会儿呆。</p>

    <h3>《山之四季》 ★★★★☆</h3>
    <p>重读。二十多岁读它觉得是"隐居文学"，现在读发现其实是"劳动文学"——大部分篇幅在写种地、修屋、烧炉子，风花雪月只是顺便。配着这个月徒步完下山泡脚的时候看，格外应景。</p>

    <h3>《何以教书》 ★★★</h3>
    <p>讲一位老教师四十年课堂记录的书。好读，但后半本明显是同类内容的排列组合，能感觉出编辑在凑页数。前半本值四星，后半本两星，平均一下三星。适合随手翻，不适合连读。</p>

    <h3>某畅销悬疑（不点名了）</h3>
    <p>第 80 页弃。理由充分：车轱辘话来回说，配角全员工具人，反转全靠"早知道就不告诉你"。它唯一的作用是让我这个月其他几本显得格外好看。弃书不是罪，人生苦短。</p>

    <h3>小结</h3>
    <p>十月合计约 1100 页，比九月多，纯靠通勤。十一月想读点非虚构，手头这本讲咖啡贸易史的已经开了头，写读后感之前，先去把参数笔记里那包危地马拉开了。</p>
  </article>
  <p class="back"><a href="/archive.html">← 回归档</a></p>
</main>

<footer class="site-foot">
  <div class="wrap">
    <p>拾光小记 · 影像与随笔 · 2019-2026 · 站点放在一台小机器上，视频没套 CDN，加载慢请体谅。</p>
  </div>
</footer>
</body>
</html>
EOF_P4
    cat > "$SITE_ROOT/sitemap.xml" <<EOF_SITEMAP
<?xml version="1.0" encoding="UTF-8"?>
<urlset xmlns="http://www.sitemaps.org/schemas/sitemap/0.9">
  <url><loc>https://${DOMAIN}/</loc><lastmod>2026-11-12</lastmod><priority>1.0</priority></url>
  <url><loc>https://${DOMAIN}/video.html</loc><lastmod>2026-11-12</lastmod><priority>0.9</priority></url>
  <url><loc>https://${DOMAIN}/wallpaper.html</loc><lastmod>2026-11-12</lastmod><priority>0.8</priority></url>
  <url><loc>https://${DOMAIN}/archive.html</loc><lastmod>2026-11-02</lastmod><priority>0.6</priority></url>
  <url><loc>https://${DOMAIN}/about.html</loc><lastmod>2026-11-12</lastmod><priority>0.5</priority></url>
  <url><loc>https://${DOMAIN}/video/auto-xingxie.html</loc><lastmod>2026-11-12</lastmod><priority>0.7</priority></url>
  <url><loc>https://${DOMAIN}/video/auto-yuanbao.html</loc><lastmod>2026-11-05</lastmod><priority>0.7</priority></url>
  <url><loc>https://${DOMAIN}/video/tushi-erhao.html</loc><lastmod>2026-10-24</lastmod><priority>0.7</priority></url>
  <url><loc>https://${DOMAIN}/video/fenxing-piaoliu.html</loc><lastmod>2026-10-15</lastmod><priority>0.7</priority></url>
  <url><loc>https://${DOMAIN}/video/jianbian-zhiye.html</loc><lastmod>2026-10-03</lastmod><priority>0.7</priority></url>
  <url><loc>https://${DOMAIN}/video/chenhun-xian.html</loc><lastmod>2026-09-24</lastmod><priority>0.7</priority></url>
  <url><loc>https://${DOMAIN}/posts/tubu-qingdan.html</loc><lastmod>2026-11-02</lastmod><priority>0.6</priority></url>
  <url><loc>https://${DOMAIN}/posts/dushu-biji.html</loc><lastmod>2026-10-28</lastmod><priority>0.6</priority></url>
  <url><loc>https://${DOMAIN}/posts/shouchong-biji.html</loc><lastmod>2026-10-12</lastmod><priority>0.6</priority></url>
  <url><loc>https://${DOMAIN}/posts/yangtai-zhiwu.html</loc><lastmod>2026-09-20</lastmod><priority>0.6</priority></url>
</urlset>
EOF_SITEMAP
    cat > "$SITE_ROOT/robots.txt" <<EOF_ROBOTS
User-agent: *
Allow: /

Sitemap: https://${DOMAIN}/sitemap.xml
EOF_ROBOTS

    write_video_pages
    ok "网站已生成: 首页/影像播放页/壁纸/随笔/关于/404"

    echo 'ok' > "$SITE_ROOT/healthz"
    ok "健康检查文件: /healthz"

    # favicon.ico（16/32/48 三尺寸，赭橙底米白菱形）
    if command -v python3 >/dev/null 2>&1; then
        python3 - "$SITE_ROOT/favicon.ico" <<'PYEOF'
import struct, sys
def rs(s, r, m=0):
    out=[]
    for y in range(s):
        row=[]
        for x in range(s):
            ok = m <= x <= s-1-m and m <= y <= s-1-m
            if ok:
                if x < m+r and y < m+r: ok = (x-m-r)**2+(y-m-r)**2 <= r*r
                elif x > s-1-m-r and y < m+r: ok = (x-s+1+m+r)**2+(y-m-r)**2 <= r*r
                elif x < m+r and y > s-1-m-r: ok = (x-m-r)**2+(y-s+1+m+r)**2 <= r*r
                elif x > s-1-m-r and y > s-1-m-r: ok = (x-s+1+m+r)**2+(y-s+1+m+r)**2 <= r*r
            row.append(ok)
        out.append(row)
    return out
imgs=[]
for s in (16,32,48):
    sq=rs(s,max(2,int(s*0.22))); cx=cy=(s-1)/2; k=s*0.30; px=[]
    for y in range(s):
        row=[]
        for x in range(s):
            if sq[y][x]:
                row.append((250,248,243,255) if abs(x-cx)+abs(y-cy)<=k else (60,98,177,255))
            else:
                row.append((0,0,0,0))
        px.append(row)
    hdr=struct.pack('<IiiHHIIiiII',40,s,s*2,1,32,0,0,0,0,0,0)
    data=b''
    for y in range(s-1,-1,-1):
        for x in range(s):
            data+=bytes(px[y][x])
    imgs.append((s,hdr+data+b'\x00'*(((s+31)//32)*4)*s))
out=struct.pack('<HHH',0,1,len(imgs)); off=6+16*len(imgs); ent=b''; blob=b''
for size,blk in imgs:
    ent+=struct.pack('<BBBBHHII',size%256,size%256,0,0,1,32,len(blk),off)
    off+=len(blk); blob+=blk
open(sys.argv[1],'wb').write(out+ent+blob)
PYEOF
        ok "favicon.ico 已生成"
    else
        warn "系统缺少 python3，跳过 favicon（不影响使用）"
    fi
}

# =============================================================================
#  步骤 5：nginx 先跑 80（给 ACME 验证用）
# =============================================================================
write_nginx_http() {
    mkdir -p "$(dirname "$NGINX_AVAIL")"
    cat > "$NGINX_AVAIL" <<NGINX
# 由 selfsteal-install.sh 生成 —— HTTP 阶段（仅 ACME 验证 + 跳转）
server {
    listen 80;
    listen [::]:80;
    server_name ${DOMAIN};

    location /.well-known/acme-challenge/ {
        root ${ACME_ROOT};
        default_type text/plain;
    }

    location / {
        return 301 https://\$host\$request_uri;
    }
}
NGINX
    [[ -n $NGINX_LINK ]] && { mkdir -p "$(dirname "$NGINX_LINK")"; ln -sf "$NGINX_AVAIL" "$NGINX_LINK"; }
    clean_stale_nginx_site

    # Debian 默认站点会抢 80，先禁用
    rm -f /etc/nginx/sites-enabled/default 2>/dev/null
    rm -f /etc/nginx/conf.d/default.conf 2>/dev/null

    nginx -t >/dev/null 2>&1 || { nginx -t; die "nginx 配置校验失败（HTTP 阶段）"; }
    systemctl reload nginx 2>/dev/null || systemctl restart nginx
    ok "nginx 已在 80 端口就绪（ACME 验证路径）"
}

# =============================================================================
#  步骤 6：签发证书
# =============================================================================
step_issue_cert() {
    line; msg "步骤 5/8  申请证书（Let's Encrypt）"; line

    if [[ -f /etc/letsencrypt/live/${DOMAIN}/fullchain.pem ]]; then
        ok "证书已存在，跳过申请"
        return 0
    fi

    local args=(certonly --webroot -w "$ACME_ROOT" -d "$DOMAIN" --agree-tos --non-interactive)
    if [[ -n $EMAIL ]]; then
        args+=(-m "$EMAIL")
    else
        args+=(--register-unsafely-without-email)
    fi

    msg "证书申请中（需要 80 端口公网可达）..."
    if ! certbot "${args[@]}"; then
        err "证书申请失败"
        echo -e "  ${gray}排查：① DNS 是否真的指向本机 ② 云厂商安全组是否放行 80 ③ 80 是否被墙${none}"
        return 1
    fi
    ok "证书已签发: /etc/letsencrypt/live/${DOMAIN}/"

    # 自动续期后 reload nginx
    mkdir -p "$(dirname "$CERT_HOOK")"
    cat > "$CERT_HOOK" <<'HOOK'
#!/bin/sh
systemctl reload nginx 2>/dev/null || true
HOOK
    chmod +x "$CERT_HOOK"
    ok "续期钩子已写入: $CERT_HOOK"
}

# =============================================================================
#  步骤 7：nginx 切到 127.0.0.1:8443（HTTPS + http2 + TLS1.3）
# =============================================================================
write_nginx_tls() {
    cat > "$NGINX_AVAIL" <<NGINX
# 由 selfsteal-install.sh 生成 —— HTTPS 阶段（仅回环监听，供 Reality 回落）
server {
    listen 127.0.0.1:${SITE_PORT} ssl http2;
    server_name ${DOMAIN};

    ssl_certificate     /etc/letsencrypt/live/${DOMAIN}/fullchain.pem;
    ssl_certificate_key /etc/letsencrypt/live/${DOMAIN}/privkey.pem;
    ssl_protocols       TLSv1.2 TLSv1.3;
    ssl_ciphers         HIGH:!aNULL:!MD5;
    ssl_session_cache   shared:SSL:10m;
    ssl_session_timeout 1d;

    root  ${SITE_ROOT};
    index index.html;
    error_page 404 /404.html;

    add_header X-Content-Type-Options nosniff;
    add_header X-Frame-Options SAMEORIGIN;

    location = /healthz {
        default_type application/json;
        return 200 '{"status":"ok","service":"api-gateway"}';
    }

    # 媒体限速：防止伪装站被恶意刷流量
    location /media/ {
        limit_rate ${MEDIA_RATE};
        limit_rate_after 1m;
    }

    location / {
        try_files \$uri \$uri/ =404;
    }
}

server {
    listen 80;
    listen [::]:80;
    server_name ${DOMAIN};

    location /.well-known/acme-challenge/ {
        root ${ACME_ROOT};
        default_type text/plain;
    }

    location / {
        return 301 https://\$host\$request_uri;
    }
}
NGINX

    nginx -t >/dev/null 2>&1 || { nginx -t; die "nginx 配置校验失败（HTTPS 阶段）"; }
    systemctl reload nginx || systemctl restart nginx
    ok "nginx 已切到 127.0.0.1:${SITE_PORT}（对外不可见）"

    # 自检：8443 必须只监听回环
    if ss -tln | awk '{print $4}' | grep -qE "0\.0\.0\.0:${SITE_PORT}|\[::\]:${SITE_PORT}"; then
        warn "检测到 ${SITE_PORT} 监听在非回环地址，请检查 nginx 配置！"
    else
        ok "确认 ${SITE_PORT} 仅监听 127.0.0.1"
    fi
}

# =============================================================================
#  步骤 8：安装并配置 sing-box
# =============================================================================
install_singbox_bin() {
    if [[ -x $SB_BIN ]]; then
        ok "sing-box 已存在: $($SB_BIN version 2>/dev/null | head -1)"
        return 0
    fi

    local ver url tmp
    # 先跟随 releases/latest 的 302 拿 tag（不受 GitHub API 限流影响）
    ver=$(curl -fsSLI -o /dev/null -w '%{url_effective}' --max-time 20 \
          https://github.com/SagerNet/sing-box/releases/latest 2>/dev/null | sed 's#.*/tag/##')
    [[ ! $ver =~ ^v[0-9] ]] && {
        ver=$(curl -fsSL --max-time 20 https://api.github.com/repos/SagerNet/sing-box/releases/latest \
              | grep -oE '"tag_name": *"[^"]+"' | head -1 | cut -d'"' -f4)
    }
    [[ ! $ver =~ ^v[0-9] ]] && die "无法获取 sing-box 版本号（网络或 GitHub 不可达）"

    url="https://github.com/SagerNet/sing-box/releases/download/${ver}/sing-box-${ver#v}-linux-${ARCH}.tar.gz"
    msg "下载 sing-box ${ver} ..."
    tmp=$(mktemp -d)
    if ! curl -fL --retry 3 --max-time 120 "$url" -o "$tmp/sb.tar.gz"; then
        rm -rf "$tmp"; die "下载失败: $url"
    fi
    mkdir -p "$SB_DIR"
    tar -xzf "$tmp/sb.tar.gz" -C "$SB_DIR" --strip-components=1 || { rm -rf "$tmp"; die "解压失败"; }
    rm -rf "$tmp"
    chmod +x "$SB_BIN"
    ln -sf "$SB_BIN" /usr/local/bin/sing-box
    ok "sing-box 已安装: $($SB_BIN version 2>/dev/null | head -1)"
}

# 记录状态供菜单复用（凭据不落此文件，仅存于 config.json）
save_state() {
    cat > "$STATE_FILE" <<ENV
DOMAIN=${DOMAIN}
UUID=${UUID}
PUB=${PUB}
REALITY_PORT=${REALITY_PORT}
SITE_PORT=${SITE_PORT}
PUB_IP=${PUB_IP}
LP_ENABLED=${LP_ENABLED:-0}
LP_IN_PORT=${LP_IN_PORT:-}
ENV
    chmod 600 "$STATE_FILE"
}

# 从现有 config.json 读回落地列表（含旧单落地配置的迁移）
load_landing_list() {
    LP_NAMES=(); LP_UUIDS=(); LP_TYPES=(); LP_SERVERS=(); LP_SPORTS=(); LP_USERS=(); LP_PASSES=()
    LP_LIST_LOADED=1
    [[ -f $SB_CONF ]] || { LP_ENABLED=${LP_ENABLED:-0}; return 0; }

    local n t
    if jq -e '.inbounds[]? | select(.tag=="vless-landing")' "$SB_CONF" >/dev/null 2>&1; then
        LP_IN_PORT=$(jq -r '.inbounds[] | select(.tag=="vless-landing") | .listen_port' "$SB_CONF")
        mapfile -t LP_NAMES < <(jq -r '.inbounds[] | select(.tag=="vless-landing") | .users[]?.name // empty' "$SB_CONF" 2>/dev/null)
        for n in "${LP_NAMES[@]}"; do
            LP_UUIDS+=("$(jq -r --arg n "$n" '.inbounds[] | select(.tag=="vless-landing") | .users[] | select(.name==$n) | .uuid' "$SB_CONF")")
            t=$(jq -r --arg n "$n" '.outbounds[] | select(.tag==$n) | .type' "$SB_CONF")
            [[ $t == socks ]] && t=socks5
            LP_TYPES+=("$t")
            LP_SERVERS+=("$(jq -r --arg n "$n" '.outbounds[] | select(.tag==$n) | .server' "$SB_CONF")")
            LP_SPORTS+=("$(jq -r --arg n "$n" '.outbounds[] | select(.tag==$n) | .server_port' "$SB_CONF")")
            LP_USERS+=("$(jq -r --arg n "$n" '.outbounds[] | select(.tag==$n) | .username // empty' "$SB_CONF")")
            LP_PASSES+=("$(jq -r --arg n "$n" '.outbounds[] | select(.tag==$n) | .password // empty' "$SB_CONF")")
        done
    fi

    # 兼容旧版单落地（用户无 name、出站 tag=residential）→ 迁移为 landing-a
    if [[ ${#LP_NAMES[@]} -eq 0 ]] && jq -e '.outbounds[]? | select(.tag=="residential")' "$SB_CONF" >/dev/null 2>&1; then
        t=$(jq -r '.outbounds[] | select(.tag=="residential") | .type' "$SB_CONF")
        [[ $t == socks ]] && t=socks5
        LP_NAMES=("landing-a")
        LP_UUIDS+=("$(jq -r '.inbounds[] | select(.tag=="vless-landing") | .users[0].uuid' "$SB_CONF")")
        LP_TYPES+=("$t")
        LP_SERVERS+=("$(jq -r '.outbounds[] | select(.tag=="residential") | .server' "$SB_CONF")")
        LP_SPORTS+=("$(jq -r '.outbounds[] | select(.tag=="residential") | .server_port' "$SB_CONF")")
        LP_USERS+=("$(jq -r '.outbounds[] | select(.tag=="residential") | .username // empty' "$SB_CONF")")
        LP_PASSES+=("$(jq -r '.outbounds[] | select(.tag=="residential") | .password // empty' "$SB_CONF")")
    fi

    [[ ${#LP_NAMES[@]} -gt 0 ]] && LP_ENABLED=1 || LP_ENABLED=0
    return 0
}

# 生成 sing-box 配置（主节点直连 + 可选落地节点走住宅代理，互不影响）
write_singbox_config() {
    # 先从现有配置读回密钥对与落地列表，再覆盖写入（顺序不可颠倒，否则落地丢失）
    if [[ -f $SB_CONF ]]; then
        [[ -z $PRIV ]] && PRIV=$(jq -r '.inbounds[0].tls.reality.private_key // empty' "$SB_CONF" 2>/dev/null)
    fi
    [[ -z $PRIV ]] && die "Reality 私钥缺失，无法生成配置"
    [[ $LP_LIST_LOADED == 0 ]] && load_landing_list

    cat > "$SB_CONF" <<JSON
{
  "log": {
    "level": "warn",
    "timestamp": true
  },
  "inbounds": [
    {
      "type": "vless",
      "tag": "vless-reality",
      "listen": "::",
      "listen_port": ${REALITY_PORT},
      "users": [
        {
          "uuid": "${UUID}",
          "flow": "xtls-rprx-vision"
        }
      ],
      "tls": {
        "enabled": true,
        "server_name": "${DOMAIN}",
        "reality": {
          "enabled": true,
          "handshake": {
            "server": "127.0.0.1",
            "server_port": ${SITE_PORT}
          },
          "private_key": "${PRIV}",
          "short_id": [""]
        }
      }
    }
  ],
  "outbounds": [
    { "type": "direct", "tag": "direct" }
  ]
}
JSON

    # 多落地：一个入站多用户（按 name 分流），共用一个节点端口
    if [[ ${LP_ENABLED:-0} == 1 && ${#LP_NAMES[@]} -gt 0 && -n ${LP_IN_PORT:-} ]]; then
        local i otype auth users="[" outs="[" rules="[" first=""
        for i in "${!LP_NAMES[@]}"; do
            otype=http
            [[ ${LP_TYPES[$i]} == socks5 || ${LP_TYPES[$i]} == socks ]] && otype=socks
            auth="{}"
            [[ -n ${LP_USERS[$i]} ]] && auth=$(jq -nc --arg u "${LP_USERS[$i]}" --arg p "${LP_PASSES[$i]}" '{username:$u,password:$p}')
            users+=$(jq -nc --arg n "${LP_NAMES[$i]}" --arg u "${LP_UUIDS[$i]}" '{name:$n,uuid:$u}')","
            outs+=$(jq -nc --arg t "$otype" --arg tag "${LP_NAMES[$i]}" \
                        --arg s "${LP_SERVERS[$i]}" --argjson p "${LP_SPORTS[$i]}" --argjson a "$auth" \
                        '{type:$t,tag:$tag,server:$s,server_port:$p} + $a')","
            rules+=$(jq -nc --arg tag "${LP_NAMES[$i]}" '{auth_user:[$tag],action:"route",outbound:$tag}')","
            [[ -z $first ]] && first="${LP_NAMES[$i]}"
        done
        users="${users%,}]"; outs="${outs%,}]"; rules="${rules%,}]"

        local tmp; tmp=$(mktemp)
        if ! jq --argjson users "$users" --argjson outs "$outs" --argjson rules "$rules" \
             --arg first "$first" --argjson lport "${LP_IN_PORT}" \
             --arg sni "$DOMAIN" --arg key "$PRIV" --argjson sport "${SITE_PORT}" '
            .inbounds += [{
              type: "vless", tag: "vless-landing",
              listen: "::", listen_port: $lport,
              users: $users,
              tls: {enabled: true, server_name: $sni,
                reality: {enabled: true,
                  handshake: {server: "127.0.0.1", server_port: $sport},
                  private_key: $key, short_id: [""]}}
            }]
            | .outbounds += $outs
            | .route = {
                rules: ($rules + [{inbound: ["vless-landing"], action: "route", outbound: $first}]),
                final: "direct"
              }
        ' "$SB_CONF" > "$tmp"; then
            rm -f "$tmp"; die "落地配置生成失败"
        fi
        mv -f "$tmp" "$SB_CONF"
    fi
}

step_write_singbox() {
    line; msg "步骤 6/8  配置 sing-box Reality"; line

    install_singbox_bin
    mkdir -p "$SB_CONF_DIR"

    if [[ -z $UUID ]]; then
        UUID=$($SB_BIN generate uuid)
    fi
    [[ -z $UUID ]] && die "UUID 生成失败"

    # 已有配置时沿用现有密钥对，避免重装导致客户端链接失效
    local old_priv
    old_priv=$(jq -r '.inbounds[0].tls.reality.private_key // empty' "$SB_CONF" 2>/dev/null)
    if [[ -n $old_priv && -n $PUB ]]; then
        PRIV=$old_priv
        ok "沿用现有 Reality 密钥对（客户端链接不变）"
    else
        local kp
        kp=$($SB_BIN generate reality-keypair) || die "Reality 密钥生成失败"
        PRIV=$(echo "$kp" | awk -F': *' '/PrivateKey/{print $2}')
        PUB=$(echo "$kp" | awk -F': *' '/PublicKey/{print $2}')
        [[ -z $PRIV || -z $PUB ]] && die "Reality 密钥解析失败"
    fi

    write_singbox_config

    $SB_BIN check -c "$SB_CONF" || die "sing-box 配置校验失败"
    ok "配置已写入并通过 check"

    cat > "$SB_SVC" <<UNIT
[Unit]
Description=sing-box service
Documentation=https://sing-box.sagernet.org
After=network.target nss-lookup.target

[Service]
User=root
CapabilityBoundingSet=CAP_NET_ADMIN CAP_NET_BIND_SERVICE
AmbientCapabilities=CAP_NET_ADMIN CAP_NET_BIND_SERVICE
NoNewPrivileges=true
ExecStart=${SB_BIN} run -c ${SB_CONF}
Restart=on-failure
RestartSec=10
LimitNOFILE=infinity

[Install]
WantedBy=multi-user.target
UNIT

    systemctl daemon-reload
    systemctl enable sing-box >/dev/null 2>&1
    systemctl restart sing-box
    sleep 2

    if systemctl is-active --quiet sing-box; then
        ok "sing-box 已启动并设为开机自启"
    else
        journalctl -u sing-box -n 20 --no-pager | sed 's/^/     /'
        die "sing-box 启动失败，见上方日志"
    fi

    if port_busy $REALITY_PORT; then
        ok "端口 ${REALITY_PORT} 已监听"
    else
        warn "端口 ${REALITY_PORT} 未监听，请检查日志"
    fi

    # 记录状态供菜单复用
    save_state
    ok "状态已记录: $STATE_FILE"
}

# =============================================================================
#  客户端链接
# =============================================================================
show_link() {
    if ! load_state; then
        err "尚未安装或状态文件缺失（$STATE_FILE）"
        return 1
    fi
    local link="vless://${UUID}@${PUB_IP}:${REALITY_PORT}?encryption=none&flow=xtls-rprx-vision&security=reality&sni=${DOMAIN}&fp=chrome&pbk=${PUB}&type=tcp#${DOMAIN}"
    line; msg "客户端链接"; line
    echo
    echo -e "${green}${link}${none}"
    echo
    echo -e "  ${gray}参数：地址 ${PUB_IP}  端口 ${REALITY_PORT}  SNI ${DOMAIN}  flow xtls-rprx-vision  fp chrome${none}"
    echo -e "  ${gray}公钥 ${PUB}${none}"
    if [[ $LP_LIST_LOADED == 0 ]] && [[ -f $SB_CONF ]]; then load_landing_list; fi
    if [[ ${#LP_NAMES[@]} -gt 0 && -n ${LP_IN_PORT:-} ]]; then
        local i llink
        for i in "${!LP_NAMES[@]}"; do
            llink="vless://${LP_UUIDS[$i]}@${PUB_IP}:${LP_IN_PORT}?encryption=none&security=reality&sni=${DOMAIN}&fp=chrome&pbk=${PUB}&type=tcp#${DOMAIN}-${LP_NAMES[$i]}"
            echo
            echo -e "  ${gray}── 落地 ${LP_NAMES[$i]}（出口 ${LP_TYPES[$i]}://${LP_SERVERS[$i]}:${LP_SPORTS[$i]}，无 flow）──${none}"
            echo -e "  ${green}${llink}${none}"
        done
        echo -e "  ${gray}落地链接全部共用节点端口 ${LP_IN_PORT}，各走各的住宅出口；主节点不受影响${none}"
    fi
    echo
    echo -e "  ${gray}把整条链接复制进客户端导入即可（支持 v2rayN / sing-box / Shadowrocket 等）${none}"
    echo
}

# =============================================================================
#  状态
# =============================================================================
show_status() {
    line; msg "运行状态"; line
    if [[ ! -f $SB_CONF ]]; then
        warn "未检测到安装（$SB_CONF 不存在）"
        return 1
    fi
    local d u p ip
    if load_state; then
        d=$DOMAIN; u=$UUID; p=$PUB; ip=$PUB_IP
    else
        d=$(jq -r '.inbounds[0].tls.server_name // "?"' "$SB_CONF" 2>/dev/null)
        u=$(jq -r '.inbounds[0].users[0].uuid // "?"' "$SB_CONF" 2>/dev/null)
    fi

    echo "  域名      : ${d:-?}"
    echo "  节点端口  : ${REALITY_PORT}（Reality）"
    echo "  回落端口  : 127.0.0.1:${SITE_PORT}（nginx，仅本机）"
    echo "  sing-box  : $(systemctl is-active sing-box 2>/dev/null) / $(systemctl is-enabled sing-box 2>/dev/null)"
    echo "  nginx     : $(systemctl is-active nginx 2>/dev/null) / $(systemctl is-enabled nginx 2>/dev/null)"
    echo "  证书到期  : $(openssl x509 -in /etc/letsencrypt/live/${d}/fullchain.pem -noout -enddate 2>/dev/null | cut -d= -f2 || echo '未知')"
    echo "  拥塞控制  : $(sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null) / $(sysctl -n net.core.default_qdisc 2>/dev/null)"
    if [[ $LP_LIST_LOADED == 0 ]] && [[ -f $SB_CONF ]]; then load_landing_list; fi
    if [[ ${#LP_NAMES[@]} -gt 0 ]]; then
        echo "  落地代理  : ${#LP_NAMES[@]} 个，共用节点端口 ${LP_IN_PORT}"
        local i
        for i in "${!LP_NAMES[@]}"; do
            echo "               - ${LP_NAMES[$i]}  ${LP_TYPES[$i]}://${LP_SERVERS[$i]}:${LP_SPORTS[$i]}"
        done
    else
        echo "  落地代理  : 未配置"
    fi
    echo
    echo "  监听："
    local pat=":(${REALITY_PORT}|${SITE_PORT}|80)\\b"
    [[ ${#LP_NAMES[@]} -gt 0 && -n ${LP_IN_PORT:-} ]] && pat=":(${REALITY_PORT}|${SITE_PORT}|80|${LP_IN_PORT})\\b"
    ss -tlnp 2>/dev/null | grep -E "$pat" | sed 's/^/    /'
    echo
    echo "  回落自检（本机访问 8443）："
    curl -sk -o /dev/null -w "    HTTP %{http_code} / TLS %{time_appconnect}s\n" "https://127.0.0.1:${SITE_PORT}/" 2>/dev/null || echo "    ✘ 无法连接"
}

# =============================================================================
#  主安装流程
# =============================================================================
# =============================================================================
#  伪装站媒体库（可选）：6 支生成艺术视频 + 12 张壁纸，约 302MB
#  临时安装 ffmpeg，生成完自动卸载；已存在的文件自动跳过
# =============================================================================

MEDIA_PACK_URL_FILE=/opt/selfsteal/media-pack.url
DEFAULT_MEDIA_URL="https://github.com/whitejia007/selfsteal-media/releases/download/media/selfsteal-media.tar.gz"

# 从 GitHub Release 拉取媒体包（推荐：低配 VPS 也无压力）
step_fetch_media() {
    local MROOT="$SITE_ROOT/media"
    if [[ -s $MROOT/video/auto-xingxie.mp4 && -s $MROOT/wallpaper/wp-12.png ]]; then
        ok "媒体库已存在，跳过"
        return 0
    fi

    line; msg "拉取伪装站媒体库（GitHub Release）"; line

    local URL="${1:-}"
    if [[ -z $URL ]]; then
        [[ -s $MEDIA_PACK_URL_FILE ]] && URL=$(cat "$MEDIA_PACK_URL_FILE")
    fi
    [[ -z $URL ]] && URL="$DEFAULT_MEDIA_URL"
    if [[ -z $URL ]]; then
        ask "输入 GitHub 媒体包直链（如 https://github.com/<用户>/<仓库>/releases/download/media/selfsteal-media.tar.gz）" ""
        URL=$REPLY
        if [[ -z $URL ]]; then
            warn "未提供地址。低配机器不建议本地生成（--media-gen），媒体库稍后再拉取"
            return 1
        fi
    fi
    echo "$URL" > "$MEDIA_PACK_URL_FILE"
    chmod 600 "$MEDIA_PACK_URL_FILE"

    local TMP=/tmp/selfsteal-media-pack.tar.gz
    msg "下载中（约300MB，断点续传，视网络需1-5分钟）..."
    if ! curl -fL --retry 3 -C - --connect-timeout 20 -o "$TMP" "$URL"; then
        err "下载失败：确认仓库为公开、Release 资产存在、链接可直接下载"
        rm -f "$TMP"
        return 1
    fi
    if ! tar -xzf "$TMP" -C "$SITE_ROOT"; then
        err "解压失败（媒体包内应为 media/ 目录结构）"
        rm -f "$TMP"
        return 1
    fi
    rm -f "$TMP"
    [[ -s $MROOT/video/auto-xingxie.mp4 ]] || { err "包内缺少 media/video，请核对打包结构"; return 1; }
    ok "媒体库就位，共 $(du -sm "$MROOT" | awk '{print $1}') MB"
}

# 本地 ffmpeg 生成（备用方案，1核512M 机器不推荐）
step_gen_media_local() {
    local MROOT="$SITE_ROOT/media"
    mkdir -p "$MROOT/video" "$MROOT/thumb" "$MROOT/wallpaper"

    local missing=0 f
    for f in auto-xingxie auto-yuanbao tushi-erhao fenxing-piaoliu jianbian-zhiye chenhun-xian; do
        [[ -s $MROOT/video/$f.mp4 ]] || missing=1
    done
    [[ -s $MROOT/wallpaper/wp-12.png ]] || missing=1
    if [[ $missing == 0 ]]; then
        ok "媒体库已存在，跳过生成"
        return 0
    fi

    line; msg "生成伪装站媒体库（需要几分钟，无需操作）"; line

    local had_ffmpeg=0
    command -v ffmpeg >/dev/null 2>&1 && had_ffmpeg=1
    if [[ $had_ffmpeg == 0 ]]; then
        msg "临时安装 ffmpeg（生成完自动卸载）..."
        apt-get update -qq >/dev/null 2>&1
        apt-get install -y -qq ffmpeg >/dev/null 2>&1 || { err "ffmpeg 安装失败，媒体库未生成"; return 1; }
    fi

    local ENC="-c:v libx264 -preset veryfast -pix_fmt yuv420p -c:a aac -b:a 96k -shortest -movflags +faststart"

    if [[ ! -s $MROOT/video/auto-xingxie.mp4 ]]; then
        ffmpeg -y -loglevel error -f lavfi -i "life=s=1280x720:r=30:mold=8:ratio=0.12:death_color=#2B303B:life_color=#E8C37A" -f lavfi -i "anoisesrc=color=pink:amplitude=0.04:d=180" -t 180 -c:v libx264 -preset veryfast -crf 27 $ENC "$MROOT/video/auto-xingxie.mp4" || warn "星屑·生命游戏 生成失败"
        ok "视频 1/6 星屑 · 生命游戏"
    fi
    if [[ ! -s $MROOT/video/auto-yuanbao.mp4 ]]; then
        ffmpeg -y -loglevel error -f lavfi -i "cellauto=s=1280x720:r=30:rule=110:ratio=0.35:scroll=1:seed=20261121" -f lavfi -i "anoisesrc=color=blue:amplitude=0.05:d=180" -t 180 -vf "lutrgb=r='val*0.30+35':g='val*0.62+25':b='val*0.95+40',vignette=PI/5" -c:v libx264 -preset veryfast -crf 27 $ENC "$MROOT/video/auto-yuanbao.mp4" || warn "元胞·雨夜 生成失败"
        ok "视频 2/6 元胞 · 雨夜 110"
    fi
    if [[ ! -s $MROOT/video/tushi-erhao.mp4 ]]; then
        ffmpeg -y -loglevel error -f lavfi -i "testsrc2=s=1280x720:r=30" -f lavfi -i "anoisesrc=color=violet:amplitude=0.04:d=180" -t 180 -vf "hue=h='t*6':s=1.2,vignette=PI/6" -c:v libx264 -preset veryfast -crf 26 $ENC "$MROOT/video/tushi-erhao.mp4" || warn "图样·色相漫游 生成失败"
        ok "视频 3/6 图样 · 色相漫游"
    fi
    if [[ ! -s $MROOT/video/fenxing-piaoliu.mp4 ]]; then
        ffmpeg -y -loglevel error -f lavfi -i "mandelbrot=s=1280x720:rate=30:end_scale=0.00003:end_pts=2700" -f lavfi -i "anoisesrc=color=pink:amplitude=0.03:d=90" -t 90 -c:v libx264 -preset veryfast -crf 27 $ENC "$MROOT/video/fenxing-piaoliu.mp4" || warn "分形漂流 生成失败"
        ok "视频 4/6 分形漂流（九十秒）"
    fi
    if [[ ! -s $MROOT/video/jianbian-zhiye.mp4 ]]; then
        ffmpeg -y -loglevel error -f lavfi -i "gradients=s=1280x720:r=30:speed=0.03:type=spiral:c0=0x0F1B2D:c1=0xC96F4A:c2=0x2A3A50:c3=0xF2E3D0:nb_colors=4" -f lavfi -i "anoisesrc=color=pink:amplitude=0.04:d=180" -t 180 -c:v libx264 -preset veryfast -crf 21 $ENC "$MROOT/video/jianbian-zhiye.mp4" || warn "渐变之夜 生成失败"
        ok "视频 5/6 渐变之夜"
    fi
    if [[ ! -s $MROOT/video/chenhun-xian.mp4 ]]; then
        ffmpeg -y -loglevel error -f lavfi -i "gradients=s=1280x720:r=30:speed=0.02:type=circular:c0=0x1B2A41:c1=0xE8B15C:c2=0x303C4E:c3=0xD8C7A8:nb_colors=4" -f lavfi -i "anoisesrc=color=velvet:amplitude=0.05:d=180" -t 180 -c:v libx264 -preset veryfast -crf 21 $ENC "$MROOT/video/chenhun-xian.mp4" || warn "晨昏线 生成失败"
        ok "视频 6/6 晨昏线"
    fi

    local W=(
        "wp-01 linear 0x0F1B2D 0xE8A15C 0x2A3A50 0x1B2940"
        "wp-02 radial 0x3A1F14 0xC96F4A 0x8A4B2F 0xF2E3D0"
        "wp-03 spiral 0x22303B 0x6E8CA0 0x3B4A57 0xAFC3CF"
        "wp-04 circular 0x241A38 0xE8B15C 0x453558 0xD8C7A8"
        "wp-05 circular 0x14261C 0x7FA37B 0x2E4A38 0xBFD8B8"
        "wp-06 linear 0x2E3B48 0x9FB4C4 0x47586A 0x1F2730"
        "wp-07 radial 0x2B0A0A 0xD4553A 0x7A2A1C 0xF2C7B8"
        "wp-08 spiral 0x15281E 0x5F9E6E 0x2E5A40 0x9FD8A8"
        "wp-09 linear 0x4A3B28 0xD9BE8A 0x8A7355 0x2A2318"
        "wp-10 circular 0x0B2226 0x3E8E8A 0x1B4A4A 0xA8D8D4"
        "wp-11 circular 0x33222E 0xC98FA8 0x6A4A5A 0xE8D0D8"
        "wp-12 linear 0x0A1428 0x3E6EA8 0x1B3350 0x081020"
    )
    local w
    for w in "${W[@]}"; do
        set -- $w
        [[ -s $MROOT/wallpaper/$1.png ]] || ffmpeg -y -loglevel error -f lavfi -i "gradients=s=1920x1080:r=25:speed=0.02:type=$2:c0=$3:c1=$4:c2=$5:c3=$6:nb_colors=4" -frames:v 1 -c:v png -compression_level 3 "$MROOT/wallpaper/$1.png" || true
        [[ -s $MROOT/thumb/$1.png ]] || ffmpeg -y -loglevel error -i "$MROOT/wallpaper/$1.png" -vf scale=480:270 "$MROOT/thumb/$1.png" || true
    done
    ok "壁纸 12 张已就位"

    for f in auto-xingxie auto-yuanbao tushi-erhao jianbian-zhiye chenhun-xian; do
        [[ -s $MROOT/thumb/$f.png ]] || ffmpeg -y -loglevel error -ss 60 -i "$MROOT/video/$f.mp4" -frames:v 1 -vf scale=480:270 "$MROOT/thumb/$f.png" || true
    done
    [[ -s $MROOT/thumb/fenxing-piaoliu.png ]] || ffmpeg -y -loglevel error -ss 45 -i "$MROOT/video/fenxing-piaoliu.mp4" -frames:v 1 -vf scale=480:270 "$MROOT/thumb/fenxing-piaoliu.png" || true
    ok "视频封面已就位"

    if [[ $had_ffmpeg == 0 ]]; then
        msg "卸载临时 ffmpeg..."
        apt-get purge -y -qq ffmpeg >/dev/null 2>&1
        apt-get autoremove -y -qq >/dev/null 2>&1
        ok "ffmpeg 已卸载，服务器恢复最小依赖"
    fi

    ok "媒体库完成，共 $(du -sm "$MROOT" | awk '{print $1}') MB"
}

# =============================================================================
#  伪装站访问 / 流量统计（sest 命令，仅本机查看）
# =============================================================================

install_stats() {
    mkdir -p /opt/selfsteal
    cat > /opt/selfsteal/selfsteal-stats.sh <<'STATSEOF'
#!/bin/bash
# selfsteal-stats.sh — 伪装站访问/流量统计 + 私密访客页面生成
# 用法：
#   sest [天数]      控制台查看统计
#   sest --html      生成/刷新访客 HTML 页面（cron 每10分钟自动执行）

LIB_DIR=/opt/selfsteal
TOKEN_FILE=$LIB_DIR/stats-token
SITE_ROOT=/var/www/selfsteal
STATE_FILE=/etc/sing-box/state.env
CRON_FILE=/etc/cron.d/selfsteal-visitors
LOGDIR=/var/log/nginx

c1() { printf "\033[36m%s\033[0m\n" "$*"; }

get_domain() {
    [[ -f $STATE_FILE ]] && . "$STATE_FILE" 2>/dev/null
    echo "${DOMAIN:-}"
}

# ---------------- HTML 访客页面 ----------------
gen_html() {
    local DOMAIN; DOMAIN=$(get_domain)
    local TOKEN
    [[ -f $TOKEN_FILE ]] && TOKEN=$(cat "$TOKEN_FILE")
    if [[ -z $TOKEN ]]; then
        echo "缺少 $TOKEN_FILE，无法生成访客页面"
        return 1
    fi
    mkdir -p "$SITE_ROOT/$TOKEN"

    # 数据源：sing-box 日志里每次非认证 TLS 连接 = 一次访客触碰（真实IP）
    local J
    J=$(journalctl -o short-iso -u sing-box --since "-30days" --no-pager 2>/dev/null \
        | grep 'processed invalid connection')

    local TOTAL UNIQ TODAY
    TOTAL=$(grep -c 'from ' <<<"$J")
    UNIQ=$(grep -oE 'from [0-9.]+' <<<"$J" | awk '{print $2}' | sort -u | wc -l)
    TODAY=$(grep "^$(date +%Y-%m-%d)T" <<<"$J" | grep -c 'from ')

    # 聚合表行：IP | 首次 | 最近 | 累计 | 今日
    local ROWS
    ROWS=$(awk -v t="$(date +%Y-%m-%d)" '{
        ts=substr($0,1,19)
        ip=$0; sub(/.* from /,"",ip); sub(/:.*/,"",ip)
        c[ip]++; if(!(ip in f)) f[ip]=ts; l[ip]=ts
        if(ts ~ t) td[ip]++
    } END {
        for(ip in c) printf "%s\t%s\t%s\t%s\t%s\n", c[ip], ip, l[ip], f[ip], td[ip]+0
    }' <<<"$J" | sort -rn | head -60 \
    | awk -F'\t' '{printf "      <tr><td>%s</td><td>%s</td><td>%s</td><td>%s</td><td>%s</td></tr>\n", $2, $4, $3, $1, $5==0?"-":$5}')

    # 最近 25 次触碰明细
    local RECENT
    RECENT=$(grep 'from ' <<<"$J" | tail -25 | tac \
    | awk '{ts=substr($0,1,19); ip=$0; sub(/.* from /,"",ip); sub(/:.*/,"",ip);
           tag="in (443)"; if($0 ~ /vless-landing/) tag="landing (9443)";
           printf "      <tr><td>%s</td><td>%s</td><td>%s</td></tr>\n", ts, ip, tag}')

    # nginx 侧：站点内容被取走了什么
    local NGX
    NGX=$(for f in "$LOGDIR"/access.log "$LOGDIR"/access.log.*; do
              [[ -f $f ]] || continue
              case $f in *.gz) zcat "$f";; *) cat "$f";; esac
          done 2>/dev/null)
    local FALL_REQ MEDIA_MB PATH_ROWS
    FALL_REQ=$(awk '$1=="127.0.0.1"' <<<"$NGX" | wc -l)
    MEDIA_MB=$(awk '$7 ~ /^\/media\// {s+=$10} END{printf "%.1f", s/1024/1024}' <<<"$NGX")
    PATH_ROWS=$(awk '{print $7}' <<<"$NGX" | sort | uniq -c | sort -rn | head -12 \
        | awk '{printf "      <tr><td>%s</td><td>%s</td></tr>\n", $2, $1}')

    cat > "$SITE_ROOT/$TOKEN/index.html" <<HTMLEOF
<!DOCTYPE html>
<html lang="zh-CN">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width,initial-scale=1">
<meta name="robots" content="noindex,nofollow">
<title>访问记录 · 自用</title>
<link rel="icon" href="/favicon.ico">
<link rel="stylesheet" href="/assets/style.css">
<style>
  .stats h2{font-size:18px;margin:28px 0 6px;color:#8f4c2e}
  .stats table{width:100%;border-collapse:collapse;font-size:13.5px;margin:8px 0}
  .stats th,.stats td{border:1px solid #e7e3da;padding:6px 10px;text-align:left}
  .stats th{background:#fffdf8;font-weight:600}
  .stats td.num{font-variant-numeric:tabular-nums}
</style>
</head>
<body>
<header class="site-head">
  <div class="wrap">
    <a class="brand" href="/">拾光小记</a>
    <nav><a href="/">首页</a></nav>
  </div>
</header>
<main class="wrap stats">
  <h1 class="page-title">访问记录 <span style="font-size:13px;color:#7a8288">（站长自用页）</span></h1>
  <p class="page-sub">生成时间：$(date '+%Y-%m-%d %H:%M:%S')（每10分钟自动刷新）</p>

  <h2>总览</h2>
  <table>
    <tr><th>30天内访客触碰</th><th>独立IP</th><th>今日触碰</th><th>站点请求数</th><th>媒体下行</th></tr>
    <tr><td class="num">$TOTAL</td><td class="num">$UNIQ</td><td class="num">$TODAY</td>
        <td class="num">$FALL_REQ</td><td class="num">${MEDIA_MB} MB</td></tr>
  </table>
  <p>说明：每一次"触碰"= 一条到本站的 TLS 连接（浏览器会开多条连接，次数约为实际点击的 1~3 倍）；in=主站443，landing=落地9443。</p>

  <h2>访客排行（最近30天，按累计次数）</h2>
  <table>
    <tr><th>IP</th><th>首次出现</th><th>最近出现</th><th>累计次数</th><th>今日</th></tr>
${ROWS:-      <tr><td colspan="5">暂无数据</td></tr>}
  </table>

  <h2>最近 25 次触碰</h2>
  <table>
    <tr><th>时间</th><th>IP</th><th>入口</th></tr>
${RECENT:-      <tr><td colspan="3">暂无数据</td></tr>}
  </table>

  <h2>站点被访问路径 Top 12</h2>
  <table>
    <tr><th>路径</th><th>次数</th></tr>
${PATH_ROWS:-      <tr><td colspan="2">暂无数据</td></tr>}
  </table>
</main>
<footer class="site-foot"><div class="wrap">
  <p>拾光小记 · 本页为站长私有页面，请勿外传。</p>
</div></footer>
</body>
</html>
HTMLEOF
    chmod 644 "$SITE_ROOT/$TOKEN/index.html"
    echo "访客页面已生成: https://${DOMAIN:-<域名>}/${TOKEN}/"
}

install_cron() {
    if [[ ! -f $CRON_FILE ]]; then
        cat > "$CRON_FILE" <<'CRONEOF'
*/10 * * * * root /opt/selfsteal/selfsteal-stats.sh --html >/dev/null 2>&1
CRONEOF
        chmod 644 "$CRON_FILE"
        echo "定时任务已安装（每10分钟刷新访客页面）"
    fi
}

ensure_token() {
    if [[ ! -f $TOKEN_FILE ]]; then
        tr -dc 'a-f0-9' < /dev/urandom | head -c 32 > "$TOKEN_FILE"
        chmod 600 "$TOKEN_FILE"
    fi
}

# ---------------- 控制台输出 ----------------
console() {
    local DAYS=${1:-30}
    local ALL
    ALL=$(for f in "$LOGDIR"/access.log "$LOGDIR"/access.log.*; do
              [[ -f $f ]] || continue
              case $f in *.gz) zcat "$f" ;; *) cat "$f" ;; esac
          done 2>/dev/null)
    [[ -z $ALL ]] && { echo "没有访问日志"; exit 0; }

    c1 "════════════════════════════════════════"
    c1 "  伪装站访问统计（明细为最近 $DAYS 天，汇总为全量）"
    c1 "════════════════════════════════════════"

    REQ_TOTAL=$(wc -l <<<"$ALL")
    FIRST_TS=$(head -1 <<<"$ALL" | awk -F'[][]' '{print $2}')
    UNIQ_IP=$(awk '{print $1}' <<<"$ALL" | sort -u | wc -l)
    BYTES_MB=$(awk '{s+=$10} END{printf "%.1f", s/1024/1024}' <<<"$ALL")
    MEDIA_MB=$(awk '$7 ~ /^\/media\// {s+=$10} END{printf "%.1f", s/1024/1024}' <<<"$ALL")
    FALLBACK_REQ=$(awk '$1=="127.0.0.1"' <<<"$ALL" | wc -l)

    echo "日志起点   : ${FIRST_TS:-未知}"
    echo "总请求数   : $REQ_TOTAL 次"
    echo "独立来源IP : $UNIQ_IP 个"
    echo "总下行流量 : $BYTES_MB MB"
    echo "其中媒体(/media/)下行: $MEDIA_MB MB"
    echo "经 Reality 回落的请求 : $FALLBACK_REQ 次"

    local TOKEN
    [[ -f $TOKEN_FILE ]] && TOKEN=$(cat "$TOKEN_FILE")
    if [[ -n $TOKEN ]]; then
        echo "访客网页   : https://$(get_domain)/$TOKEN/（每10分钟自动刷新）"
    fi
    echo

    c1 "—— 按天统计（最近 $DAYS 天）——"
    printf "   %-12s %8s %8s %10s\n" 日期 请求 独立IP 下行MB
    awk '
BEGIN{
    m["Jan"]="01";m["Feb"]="02";m["Mar"]="03";m["Apr"]="04";m["May"]="05";m["Jun"]="06"
    m["Jul"]="07";m["Aug"]="08";m["Sep"]="09";m["Oct"]="10";m["Nov"]="11";m["Dec"]="12"
}
{
    dt=substr($4,2,20); split(dt,a,"/"); split(a[3],b,":")
    day=b[1] "-" m[a[2]] "-" a[1]
    req[day]++
    if(!seen[day SUBSEP $1]++) ip[day]++
    by[day]+=$10
    if($7 ~ /^\/media\//) md[day]+=$10
}
END{
    for(d in req)
        printf "%s %d %d %.2f %.2f\n", d, req[d], ip[d], by[d]/1024/1024, md[d]/1024/1024
}' <<<"$ALL" | sort -r | head -n "$DAYS" \
    | awk '{printf "   %-12s %8d %8d %10.2f%s\n", $1, $2, $3, $4, ($5+0>0?" (媒体"$5"MB)":"")}'
    echo

    c1 "—— 触碰节点的来源（sing-box 记录的 TLS 访客，最近 $DAYS 天 Top 15）——"
    journalctl -u sing-box --since "-${DAYS}days" --no-pager 2>/dev/null \
      | grep 'REALITY' | grep -oE 'from [0-9.]+' | awk '{print $2}' \
      | sort | uniq -c | sort -rn | head -15 \
      | awk '{printf "   %-20s %s 次\n", $2, $1}'
    echo

    c1 "—— 参考数字 ——"
    MEDIA_DIR_MB=$(du -sm "$SITE_ROOT/media" 2>/dev/null | awk '{print $1}')
    echo "媒体库占用磁盘 : ${MEDIA_DIR_MB:-0} MB"
    echo "媒体按 256KB/s/连接 限速；VPS 总进出流量以服务商面板为准"
}

case "${1:-}" in
    --html) ensure_token; install_cron >/dev/null; gen_html ;;
    --cron) install_cron ;;
    *)      ensure_token; install_cron >/dev/null; console "$@" ;;
esac

STATSEOF
    chmod +x /opt/selfsteal/selfsteal-stats.sh
    ln -sf /opt/selfsteal/selfsteal-stats.sh /usr/local/bin/sest
}

do_install() {
    clear
    echo
    echo -e "${blue}  selfsteal · 偷自己 Reality 一键部署${none}"
    echo -e "  ${gray}nginx + certbot + sing-box · 零面板 · 最小依赖${none}"
    echo
    line

    step_precheck
    step_install_deps
    step_collect_domain
    step_write_site
    if [[ -f /etc/letsencrypt/live/${DOMAIN}/fullchain.pem ]]; then
        ok "证书已存在，跳过 HTTP 阶段与证书申请"
    else
        line; msg "步骤 4.5/8  写入 nginx（HTTP 阶段）"; line
        write_nginx_http
        step_issue_cert || { err "证书环节失败，网站与 nginx 保留，可修复后重跑"; return 1; }
    fi
    step_write_singbox
    line; msg "步骤 7/8  写入 nginx（HTTPS 阶段）"; line
    write_nginx_tls

    line; msg "步骤 8/8  完成"; line

    ask "是否拉取伪装站媒体库（GitHub，约302MB，已存在则跳过）[Y/n]" "Y"
    if [[ $REPLY == y || $REPLY == Y ]]; then
        step_fetch_media
    fi

    show_link

    echo -e "  ${green}部署完成。${none}"
    echo -e "  ${gray}· 以后随时输入 ${green}se${none}${gray} 进入管理菜单${none}"
    echo -e "  ${gray}· 网站：https://${DOMAIN}（经 Reality 回落显示）${none}"
    echo -e "  ${gray}· 节点：${PUB_IP}:${REALITY_PORT}（Reality + Vision）${none}"
    echo -e "  ${gray}· 证书自动续期由 certbot.timer 负责，续期后自动 reload nginx${none}"
    echo
}

# =============================================================================
#  更换域名（保留节点密钥与 UUID，重新签证书）
# =============================================================================
change_domain() {
    load_state || { err "尚未安装"; return 1; }
    local old=$DOMAIN
    ask "新域名" ""
    [[ -z $REPLY ]] && { warn "未输入，取消"; return 1; }
    DOMAIN=$(echo "$REPLY" | tr -d ' ' | tr 'A-Z' 'a-z')

    msg "校验新域名解析..."
    local r; r=$(getent ahostsv4 "$DOMAIN" | awk '{print $1; exit}')
    [[ $r != "$PUB_IP" ]] && { err "新域名解析($r)未指向本机($PUB_IP)，中止"; return 1; }

    write_nginx_http
    if ! step_issue_cert; then
        err "新证书申请失败，回滚到旧域名 $old"
        DOMAIN=$old
        write_nginx_http; write_nginx_tls
        return 1
    fi

    # 重新生成 sing-box 配置（两个入站的 SNI 一起更新，落地设置保留）
    write_singbox_config
    $SB_BIN check -c "$SB_CONF" || { err "配置校验失败"; return 1; }
    systemctl restart sing-box
    write_nginx_tls

    save_state
    ok "域名已切换为 $DOMAIN（客户端链接需重新导入）"
    show_link
}

# =============================================================================
#  配置落地代理（多落地共用一个节点端口，按用户分流到不同住宅出口）
# =============================================================================
# 应用落地列表并重启
landing_apply() {
    write_singbox_config
    $SB_BIN check -c "$SB_CONF" || { err "配置校验失败，未重启"; return 1; }
    systemctl restart sing-box
    sleep 2
    systemctl is-active --quiet sing-box || { journalctl -u sing-box -n 15 --no-pager | sed 's/^/  /'; err "sing-box 启动失败"; return 1; }
    save_state
    return 0
}

# 交互录入/修改一个落地（$1=数组下标），失败返回 1
landing_input() {
    local idx=$1 pw
    ask "代理类型（http / socks5）" "${LP_TYPES[$idx]:-http}"
    case $REPLY in
        socks5|socks) LP_TYPES[$idx]=socks5 ;;
        http)         LP_TYPES[$idx]=http ;;
        *) err "类型只能是 http 或 socks5"; return 1 ;;
    esac
    ask "落地代理地址" "${LP_SERVERS[$idx]:-}"
    [[ -z $REPLY ]] && { err "地址不能为空"; return 1; }
    LP_SERVERS[$idx]=$REPLY
    ask "落地代理端口" "${LP_SPORTS[$idx]:-}"
    [[ $REPLY =~ ^[0-9]+$ ]] || { err "端口不合法"; return 1; }
    LP_SPORTS[$idx]=$REPLY
    ask "用户名（无认证可留空）" "${LP_USERS[$idx]:-}"
    LP_USERS[$idx]=$REPLY
    if [[ -n ${LP_USERS[$idx]} ]]; then
        if [[ -n ${LP_PASSES[$idx]:-} ]]; then
            read -rs -p "$(echo -e "${cyan}?${none} 密码 ${gray}[回车=保持不变]${none}: ")" pw; echo
        else
            read -rs -p "$(echo -e "${cyan}?${none} 密码: ")" pw; echo
        fi
        [[ -n $pw ]] && LP_PASSES[$idx]=$pw
    else
        LP_PASSES[$idx]=""
    fi
    return 0
}

# 弹出数组末尾 $1 个（添加失败时回滚用）
landing_pop() {
    local keep=$(( ${#LP_NAMES[@]} - $1 ))
    LP_NAMES=("${LP_NAMES[@]:0:$keep}"); LP_UUIDS=("${LP_UUIDS[@]:0:$keep}")
    LP_TYPES=("${LP_TYPES[@]:0:$keep}");  LP_SERVERS=("${LP_SERVERS[@]:0:$keep}")
    LP_SPORTS=("${LP_SPORTS[@]:0:$keep}"); LP_USERS=("${LP_USERS[@]:0:$keep}")
    LP_PASSES=("${LP_PASSES[@]:0:$keep}")
}

# 删除下标 $1 的落地
landing_del() {
    local del=$1
    LP_NAMES=("${LP_NAMES[@]:0:$del}" "${LP_NAMES[@]:$((del+1))}")
    LP_UUIDS=("${LP_UUIDS[@]:0:$del}" "${LP_UUIDS[@]:$((del+1))}")
    LP_TYPES=("${LP_TYPES[@]:0:$del}" "${LP_TYPES[@]:$((del+1))}")
    LP_SERVERS=("${LP_SERVERS[@]:0:$del}" "${LP_SERVERS[@]:$((del+1))}")
    LP_SPORTS=("${LP_SPORTS[@]:0:$del}" "${LP_SPORTS[@]:$((del+1))}")
    LP_USERS=("${LP_USERS[@]:0:$del}" "${LP_USERS[@]:$((del+1))}")
    LP_PASSES=("${LP_PASSES[@]:0:$del}" "${LP_PASSES[@]:$((del+1))}")
}

# 测试下标 $1 的出口
landing_test_exit() {
    local idx=$1 proto=http purl ip
    [[ ${LP_TYPES[$idx]} == socks5 ]] && proto=socks5h
    if [[ -n ${LP_USERS[$idx]} ]]; then
        purl="${proto}://${LP_USERS[$idx]}:${LP_PASSES[$idx]}@${LP_SERVERS[$idx]}:${LP_SPORTS[$idx]}"
    else
        purl="${proto}://${LP_SERVERS[$idx]}:${LP_SPORTS[$idx]}"
    fi
    msg "测试 ${LP_NAMES[$idx]} 出口..."
    ip=$(curl -sS --proxy "$purl" --max-time 15 https://ipv4.webshare.io/ 2>&1 | head -1)
    if [[ $ip =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
        ok "${LP_NAMES[$idx]} 出口 IP: ${ip}"
    else
        warn "未通过：${ip:-无响应}（常见原因：服务商未把本机 IP 加入白名单 / 账密错误）"
    fi
}

# 选一个落地编号 -> 返回下标到全局 LP_PICK
landing_pick() {
    local i n=${#LP_NAMES[@]} a
    for i in "${!LP_NAMES[@]}"; do
        echo "  $((i+1))) ${LP_NAMES[$i]}   ${LP_TYPES[$i]}://${LP_SERVERS[$i]}:${LP_SPORTS[$i]}"
    done
    ask "请选择编号 [1-${n}]" "1"
    [[ $REPLY =~ ^[0-9]+$ ]] && (( REPLY >= 1 && REPLY <= n )) || { err "无效编号"; return 1; }
    LP_PICK=$((REPLY-1))
    return 0
}

configure_landing() {
    load_state || { err "尚未安装主节点，请先完成安装"; return 1; }
    load_landing_list

    local letters=(a b c d e f g h i j k l m n o p q r s t u v w x y z)
    while :; do
        line
        if [[ ${#LP_NAMES[@]} -gt 0 ]]; then
            msg "落地列表（共 ${#LP_NAMES[@]} 个，共用节点端口 ${LP_IN_PORT}，按用户分流）"
            local i
            for i in "${!LP_NAMES[@]}"; do
                echo "  $((i+1))) ${LP_NAMES[$i]}   ${LP_TYPES[$i]}://${LP_SERVERS[$i]}:${LP_SPORTS[$i]}"
            done
        else
            msg "尚未配置落地代理"
        fi
        line
        echo "  1) 添加落地   2) 修改   3) 删除   4) 测试出口   0) 返回"
        ask "请选择" "0"
        case $REPLY in
            0) return 0 ;;

            1)  # 添加
                [[ ${#LP_NAMES[@]} -ge 26 ]] && { err "最多支持 26 个落地"; continue; }
                local idx=${#LP_NAMES[@]} first_add=0
                [[ $idx == 0 ]] && first_add=1
                LP_NAMES[$idx]="landing-${letters[$idx]}"
                LP_UUIDS[$idx]=$($SB_BIN generate uuid)
                LP_TYPES[$idx]=http; LP_SERVERS[$idx]=""; LP_SPORTS[$idx]=""; LP_USERS[$idx]=""; LP_PASSES[$idx]=""
                if ! landing_input $idx; then landing_pop 1; continue; fi

                if [[ $first_add == 1 ]]; then
                    local def_port
                    def_port=$(shuf -i 10000-65535 -n 1)
                    while [[ $def_port == $REALITY_PORT || $def_port == $SITE_PORT || $def_port == 80 || $def_port == 22 ]] || port_busy $def_port; do
                        def_port=$(shuf -i 10000-65535 -n 1)
                    done
                    ask "落地节点监听端口" "$def_port"
                    [[ $REPLY =~ ^[0-9]+$ ]] || { err "端口不合法"; landing_pop 1; continue; }
                    if [[ $REPLY != "$REALITY_PORT" ]] && port_busy $REPLY; then
                        err "端口 $REPLY 已被占用"; landing_pop 1; continue
                    fi
                    LP_IN_PORT=$REPLY
                fi

                echo
                echo "  落地    : ${PUB_IP}:${LP_IN_PORT}  用户 ${LP_NAMES[$idx]}（链接独立，无 flow）"
                echo "  出口    : 经 ${LP_TYPES[$idx]}://${LP_SERVERS[$idx]}:${LP_SPORTS[$idx]}"
                echo "  主节点  : ${PUB_IP}:${REALITY_PORT} 保持直连，不受影响"
                confirm "确认添加？" || { landing_pop 1; msg "已取消"; continue; }

                LP_ENABLED=1
                if landing_apply; then
                    ok "落地 ${LP_NAMES[$idx]} 已生效：${PUB_IP}:${LP_IN_PORT}"
                    landing_test_exit $idx
                    show_link
                else
                    landing_pop 1
                    err "应用失败，已回滚本次添加"
                    write_singbox_config; systemctl restart sing-box 2>/dev/null
                fi
                ;;

            2)  # 修改
                [[ ${#LP_NAMES[@]} -eq 0 ]] && { warn "还没有落地，先添加"; continue; }
                landing_pick || continue
                local p=$LP_PICK
                if landing_input $p; then
                    confirm "确认修改 ${LP_NAMES[$p]}？" || { msg "已取消"; continue; }
                    if landing_apply; then
                        ok "${LP_NAMES[$p]} 已更新（链接不变，仅出口变化）"
                        landing_test_exit $p
                        show_link
                    fi
                fi
                ;;

            3)  # 删除
                [[ ${#LP_NAMES[@]} -eq 0 ]] && { warn "还没有落地"; continue; }
                landing_pick || continue
                local d=$LP_PICK
                confirm "确认删除 ${LP_NAMES[$d]}？（其它落地与主节点不受影响）" || { msg "已取消"; continue; }
                local dn="${LP_NAMES[$d]}"
                landing_del $d
                if [[ ${#LP_NAMES[@]} -eq 0 ]]; then
                    LP_ENABLED=0; LP_IN_PORT=""
                fi
                if landing_apply; then
                    ok "已删除 ${dn}"
                    [[ ${#LP_NAMES[@]} -eq 0 ]] && ok "落地已全部清空，主节点保持不变"
                fi
                ;;

            4)  # 测试出口
                [[ ${#LP_NAMES[@]} -eq 0 ]] && { warn "还没有落地"; continue; }
                landing_pick || continue
                landing_test_exit $LP_PICK
                ;;
        esac
    done
}

# =============================================================================
#  更改端口（端口被阻断时的应急手段：主节点 / 落地节点独立换端口）
# =============================================================================
change_port() {
    load_state || { err "尚未安装"; return 1; }

    line; msg "更改端口（应急换端口，不影响另一个节点）"; line
    echo "  当前：主节点 ${REALITY_PORT}   落地 $([[ ${LP_ENABLED:-0} == 1 ]] && echo "${LP_IN_PORT}" || echo '未配置')"
    echo
    echo "  1) 更改主节点端口"
    echo "  2) 更改落地节点端口"
    echo "  0) 返回"
    ask "请选择" "0"

    local which=$REPLY old_port new_port label
    case $which in
        0) return 0 ;;
        1) old_port=$REALITY_PORT; label="主节点" ;;
        2)
            [[ ${LP_ENABLED:-0} == 1 ]] || { err "落地未配置，请先用菜单 5 配置落地代理"; return 1; }
            old_port=$LP_IN_PORT; label="落地节点" ;;
        *) err "无效选择"; return 1 ;;
    esac

    ask "${label}新端口（当前 ${old_port}）" "$old_port"
    new_port=$((10#$REPLY))
    [[ $REPLY =~ ^[0-9]+$ ]] || { err "端口不合法"; return 1; }
    (( new_port >= 1 && new_port <= 65535 )) || { err "端口范围 1-65535"; return 1; }
    [[ $new_port == "$old_port" ]] && { msg "端口未变化"; return 0; }

    # 冲突检查：另一个节点端口、本脚本保留端口、其它程序占用
    if [[ $which == 1 ]]; then
        [[ ${LP_ENABLED:-0} == 1 && $new_port == "$LP_IN_PORT" ]] && { err "与落地端口 ${LP_IN_PORT} 冲突"; return 1; }
    else
        [[ $new_port == "$REALITY_PORT" ]] && { err "与主节点端口 ${REALITY_PORT} 冲突"; return 1; }
    fi
    { [[ $new_port == $SITE_PORT || $new_port == 80 || $new_port == 22 ]]; } && \
        { err "端口 ${new_port} 为本脚本保留（网站回落/证书续签/SSH）"; return 1; }
    port_busy $new_port && { err "端口 ${new_port} 已被其它程序占用"; return 1; }

    # 主节点离开 443 的固有代价，先讲清楚
    if [[ $which == 1 && $old_port == 443 ]]; then
        warn "443 是标准 HTTPS 端口，离开后伪装度下降（Xray 官方同样警告非 443 更易被墙）"
        warn "且 https://${DOMAIN} 的正常访客将打不开网站——建议仅在 443 被阻断时这样应急"
        confirm "仍要更改？" || { msg "已取消"; return 0; }
    fi

    # 先把现有落地列表载入内存（LP_LIST_LOADED=1），
    # 防止 write_singbox_config 内部重读旧配置时把新端口覆盖回旧值
    load_landing_list

    if [[ $which == 1 ]]; then
        REALITY_PORT=$new_port
    else
        LP_IN_PORT=$new_port
    fi

    write_singbox_config
    $SB_BIN check -c "$SB_CONF" || { err "配置校验失败"; return 1; }
    systemctl restart sing-box
    sleep 2
    systemctl is-active --quiet sing-box || { journalctl -u sing-box -n 15 --no-pager | sed 's/^/  /'; err "sing-box 启动失败"; return 1; }
    save_state
    port_busy $new_port && ok "${label}端口已生效：${old_port} → ${new_port}" || warn "端口 ${new_port} 未监听，请查看日志"
    if [[ $which == 1 ]]; then
        ok "主节点链接已更新（重新导入）；落地节点不受影响"
    else
        ok "落地节点链接已更新（重新导入）；主节点不受影响"
    fi
    show_link
}

# =============================================================================
#  更新 sing-box 核心（配置不动、链接不变；失败自动回滚）
# =============================================================================
update_core() {
    [[ -x $SB_BIN ]] || { err "尚未安装，请先运行安装"; return 1; }
    line; msg "更新 sing-box 核心"; line

    local cur ver new arch url tmp
    cur=$($SB_BIN version 2>/dev/null | head -1 | awk '{print $3}')
    [[ -z $cur ]] && { err "无法获取当前版本"; return 1; }
    echo "  当前版本: ${cur}"

    ask "目标版本（回车=最新）" "latest"
    if [[ $REPLY == "latest" ]]; then
        ver=$(curl -fsSLI -o /dev/null -w '%{url_effective}' --max-time 20 \
              https://github.com/SagerNet/sing-box/releases/latest 2>/dev/null | sed 's#.*/tag/##')
    else
        ver="v${REPLY//v/}"
    fi
    [[ ! $ver =~ ^v[0-9] ]] && { err "无法获取版本号（网络或 GitHub 不可达）"; return 1; }
    new="${ver#v}"

    if [[ $cur == "$new" ]]; then
        ok "已是最新版本 ${cur}，无需更新"
        return 0
    fi

    echo "  将更新: ${cur} → ${new}"
    confirm "确认更新？（配置不动、链接不变，失败自动回滚）" || { msg "已取消"; return 0; }

    arch=$(uname -m); case $arch in
        x86_64|amd64) arch=amd64 ;;
        aarch64|arm64) arch=arm64 ;;
        *) err "不支持的架构: $arch"; return 1 ;;
    esac
    url="https://github.com/SagerNet/sing-box/releases/download/${ver}/sing-box-${new}-linux-${arch}.tar.gz"
    tmp=$(mktemp -d)
    msg "下载 ${ver} ..."
    if ! curl -fL --retry 3 --max-time 180 "$url" -o "$tmp/sb.tar.gz"; then
        rm -rf "$tmp"; err "下载失败: $url"; return 1
    fi
    tar -xzf "$tmp/sb.tar.gz" -C "$tmp" --strip-components=1 || { rm -rf "$tmp"; err "解压失败"; return 1; }
    [[ -x $tmp/sing-box ]] || { rm -rf "$tmp"; err "包内无 sing-box 二进制"; return 1; }

    # 关键：先用新版二进制校验现有配置，不通过就不动任何东西
    msg "用新版校验现有配置..."
    if ! "$tmp/sing-box" check -c "$SB_CONF"; then
        rm -rf "$tmp"
        err "新版本与现有配置不兼容（配置格式变更）"
        warn "已取消更新，当前核心 ${cur} 保持原样"
        return 1
    fi
    ok "配置校验通过"

    cp -f "$SB_BIN" "$SB_BIN.bak-${cur}"
    systemctl stop sing-box
    mv -f "$tmp/sing-box" "$SB_BIN"
    rm -rf "$tmp"
    chmod +x "$SB_BIN"
    systemctl restart sing-box
    sleep 2

    if systemctl is-active --quiet sing-box && port_busy $REALITY_PORT; then
        ok "已更新到 $($SB_BIN version | head -1 | awk '{print $3}')"
        ok "旧版本已备份: $SB_BIN.bak-${cur}"
        if [[ ${LP_ENABLED:-0} == 1 && -n ${LP_IN_PORT:-} ]] && ! port_busy "$LP_IN_PORT"; then
            warn "落地端口 ${LP_IN_PORT} 未监听，请查看日志"
        fi
        show_link
    else
        err "新核心启动失败，自动回滚到 ${cur} ..."
        systemctl stop sing-box
        mv -f "$SB_BIN.bak-${cur}" "$SB_BIN"
        systemctl restart sing-box
        sleep 2
        if systemctl is-active --quiet sing-box; then
            ok "已回滚到 ${cur}，服务恢复"
        else
            err "回滚后仍异常，请查看日志: journalctl -u sing-box -n 20"
        fi
        return 1
    fi
}

# =============================================================================
#  卸载
# =============================================================================
do_uninstall() {
    line; msg "卸载"; line
    warn "将停止并删除 sing-box、nginx 站点配置、网站文件、systemd 服务"
    confirm "确认卸载？证书与 nginx 软件包保留" || { msg "已取消"; return 0; }

    systemctl stop sing-box 2>/dev/null
    systemctl disable sing-box 2>/dev/null
    rm -f "$SB_SVC"; systemctl daemon-reload

    # 两种 nginx 路径都清理，兼容历史安装位置
    rm -f "$NGINX_LINK" "$NGINX_AVAIL" \
          /etc/nginx/conf.d/selfsteal.conf \
          /etc/nginx/sites-available/selfsteal \
          /etc/nginx/sites-enabled/selfsteal
    nginx -t >/dev/null 2>&1 && systemctl reload nginx

    rm -rf "$SITE_ROOT" "$SB_CONF_DIR" "$SB_DIR" /usr/local/bin/sing-box
    rm -rf /opt/selfsteal /usr/local/bin/se /usr/local/bin/SE
    ok "已卸载（nginx/certbot 软件包与 /etc/letsencrypt 保留）"
}

# =============================================================================
#  菜单
# =============================================================================
main_menu() {
    while :; do
        clear
        echo
        echo -e "${blue}  selfsteal · 偷自己 Reality 管理${none}"
        if load_state 2>/dev/null; then
            echo -e "  ${gray}当前：${DOMAIN}  ${PUB_IP}:${REALITY_PORT}  $(systemctl is-active sing-box 2>/dev/null)${none}"
        else
            echo -e "  ${gray}当前：未安装${none}"
        fi
        line
        echo "  1) 安装 / 重新配置"
        echo "  2) 查看运行状态"
        echo "  3) 查看客户端链接（主节点 + 落地）"
        echo "  4) 更换域名（重签证书）"
        echo "  5) 配置落地代理（静态住宅）"
        echo "  6) 更改端口（应急）"
        echo "  7) 查看日志"
        echo "  8) 更新 sing-box 核心"
        echo "  9) 卸载"
        echo "  10) 拉取伪装站媒体库（GitHub）"
        echo "  11) 站点访问统计"
        echo "  0) 退出"
        line
        ask "请选择 [0-9]" "0"
        case $REPLY in
            1) do_install; echo; read -r -p "按回车返回菜单..." _ ;;
            2) show_status; echo; read -r -p "按回车返回菜单..." _ ;;
            3) show_link; echo; read -r -p "按回车返回菜单..." _ ;;
            4) change_domain; echo; read -r -p "按回车返回菜单..." _ ;;
            5) configure_landing; echo; read -r -p "按回车返回菜单..." _ ;;
            6) change_port; echo; read -r -p "按回车返回菜单..." _ ;;
            7) journalctl -u sing-box -n 60 --no-pager; echo; read -r -p "按回车返回菜单..." _ ;;
            8) update_core; echo; read -r -p "按回车返回菜单..." _ ;;
            9) do_uninstall; echo; read -r -p "按回车返回菜单..." _ ;;
            10) step_fetch_media; echo; read -r -p "按回车返回菜单..." _ ;;
            11) bash /opt/selfsteal/selfsteal-stats.sh 30; echo; read -r -p "按回车返回菜单..." _ ;;
            0) exit 0 ;;
        esac
    done
}

# =============================================================================
#  入口
# =============================================================================
# --help 不需要 root，先处理
if [[ "${1:-}" == "-h" || "${1:-}" == "--help" ]]; then
    sed -n '2,/^$/p' "$0" | sed 's/^# \{0,1\}//'
    exit 0
fi

need_root
detect_pkg
init_nginx_paths
load_state 2>/dev/null || true
ensure_cli

ACTION=""
while [[ $# -gt 0 ]]; do
    case $1 in
        --install)   ACTION=install ;;
        --status)    show_status; exit $? ;;
        --link)      show_link; exit $? ;;
        --uninstall) do_uninstall; exit $? ;;
        --media)     step_fetch_media "${2:-}"; exit $? ;;
        --media-gen) step_gen_media_local; exit $? ;;
        --write-site) step_write_site; exit $? ;;
        --domain)    DOMAIN=$2; ACTION=install; shift 2 ;;
        --email)     EMAIL=$2; shift 2 ;;
        *) err "未知参数: $1（用 --help 查看用法）"; exit 1 ;;
    esac
done

# 无参数：新机器直接进安装向导（像 233boy 一样）；已安装则进管理菜单
if [[ $ACTION == install ]]; then
    do_install
elif is_installed; then
    main_menu
else
    do_install
fi
