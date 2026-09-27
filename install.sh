#!/bin/bash
# ==============================================================================
# Emby 动态反代管理脚本  v3.9.1
# ==============================================================================
# 【这个脚本是干什么的】
#   把一台服务器做成 Emby 的"中转站"。
#   用户访问  https://你的域名/https://真实Emby地址/路径
#   脚本自动把后半段（真实 Emby 地址）解析出来，把请求转发过去，
#   再把 Emby 的响应原样返回。这样就实现了一个动态反向代理。
#
# 【主要功能模块】
#   1. 动态反向代理         —— 通过 URL 路径解析目标地址
#   2. 域名 / IP 双模式     —— 有域名走 HTTPS，没域名走 IP + HTTP
#   3. 中国 IP 限制         —— 非中国大陆 IP 直接拒绝（IPv6 放行）
#   4. 域名白名单           —— 只允许反代指定的几个目标域名
#   5. 客户端白名单         —— 只允许特定的 Emby 客户端 UA 访问
#   6. 首页伪装 + 错误页伪装 —— 让反代看起来像一个普通博客
#   7. 证书自动申请          —— 用 acme.sh 申请 Let's Encrypt 证书
#   8. 脚本内升级            —— 保留配置，一键补新功能
#   9. Range 请求透传        —— 让拖动进度条变快、省流量
#  10. 详细错误提示 + 调试模式
#
# 【系统要求】
#   Debian 10+ / Ubuntu 20.04+，必须以 root 运行
#
# 【配置文件位置】
#   /etc/emby-rp.conf                    主配置（模式、开关、白名单等）
#   /usr/local/openresty/nginx/conf/      OpenResty / Nginx 相关文件
# ==============================================================================


# 版本号 —— 用于升级检测
VER="v3.9.1"


# ==============================================================================
# 一、路径定义
# ==============================================================================
# 把常用路径集中定义，方便统一修改，也便于阅读
# ==============================================================================

CONF="/etc/emby-rp.conf"                                       # 主配置文件（键=值形式，可 source）
NGINX="/usr/local/openresty/nginx/conf/nginx.conf"              # Nginx 主配置
LUA="/usr/local/openresty/nginx/conf/lua_init.lua"              # Lua 初始化脚本（启动时执行一次）
ALLOW_FILE="/usr/local/openresty/nginx/conf/allow_domains.txt"  # 域名白名单（每行一个）
CLIENT_FILE="/usr/local/openresty/nginx/conf/allow_clients.txt" # 客户端白名单（每行一个 UA 关键字）
CAMO_FILE="/usr/local/openresty/nginx/conf/camo_index.html"     # 首页伪装模板
CAMO_ERROR_FILE="/usr/local/openresty/nginx/conf/camo_error.html" # 错误页伪装模板
SERVICE="/etc/systemd/system/emby-proxy.service"                # 自定义 systemd 服务
LOGROTATE="/etc/logrotate.d/emby-proxy"                         # 日志轮转配置
SSL_DIR="/usr/local/openresty/nginx/conf/ssl"                   # 证书存放目录
ACME_HOME="/root/.acme.sh"                                      # acme.sh 安装目录
ACME_WEBROOT="/var/www/acme"                                    # ACME HTTP-01 验证目录
CHINA_IP_CONF="/usr/local/openresty/nginx/conf/china_ip.conf"   # 中国 IPv4 段（geo 格式）
CHINA_IP_URL="https://raw.githubusercontent.com/17mon/china_ip_list/master/china_ip_list.txt"  # IP 库源


# ==============================================================================
# 二、默认客户端白名单
# ==============================================================================
# 这些关键字用于匹配请求头里的 User-Agent。
# 只要 UA 里出现其中任意一段（忽略大小写），就认为客户端合法。
# 覆盖 Android / iOS / macOS / tvOS / HarmonyOS / Windows 常见 Emby 客户端。
# 用户可在菜单 [3] 中自行增删或重置。
# ==============================================================================

DEFAULT_CLIENTS="Emby|Infuse|Forward|REX|Conflux|Reflix|Fileball|DS One|DS Cloud|IIVA|iemc|yybx|yyb|EMTV|AGC|VidHub|HamHub|CapyPlayer|iPlayX|EplayerX|Temby|Swiftfin|Streamyfin|Moon|BoxPlayer|Vidora|Optic|Themby|LinPlayer|Elegant|DreamBy|OopsPlayer|映盒|Afusekt|Prism|iNAS|Lumenic|RovePlayer|Yamby|Hills|Cinemore|Kodi|Findroid|Symfonium|AfuseKt|Femor|Terminus|Jellyfin|JeffernTV|ChaiChaiEmbyTV|TVXemby|Flow|Cmby|CovePlayer|Hosplayer|Harflix|Flymby|Tsukimi|Zerk|FloePlayer|WWPlayer|qEmby|Lenna|SenPlayer|nPlayer|iPlay|小幻|卡皮巴拉|学习小秘版"


# ==============================================================================
# 三、颜色输出工具
# ==============================================================================
# 用 ANSI 转义码在终端上输出彩色文字。
# green  = 成功
# red    = 失败 / 错误
# yellow = 警告
# blue   = 提示 / 信息
# ==============================================================================

green(){  echo -e "\033[32m$1\033[0m"; }
red(){    echo -e "\033[31m$1\033[0m"; }
yellow(){ echo -e "\033[33m$1\033[0m"; }
blue(){   echo -e "\033[36m$1\033[0m"; }

# 暂停，等待用户按回车返回
pause(){ echo; read -p "按回车返回..." ; }


# ==============================================================================
# 四、界面标题渲染
# ==============================================================================

# 主菜单顶部的大标题（清屏 + 边框）
header(){
    clear
    echo -e "\033[36m╔══════════════════════════════════════════╗\033[0m"
    echo -e "\033[36m║\033[0m        \033[1m动态反代管理面板  $VER\033[0m         \033[36m║\033[0m"
    echo -e "\033[36m╚══════════════════════════════════════════╝\033[0m"
    echo
}

# 二级菜单的分隔线 + 标题
subheader(){
    echo -e "\033[36m──────────────────────────────────────────\033[0m"
    echo -e "  \033[1m$1\033[0m"
    echo -e "\033[36m──────────────────────────────────────────\033[0m"
}

# 状态显示快捷方式
status_on(){  green "已开启"; }
status_off(){ yellow "已关闭"; }


# ==============================================================================
# 五、服务控制
# ==============================================================================
# 本脚本使用 emby-proxy.service 承载 OpenResty，
# 并禁用系统自带的 openresty.service，避免两个服务抢 80/443 端口。
# ==============================================================================

# 重启服务：先停掉系统自带的 openresty，再重启 emby-proxy
svc_restart(){
    systemctl stop openresty 2>/dev/null
    systemctl disable openresty 2>/dev/null
    systemctl daemon-reload
    systemctl restart emby-proxy 2>/dev/null || {
        # 如果 systemd 重启失败，退化为直接杀进程 + 手动启动
        pkill -f 'nginx: master' 2>/dev/null
        sleep 1
        /usr/local/openresty/bin/openresty
    }
}

# 平滑重载：不中断现有连接
svc_reload(){ systemctl reload emby-proxy 2>/dev/null || openresty -s reload 2>/dev/null || true; }

# 停止服务：全部停掉并杀进程
svc_stop(){
    systemctl stop emby-proxy 2>/dev/null
    systemctl stop openresty 2>/dev/null
    pkill -f 'nginx: master' 2>/dev/null
    true
}


# ==============================================================================
# 六、配置读写
# ==============================================================================
# 所有可调参数保存在 /etc/emby-rp.conf 中。
# init() 会在启动时读取它（source），并在字段缺失时补默认值。
# save() 把当前变量写回磁盘。
# ==============================================================================

init(){
    # 首次运行：创建默认配置文件
    if [ ! -f "$CONF" ]; then
        cat > "$CONF" <<EOF
MODE="domain"                                   # 部署模式：domain=域名模式 / ip=IP模式
DOMAIN=""                                       # 绑定域名（域名模式下使用）
FILTER="0"                                      # 域名白名单开关：1=开 / 0=关
ALLOW_DOMAIN=""                                 # 域名白名单（用 | 分隔）
CLIENT_FILTER="0"                               # 客户端白名单开关：1=开 / 0=关
CLIENT_ALLOW="$DEFAULT_CLIENTS"                 # 客户端白名单（用 | 分隔）
HTTPS="0"                                       # 是否启用 HTTPS：1=是 / 0=否
CHINA_ONLY="1"                                  # 仅允许中国大陆 IP：1=是 / 0=否
CAMO="0"                                        # 首页伪装开关：1=开 / 0=关
DEBUG="0"                                       # 调试模式：1=开 / 0=关
INSTALLED_VER="$VER"                            # 记录已安装的版本号（用于升级检测）
EOF
    fi

    # 读取配置文件
    source "$CONF"

    # 兼容老版本：如果某些字段没定义，补上默认值
    : "${MODE:=domain}"
    : "${DOMAIN:=}"
    : "${HTTPS:=0}"
    : "${CHINA_ONLY:=1}"
    : "${FILTER:=0}"
    : "${ALLOW_DOMAIN:=}"
    : "${CAMO:=0}"
    : "${CLIENT_FILTER:=0}"
    : "${DEBUG:=0}"
    # 特别处理：只有变量完全未定义时才注入默认客户端，尊重用户清空的选择
    if [ -z "${CLIENT_ALLOW+x}" ]; then
        CLIENT_ALLOW="$DEFAULT_CLIENTS"
    fi
    # 老版本没有 INSTALLED_VER，标记成 v3.5
    : "${INSTALLED_VER:=v3.5}"
}

# 把当前所有变量写回配置文件
save(){
    cat > "$CONF" <<EOF
MODE="$MODE"
DOMAIN="$DOMAIN"
FILTER="$FILTER"
ALLOW_DOMAIN="$ALLOW_DOMAIN"
CLIENT_FILTER="$CLIENT_FILTER"
CLIENT_ALLOW="$CLIENT_ALLOW"
HTTPS="$HTTPS"
CHINA_ONLY="$CHINA_ONLY"
CAMO="$CAMO"
DEBUG="$DEBUG"
INSTALLED_VER="$INSTALLED_VER"
EOF
}


# ==============================================================================
# 七、中国 IP 库管理
# ==============================================================================
# 从 GitHub 拉取 china_ip_list，转换为 Nginx geo 模块可用格式：
#   每行形如  1.2.3.0/24 1;
# geo 里用 include 引用，1 表示"中国"。
# ==============================================================================

update_china_ip(){
    blue "ℹ️ 更新中国IP库..."
    mkdir -p "$(dirname "$CHINA_IP_CONF")"
    local tmp="/tmp/china_ip_list.txt"

    # 下载原始列表
    if ! curl -fsSL --connect-timeout 15 --max-time 60 "$CHINA_IP_URL" -o "$tmp"; then
        red "❌ 下载失败"
        return 1
    fi

    # 转换格式：忽略空行和注释，输出 "CIDR 1;"
    awk '!/^[[:space:]]*#/ && NF>=1 {print $1 " 1;"}' "$tmp" > "$CHINA_IP_CONF"
    rm -f "$tmp"

    # 校验结果非空
    if [ ! -s "$CHINA_IP_CONF" ]; then
        red "❌ IP库为空，请检查源"
        return 1
    fi
    green "✅ 更新完成（$(wc -l < "$CHINA_IP_CONF") 条，仅 IPv4）"
}


# ==============================================================================
# 八、依赖与 OpenResty 安装
# ==============================================================================

# 安装系统基础依赖
install_pkg(){
    blue "ℹ️ 安装基础依赖..."
    apt update >/dev/null 2>&1
    apt install -y curl wget socat gnupg2 ca-certificates \
        software-properties-common lsb-release apt-transport-https cron logrotate >/dev/null 2>&1
    green "✅ 依赖安装完成"
}

# 安装 OpenResty
# 逻辑：
#   1. 按系统代号从新到旧依次尝试（比如 trixie → bookworm → bullseye）
#   2. 优先用官方 GPG 签名，失败时回退 trusted=yes
#   3. 找到可用的源代号后再安装
install_openresty(){
    # 已经装过就跳过
    if command -v openresty >/dev/null 2>&1; then
        green "✅ OpenResty 已安装"
        return 0
    fi
    blue "ℹ️ 开始安装 OpenResty..."

    # 获取系统代号
    local CODENAME
    CODENAME=$(lsb_release -sc)

    # 候选源代号列表：当前系统的代号优先，然后是相邻的老版本
    local CANDIDATES
    case "$CODENAME" in
        trixie)   CANDIDATES="trixie bookworm bullseye" ;;
        bookworm) CANDIDATES="bookworm bullseye" ;;
        bullseye) CANDIDATES="bullseye" ;;
        noble)    CANDIDATES="noble jammy" ;;
        jammy)    CANDIDATES="jammy focal" ;;
        focal)    CANDIDATES="focal" ;;
        *)        CANDIDATES="$CODENAME bookworm jammy" ;;
    esac

    local chosen=""
    local code
    for code in $CANDIDATES; do
        blue "ℹ️ 尝试源代号: $code"
        rm -f /etc/apt/sources.list.d/openresty.list
        rm -f /usr/share/keyrings/openresty.gpg

        local use_official=0

        # 先试官方签名源
        if wget -qO- https://openresty.org/package/pubkey.gpg | gpg --dearmor -o /usr/share/keyrings/openresty.gpg 2>/dev/null; then
            echo "deb [signed-by=/usr/share/keyrings/openresty.gpg] http://openresty.org/package/debian $code openresty" \
                > /etc/apt/sources.list.d/openresty.list
            if apt update >/dev/null 2>&1 && apt-cache policy openresty 2>/dev/null | grep -q "Candidate:"; then
                use_official=1
            fi
        fi

        # 官方源失败，回退到 trusted=yes（不校验签名）
        if [ "$use_official" = "0" ]; then
            rm -f /usr/share/keyrings/openresty.gpg
            echo "deb [trusted=yes] http://openresty.org/package/debian $code openresty" \
                > /etc/apt/sources.list.d/openresty.list
            apt update >/dev/null 2>&1
        fi

        # 检查是否真的能找到 openresty 包
        if apt-cache policy openresty 2>/dev/null | grep -q "Candidate:"; then
            chosen="$code"
            green "✅ 使用源代号: $code"
            break
        else
            yellow "⚠️ $code 源无 openresty 包，尝试下一个"
        fi
    done

    # 一个可用源都没有
    if [ -z "$chosen" ]; then
        red "❌ 所有候选源均不可用，请检查网络或手动配置源"
        return 1
    fi

    # 安装
    blue "ℹ️ 下载并安装 openresty..."
    if ! apt install -y openresty; then
        red "❌ apt install 失败，请检查上方报错"
        return 1
    fi

    # 校验命令是否真的可用
    if ! command -v openresty >/dev/null 2>&1; then
        red "❌ 安装后仍找不到 openresty 命令"
        return 1
    fi
    systemctl enable openresty >/dev/null 2>&1
    green "✅ OpenResty 安装完成"
}

# 安装 acme.sh（Let's Encrypt 证书申请工具）
install_acme(){
    if [ -f "$ACME_HOME/acme.sh" ]; then
        green "✅ acme.sh 已安装"
        return 0
    fi
    if [ -z "$DOMAIN" ]; then
        red "❌ 请先设置域名再安装 acme.sh"
        return 1
    fi
    blue "ℹ️ 安装 acme.sh..."
    curl -s https://get.acme.sh | sh -s email=admin@"$DOMAIN" >/dev/null 2>&1
    export PATH="$ACME_HOME:$PATH"
    [ -f /root/.bashrc ] && source /root/.bashrc 2>/dev/null
    if [ ! -f "$ACME_HOME/acme.sh" ]; then
        red "❌ 安装失败"
        return 1
    fi
    # 默认使用 Let's Encrypt
    "$ACME_HOME/acme.sh" --set-default-ca --server letsencrypt >/dev/null 2>&1
    green "✅ acme.sh 安装完成"
}


# ==============================================================================
# 九、证书申请
# ==============================================================================
# 优先用 webroot 模式（不中断服务），失败再退到 standalone。
# 申请成功后，把证书安装到 SSL_DIR，并注册自动重载命令。
# ==============================================================================

issue_cert(){
    local domain="$1"
    mkdir -p "$SSL_DIR" "$ACME_WEBROOT"
    blue "ℹ️ 申请证书 $domain ..."
    export PATH="$ACME_HOME:$PATH"

    # 备份现有 nginx.conf
    local bak=""
    if [ -f "$NGINX" ]; then
        bak="${NGINX}.bak.$$"
        cp -a "$NGINX" "$bak"
    fi

    # 写一个只用于 ACME 验证的临时 Nginx 配置
    write_acme_temp_nginx "$domain"
    svc_restart
    sleep 1

    # 方法一：webroot 验证
    "$ACME_HOME/acme.sh" --issue -d "$domain" -w "$ACME_WEBROOT" --keylength 2048 --force >/dev/null 2>&1
    local ok=$?

    # 方法二：standalone 验证（需要临时释放 80 端口）
    if [ $ok -ne 0 ]; then
        yellow "⚠️ webroot 失败，尝试 standalone"
        svc_stop
        fuser -k 80/tcp 2>/dev/null || true
        "$ACME_HOME/acme.sh" --issue -d "$domain" --standalone --keylength 2048 --force >/dev/null 2>&1
        ok=$?
    fi

    # 恢复原 nginx.conf
    if [ -n "$bak" ] && [ -f "$bak" ]; then
        mv -f "$bak" "$NGINX"
    fi

    if [ $ok -ne 0 ]; then
        red "❌ 证书申请失败"
        return 1
    fi

    # 把证书安装到指定路径，并注册证书更新后的重载命令
    "$ACME_HOME/acme.sh" --install-cert -d "$domain" \
        --key-file       "$SSL_DIR/${domain}.key" \
        --fullchain-file "$SSL_DIR/${domain}.fullchain.pem" \
        --reloadcmd      "systemctl reload emby-proxy 2>/dev/null || openresty -s reload 2>/dev/null || true" >/dev/null 2>&1
    if [ $? -ne 0 ]; then
        red "❌ 证书安装失败"
        return 1
    fi

    # 权限：私钥 600，证书链 644
    chmod 600 "$SSL_DIR/${domain}.key"
    chmod 644 "$SSL_DIR/${domain}.fullchain.pem"
    green "✅ 证书申请并安装成功"
}

# 写一个临时的 nginx.conf，仅用于 ACME HTTP-01 验证
write_acme_temp_nginx(){
    local domain="$1"
    mkdir -p "$ACME_WEBROOT"
    cat > "$NGINX" <<EOF
worker_processes auto;
events { worker_connections 1024; }
http {
    server {
        listen 80;
        listen [::]:80;
        server_name $domain;
        # ACME 验证路径
        location /.well-known/acme-challenge/ {
            root $ACME_WEBROOT;
            default_type text/plain;
        }
        # 其他请求随便返回一个占位
        location / {
            return 200 'acme-ready';
            add_header Content-Type text/plain;
        }
    }
}
EOF
    openresty -t >/dev/null 2>&1 || true
}


# ==============================================================================
# 十、Lua 初始化 + 伪装页面
# ==============================================================================
# 这个函数做三件事：
#   1. 把域名 / 客户端白名单从 bash 字符串拆成独立文件
#   2. 生成首页伪装 HTML、错误页伪装 HTML
#   3. 生成 lua_init.lua —— Nginx 启动时会执行它，把开关和内容读进共享字典
# ==============================================================================

write_lua(){
    mkdir -p "$(dirname "$LUA")"

    # ---------- 域名白名单文件（每行一个） ----------
    : > "$ALLOW_FILE"
    if [ -n "$ALLOW_DOMAIN" ]; then
        IFS="|" read -ra ARR <<< "$ALLOW_DOMAIN"
        for d in "${ARR[@]}"; do
            [ -n "$d" ] && echo "$d" >> "$ALLOW_FILE"
        done
    fi

    # ---------- 客户端白名单文件（每行一个关键字） ----------
    : > "$CLIENT_FILE"
    if [ -n "$CLIENT_ALLOW" ]; then
        IFS="|" read -ra CARR <<< "$CLIENT_ALLOW"
        for c in "${CARR[@]}"; do
            [ -n "$c" ] && echo "$c" >> "$CLIENT_FILE"
        done
    fi

    # ---------- 首页伪装 HTML（写死在这里，每次升级都会覆盖） ----------
    cat > "$CAMO_FILE" <<'HTML'
<!DOCTYPE html>
<html lang="zh-CN">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>Stream Notes</title>
<style>
  :root { --fg:#222; --muted:#888; --bg:#fafafa; --accent:#3b6ea5; }
  * { box-sizing: border-box; }
  body { margin:0; background:var(--bg); color:var(--fg);
    font: 16px/1.7 -apple-system, "Segoe UI", "PingFang SC", "Microsoft YaHei", sans-serif; }
  .wrap { max-width: 680px; margin: 0 auto; padding: 64px 24px 96px; }
  header { margin-bottom: 48px; }
  header h1 { font-size: 26px; margin: 0 0 8px; letter-spacing: .5px; }
  header p { color: var(--muted); margin: 0; font-size: 14px; }
  article { padding: 20px 0; border-bottom: 1px solid #eaeaea; }
  article:last-child { border-bottom: none; }
  article h2 { font-size: 18px; margin: 0 0 6px; }
  article h2 a { color: var(--fg); text-decoration: none; }
  article h2 a:hover { color: var(--accent); }
  article .meta { color: var(--muted); font-size: 13px; margin-bottom: 8px; }
  article p { margin: 0; color: #555; }
  footer { margin-top: 64px; color: var(--muted); font-size: 13px; text-align: center; }
</style>
</head>
<body>
<div class="wrap">
  <header>
    <h1>Stream Notes</h1>
    <p>记录一些关于流媒体、网络与自建服务的小事。</p>
  </header>

  <article>
    <h2><a href="#">用 OpenResty 搭建轻量反向代理</a></h2>
    <div class="meta">2026-03-12 · 网络</div>
    <p>通过 Lua 在请求阶段解析路径，把动态目标地址交给 proxy_pass，实现一个极简的通用反代。</p>
  </article>

  <article>
    <h2><a href="#">流媒体播放的缓冲与 Range 请求</a></h2>
    <div class="meta">2026-02-28 · 流媒体</div>
    <p>关闭 proxy_buffering、打开 proxy_force_ranges，可以显著改善拖动进度条时的体验。</p>
  </article>

  <article>
    <h2><a href="#">给自建服务加一层访问控制</a></h2>
    <div class="meta">2026-02-10 · 安全</div>
    <p>用 geo 模块做地区限制、用共享字典做域名白名单，成本低但足够挡住大部分滥用。</p>
  </article>

  <article>
    <h2><a href="#">关于日志轮转的一点经验</a></h2>
    <div class="meta">2026-01-22 · 运维</div>
    <p>logrotate 配合 nginx 的 USR1 信号，可以在不中断服务的前提下切分日志。</p>
  </article>

  <footer>© 2026 Stream Notes · 保持简单</footer>
</div>
</body>
</html>
HTML

    # ---------- 错误页伪装模板 ----------
    # 里面有 4 个占位符，Lua 在运行时替换：
    #   {{CODE}}   —— HTTP 状态码（如 403）
    #   {{TITLE}}  —— 标题（如 "内容暂时不可见"）
    #   {{DETAIL}} —— 说明文字
    #   {{DEBUG}}  —— 调试信息块（仅当调试模式开启时非空）
    cat > "$CAMO_ERROR_FILE" <<'HTML'
<!DOCTYPE html>
<html lang="zh-CN">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>{{CODE}} · Stream Notes</title>
<style>
  :root { --fg:#222; --muted:#888; --bg:#fafafa; --accent:#3b6ea5; --line:#eaeaea; }
  * { box-sizing: border-box; }
  body { margin:0; background:var(--bg); color:var(--fg);
    font: 16px/1.7 -apple-system, "Segoe UI", "PingFang SC", "Microsoft YaHei", sans-serif; }
  .wrap { max-width: 680px; margin: 0 auto; padding: 96px 24px 64px; }
  .card { text-align: center; }
  .code {
    font-size: 96px; font-weight: 700; color: var(--accent);
    line-height: 1; letter-spacing: 3px; margin: 0 0 20px; opacity: .85;
    font-family: "SF Mono", Menlo, Consolas, monospace;
  }
  h1 { font-size: 22px; margin: 0 0 14px; font-weight: 600; }
  p  { color: #555; margin: 0 0 8px; }
  .hint { color: var(--muted); font-size: 14px; margin-top: 28px; }
  a.home { color: var(--accent); text-decoration: none; }
  a.home:hover { text-decoration: underline; }
  .debug {
    margin-top: 48px; padding: 16px 18px; border: 1px dashed #ddd;
    background: #fff; color: #666; font-size: 12px; text-align: left;
    border-radius: 6px; white-space: pre-wrap; word-break: break-all;
    font-family: "SF Mono", Menlo, Consolas, monospace; line-height: 1.6;
  }
  .debug::before {
    content: "调试信息"; display: block; color: #999; margin-bottom: 8px;
    font-size: 11px; letter-spacing: 1px; text-transform: uppercase;
  }
  footer { margin-top: 64px; color: var(--muted); font-size: 13px; text-align: center; }
</style>
</head>
<body>
<div class="wrap">
  <div class="card">
    <div class="code">{{CODE}}</div>
    <h1>{{TITLE}}</h1>
    <p>{{DETAIL}}</p>
    <p class="hint"><a class="home" href="/">← 返回首页</a></p>
  </div>
  {{DEBUG}}
  <footer>© 2026 Stream Notes · 保持简单</footer>
</div>
</body>
</html>
HTML

    # ---------- Lua 初始化脚本 ----------
    # 这个脚本由 init_by_lua_file 在 Nginx 启动时执行一次
    # 作用：把 bash 里的开关和文件内容读进共享字典 allow_domain
    cat > "$LUA" <<EOF
-- 共享字典（在 nginx.conf 中用 lua_shared_dict 定义）
local dict = ngx.shared.allow_domain

-- 各类开关
dict:set("filter",        "$FILTER")          -- 域名白名单开关
dict:set("camo",          "$CAMO")            -- 首页伪装开关
dict:set("china_only",    "$CHINA_ONLY")      -- 中国 IP 限制开关
dict:set("client_filter", "$CLIENT_FILTER")   -- 客户端白名单开关
dict:set("debug",         "$DEBUG")           -- 调试模式开关

-- 加载首页伪装 HTML
local cf = io.open("$CAMO_FILE", "r")
if cf then
    dict:set("camo_html", cf:read("*a"))
    cf:close()
end

-- 加载错误页伪装模板
local cef = io.open("$CAMO_ERROR_FILE", "r")
if cef then
    dict:set("camo_error_html", cef:read("*a"))
    cef:close()
end

-- 加载域名白名单
local f = io.open("$ALLOW_FILE", "r")
if f then
    local lines = {}
    for line in f:lines() do
        line = line:gsub("%s+", "")
        if line ~= "" then lines[#lines+1] = line end
    end
    f:close()
    -- 用 | 拼成一整条，读取时再 split
    dict:set("domains", table.concat(lines, "|"))
end

-- 加载客户端白名单
local cf2 = io.open("$CLIENT_FILE", "r")
if cf2 then
    local clines = {}
    for line in cf2:lines() do
        line = line:gsub("%s+", "")
        if line ~= "" then clines[#clines+1] = line end
    end
    cf2:close()
    dict:set("clients", table.concat(clines, "|"))
end
EOF
}


# ==============================================================================
# 十一、systemd 与 logrotate
# ==============================================================================

# 生成 emby-proxy.service，用它来管理 OpenResty
make_systemd(){
    cat > "$SERVICE" <<EOF
[Unit]
Description=Emby Dynamic Reverse Proxy
After=network.target

[Service]
Type=forking
PIDFile=/usr/local/openresty/nginx/logs/nginx.pid
# 启动前先做一次配置检查
ExecStartPre=/usr/local/openresty/nginx/sbin/nginx -t -q -g 'daemon on; master_process on;'
ExecStart=/usr/local/openresty/nginx/sbin/nginx -g 'daemon on; master_process on;'
ExecReload=/usr/local/openresty/nginx/sbin/nginx -g 'daemon on; master_process on;' -s reload
ExecStop=-/sbin/start-stop-daemon --quiet --stop --retry QUIT/5 --pidfile /usr/local/openresty/nginx/logs/nginx.pid
Restart=always
RestartSec=5

[Install]
WantedBy=multi-user.target
EOF
    systemctl daemon-reload
    # 禁用系统自带 openresty，避免和 emby-proxy 抢端口
    systemctl disable openresty 2>/dev/null
    systemctl stop openresty 2>/dev/null
    systemctl enable emby-proxy.service >/dev/null 2>&1
}

# 日志轮转：每天切一次，保留 7 天，压缩旧日志
# postrotate 里向 nginx 发 USR1 信号，让它重新打开日志文件
make_logrotate(){
    cat > "$LOGROTATE" <<EOF
/usr/local/openresty/nginx/logs/*.log {
    daily
    rotate 7
    missingok
    notifempty
    compress
    delaycompress
    sharedscripts
    postrotate
        [ -f /usr/local/openresty/nginx/logs/nginx.pid ] && kill -USR1 \$(cat /usr/local/openresty/nginx/logs/nginx.pid) 2>/dev/null || true
    endscript
}
EOF
    green "✅ logrotate 已配置（保留 7 天）"
}


# ==============================================================================
# 十二、反代 location 生成
# ==============================================================================
# 这个函数是整个脚本最核心的部分，生成 location / 的完整配置。
# 里面包含：
#   1. 一段 Lua 代码（rewrite_by_lua_block），处理所有拦截逻辑
#   2. proxy_pass 和一系列 proxy_set_header
#   3. 502 / 503 / 504 错误处理
# ==============================================================================

gen_proxy_location(){
    # 注意这里用的是 'LOC' 引号，避免 bash 展开其中的 $xxx 和 {{xxx}}
    cat > /tmp/rp_location.$$ <<'LOC'
    location / {
        # 下面这三个变量在 Lua 里被赋值，然后交给 proxy_pass 使用
        set $upstream "";         # 完整的协议 + 主机名，比如 https://example.com
        set $target_host "";      # 目标主机名（可能带端口）
        set $target_scheme "";    # http 或 https
        set $target_path "";      # 目标路径（暂未直接使用，预留给日志）

        # ============================================================
        # 请求重写阶段：Lua 在这里做所有校验和路径改写
        # ============================================================
        rewrite_by_lua_block {
            local dict = ngx.shared.allow_domain

            -- 简单的转义工具：把换行/制表符替换成空格，防止日志被注入
            local function esc(s)
                if not s then return "" end
                s = tostring(s):gsub("[\r\n\t]", " ")
                return s
            end

            -- 渲染"博客风格"错误页（伪装模式启用时使用）
            -- 用 gsub 替换模板里的 4 个占位符
            local function render_camo_error(status, title, detail, debug_text)
                local tpl = dict:get("camo_error_html")
                if not tpl or tpl == "" then
                    -- 没有模板就退化成纯文本
                    ngx.header.content_type = "text/plain; charset=utf-8"
                    ngx.say("[" .. tostring(status) .. "] " .. (title or ""))
                    return ngx.exit(status)
                end
                local html = tpl
                html = html:gsub("{{CODE}}",   tostring(status))
                html = html:gsub("{{TITLE}}",  title or "")
                html = html:gsub("{{DETAIL}}", detail or "")
                local dbg = ""
                if dict:get("debug") == "1" and debug_text and debug_text ~= "" then
                    dbg = '<div class="debug">' .. debug_text .. '</div>'
                end
                html = html:gsub("{{DEBUG}}", dbg)
                ngx.header.content_type = "text/html; charset=utf-8"
                ngx.print(html)
                return ngx.exit(status)
            end

            -- 统一错误入口：
            --   伪装模式 → 博客风格错误页
            --   普通模式 → 带详细信息的纯文本
            local function render_error(status, title, detail, hints, extra)
                ngx.status = status

                -- 拼装调试信息
                local debug_text = "原始状态码: " .. tostring(status) ..
                                   "\n原始说明:   " .. tostring(title or "") ..
                                   "\n详情:       " .. tostring(detail or "")
                if extra and extra ~= "" then
                    debug_text = debug_text .. "\n" .. extra
                end
                debug_text = debug_text ..
                    "\n\n客户端: " .. esc(ngx.var.remote_addr) ..
                    "\n请求:   " .. esc(ngx.var.request_method) .. " " .. esc(ngx.var.request_uri)
                if ngx.var.http_user_agent then
                    debug_text = debug_text .. "\nUA:     " .. esc(ngx.var.http_user_agent)
                end

                -- 伪装模式：翻译成博客文案
                if dict:get("camo") == "1" then
                    local c_title, c_detail
                    if status == 403 then
                        c_title  = "内容暂时不可见"
                        c_detail = "你访问的内容是私密的，或已不再对公众开放。"
                    elseif status == 400 or status == 414 then
                        c_title  = "这一页走丢了"
                        c_detail = "可能链接已失效，或者地址拼写有误。"
                    else
                        c_title  = "页面无法访问"
                        c_detail = "请稍后再试，或返回首页看看别的。"
                    end
                    return render_camo_error(status, c_title, c_detail, debug_text)
                end

                -- 普通模式：纯文本错误页
                local L = {}
                L[#L+1] = string.rep("═", 44)
                L[#L+1] = string.format("  [%d] %s", status, title or "")
                L[#L+1] = string.rep("═", 44)
                L[#L+1] = ""
                if detail and detail ~= "" then
                    L[#L+1] = detail
                end
                if hints and #hints > 0 then
                    L[#L+1] = ""
                    L[#L+1] = "处理建议："
                    for _, h in ipairs(hints) do
                        L[#L+1] = "  · " .. h
                    end
                end
                if extra and extra ~= "" then
                    L[#L+1] = ""
                    L[#L+1] = "详情："
                    L[#L+1] = extra
                end
                L[#L+1] = ""
                L[#L+1] = string.rep("─", 44)
                L[#L+1] = "时间:   " .. os.date("%Y-%m-%d %H:%M:%S")
                L[#L+1] = "客户端: " .. esc(ngx.var.remote_addr)
                L[#L+1] = "请求:   " .. esc(ngx.var.request_method) .. " " .. esc(ngx.var.request_uri)
                if dict:get("debug") == "1" then
                    L[#L+1] = string.rep("─", 44)
                    L[#L+1] = "调试信息："
                    L[#L+1] = "UA:     " .. esc(ngx.var.http_user_agent or "(空)")
                    L[#L+1] = "Host:   " .. esc(ngx.var.host or "")
                    L[#L+1] = "Referer:" .. esc(ngx.var.http_referer or "(空)")
                    L[#L+1] = "is_cn:  " .. esc(ngx.var.is_cn or "(未启用)")
                    L[#L+1] = "filter: " .. esc(dict:get("filter") or "?")
                    L[#L+1] = "cli_flt:" .. esc(dict:get("client_filter") or "?")
                end
                ngx.header.content_type = "text/plain; charset=utf-8"
                ngx.say(table.concat(L, "\n"))
                return ngx.exit(status)
            end

            -- --------------------------------------------------------
            -- 拦截 1：中国 IP 限制
            -- $is_cn 由 nginx.conf 里的 geo 块赋值：
            --   0 = 境外
            --   1 = 中国 / IPv6 / 未知
            -- --------------------------------------------------------
            if dict:get("china_only") == "1" and ngx.var.is_cn == "0" then
                return render_error(403, "拒绝访问 · 非中国大陆 IP",
                    "当前请求来自境外 IP，访问被限制。",
                    {
                        "如果您在中国大陆但被拦截，可能是 IP 库未覆盖，请管理员进入面板 [4] 更新 IP 库",
                        "如需关闭此限制，管理员可在面板 [4] 选择关闭",
                    },
                    "客户端 IP: " .. esc(ngx.var.remote_addr))
            end

            -- --------------------------------------------------------
            -- 拦截 2：客户端 UA 白名单
            -- 遍历共享字典里的 clients，用纯文本匹配（第四个参数 true）
            -- 关键字是包含关系，例如 "Emby" 能匹配 "Emby/2.0.83g"
            -- --------------------------------------------------------
            if dict:get("client_filter") == "1" then
                local ua = (ngx.var.http_user_agent or ""):lower()
                if ua == "" then
                    return render_error(403, "拒绝访问 · 缺少 User-Agent",
                        "请求未携带 User-Agent，无法识别客户端。",
                        {
                            "使用支持自定义 UA 的客户端",
                            "如使用浏览器，请确认未禁用 UA",
                        })
                end
                local allow = false
                for pat in string.gmatch(dict:get("clients") or "", "[^|]+") do
                    if pat ~= "" and ua:find(pat:lower(), 1, true) then
                        allow = true
                        break
                    end
                end
                if not allow then
                    return render_error(403, "拒绝访问 · 客户端未授权",
                        "当前客户端不在白名单中。",
                        {
                            "管理员可在面板 [3] 添加该客户端的 UA 关键字",
                            "关键字无需完整 UA，取特征片段即可（如 \"MyApp\"）",
                            "如怀疑误判，可临时在面板 [3] 关闭客户端过滤",
                        },
                        "您的 UA: " .. esc(ngx.var.http_user_agent))
                end
            end

            -- --------------------------------------------------------
            -- 解析 URL 路径：/https://example.com/path?query
            -- 拆成 pure_uri 和 args 两部分
            -- --------------------------------------------------------
            local uri = ngx.var.request_uri
            local pure_uri, args = uri:match("^([^?]*)%??(.*)$")
            local target = pure_uri:sub(2)   -- 去掉开头的 "/"

            -- 拦截 3：路径为空
            if target == "" then
                return render_error(400, "请求无效 · 缺少目标地址",
                    "您访问的是根路径，未指定要反代的目标地址。",
                    {
                        "正确格式： https://本域名/https://目标域名/路径",
                        "示例：      https://your.domain/https://example.com/video.mp4",
                    })
            end

            -- 拦截 4：地址过长
            if #target > 2048 then
                return render_error(414, "请求无效 · 目标地址过长",
                    "目标 URL 长度超过 2048 字符。",
                    { "请确认 URL 是否被重复拼接或包含冗余参数" })
            end

            -- 无协议时默认补 https://
            local url = target
            if not url:match("^https?://") then
                url = "https://" .. url
            end

            -- 拆解：scheme / host / path
            local scheme, host, path = url:match("^(https?://)([^/]+)(.*)")
            if not host then
                return render_error(400, "请求无效 · 目标地址格式错误",
                    "无法从路径中解析出目标域名。",
                    {
                        "检查目标地址是否包含非法字符",
                        "格式： /https://example.com/path",
                    },
                    "解析输入: " .. esc(target))
            end
            if path == "" then path = "/" end

            -- 剥掉端口，白名单比对时用裸主机名
            local host_no_port = host:lower():match("^([^:]+)") or host:lower()

            -- --------------------------------------------------------
            -- 拦截 5：目标域名白名单
            -- 支持精确匹配和子域名匹配（a.example.com 匹配 example.com）
            -- --------------------------------------------------------
            if dict:get("filter") == "1" then
                local allow = false
                for domain in string.gmatch(dict:get("domains") or "", "[^|]+") do
                    domain = domain:lower()
                    domain = domain:match("^([^:]+)") or domain
                    if host_no_port == domain or
                       (#host_no_port > #domain and host_no_port:sub(-#domain - 1) == "." .. domain) then
                        allow = true
                        break
                    end
                end
                if not allow then
                    return render_error(403, "拒绝访问 · 目标域名不在白名单",
                        "您尝试反代的目标域名未获授权。",
                        {
                            "管理员可在面板 [2] 添加该域名",
                            "如不需要限制，可在面板 [2] 关闭域名白名单",
                        },
                        "目标域名: " .. esc(host))
                end
            end

            -- --------------------------------------------------------
            -- 全部校验通过：把 URI 重写成目标 path，把参数恢复
            -- 然后设置三个变量，交给下面的 proxy_pass 使用
            -- --------------------------------------------------------
            ngx.req.set_uri(path)
            if args and args ~= "" then
                ngx.req.set_uri_args(args)
            end

            ngx.var.target_scheme = scheme:gsub("://", "")
            ngx.var.target_host = host
            ngx.var.target_path = path
            ngx.var.upstream = scheme .. host
        }

        # ============================================================
        # 代理设置
        # ============================================================
        proxy_pass $upstream;

        # 请求头：Host 改成目标域名；其余透传
        proxy_set_header Host $target_host;
        proxy_set_header X-Real-IP $remote_addr;
        proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto $target_scheme;

        # HTTPS 上游：开启 SNI，但不校验证书（因为目标是用户自己的 Emby）
        proxy_ssl_server_name on;
        proxy_ssl_name $target_host;
        proxy_ssl_verify off;

        # WebSocket 支持（Emby 客户端经常用长连接）
        proxy_http_version 1.1;
        proxy_set_header Upgrade $http_upgrade;
        proxy_set_header Connection "upgrade";

        # Range 请求：直接透传给 Emby，由源站决定返回哪一段
        # proxy_force_ranges off 是关键，可以让拖进度条更流畅、更省流量
        proxy_set_header Range $http_range;
        proxy_set_header If-Range $http_if_range;
        proxy_force_ranges off;

        # 不缓冲任何请求/响应，适合流媒体大文件
        proxy_buffering off;
        proxy_request_buffering off;
        proxy_max_temp_file_size 0;

        # 长超时（默认 24 小时，适合观看大文件）
        proxy_read_timeout 86400s;
        proxy_send_timeout 86400s;

        # 连接阶段超时（15 秒，避免目标挂掉时长时间挂起）
        proxy_connect_timeout 15s;
    }

    # ============================================================
    # 上游错误处理：500 / 502 / 503 / 504
    # 走 Lua 渲染，支持伪装模式
    # ============================================================
    error_page 500 502 503 504 = @upstream_error;
    location @upstream_error {
        content_by_lua_block {
            local dict = ngx.shared.allow_domain
            local status = ngx.status

            local function esc(s)
                if not s then return "" end
                s = tostring(s):gsub("[\r\n\t]", " ")
                return s
            end

            -- 每种状态码对应的标题 / 说明 / 建议
            local titles = {
                [500] = "源站内部错误",
                [502] = "源站连接失败",
                [503] = "源站暂不可用",
                [504] = "源站响应超时",
            }
            local details = {
                [500] = "目标服务器返回了 500 错误。",
                [502] = "无法连接目标服务器，可能是域名无法解析、端口不通或源站拒绝连接。",
                [503] = "目标服务器当前无法处理请求（过载或维护中）。",
                [504] = "等待目标服务器响应超时（连接阶段 15 秒超时）。",
            }
            local hints = {
                [500] = { "稍后重试，或确认目标地址正确" },
                [502] = {
                    "确认目标域名拼写正确",
                    "在服务器上用 curl 测试目标是否可达",
                    "检查 DNS：nslookup 目标域名",
                    "若为 HTTPS 目标，确认端口 443 未被封锁",
                },
                [503] = { "稍后重试" },
                [504] = { "稍后重试", "确认目标服务器未宕机" },
            }

            local title  = titles[status]  or "上游错误"
            local detail = details[status] or ("目标服务器返回 " .. tostring(status))
            local hint   = hints[status]   or { "稍后重试" }

            -- 组装调试文本
            local dbg_lines = {
                "原始状态码: " .. tostring(status),
                "原始说明:   " .. title,
                "详情:       " .. detail,
                "",
                "客户端: " .. esc(ngx.var.remote_addr),
                "请求:   " .. esc(ngx.var.request_method) .. " " .. esc(ngx.var.request_uri),
            }
            if ngx.var.http_user_agent then
                dbg_lines[#dbg_lines+1] = "UA:     " .. esc(ngx.var.http_user_agent)
            end
            local debug_text = table.concat(dbg_lines, "\n")

            -- 伪装模式
            if dict:get("camo") == "1" then
                local tpl = dict:get("camo_error_html")
                if tpl and tpl ~= "" then
                    local c_title, c_detail
                    if status == 503 then
                        c_title  = "服务维护中"
                        c_detail = "我们正在进行短暂维护，请稍后再来。"
                    elseif status == 504 then
                        c_title  = "响应超时"
                        c_detail = "服务器响应太慢，请稍后再试。"
                    else
                        c_title  = "服务暂时不可用"
                        c_detail = "后端服务没有响应，请稍后再试。"
                    end
                    local html = tpl
                    html = html:gsub("{{CODE}}",   tostring(status))
                    html = html:gsub("{{TITLE}}",  c_title)
                    html = html:gsub("{{DETAIL}}", c_detail)
                    local dbg = ""
                    if dict:get("debug") == "1" then
                        dbg = '<div class="debug">' .. debug_text .. '</div>'
                    end
                    html = html:gsub("{{DEBUG}}", dbg)
                    ngx.header.content_type = "text/html; charset=utf-8"
                    ngx.print(html)
                    return
                end
            end

            -- 普通模式：纯文本
            local L = {}
            L[#L+1] = string.rep("═", 44)
            L[#L+1] = string.format("  [%d] %s", status, title)
            L[#L+1] = string.rep("═", 44)
            L[#L+1] = ""
            L[#L+1] = detail
            L[#L+1] = ""
            L[#L+1] = "处理建议："
            for _, h in ipairs(hint) do
                L[#L+1] = "  · " .. h
            end
            L[#L+1] = ""
            L[#L+1] = string.rep("─", 44)
            L[#L+1] = "时间:   " .. os.date("%Y-%m-%d %H:%M:%S")
            L[#L+1] = "客户端: " .. esc(ngx.var.remote_addr)
            L[#L+1] = "请求:   " .. esc(ngx.var.request_method) .. " " .. esc(ngx.var.request_uri)
            if dict:get("debug") == "1" then
                L[#L+1] = string.rep("─", 44)
                L[#L+1] = "调试信息："
                L[#L+1] = "UA:     " .. esc(ngx.var.http_user_agent or "(空)")
                L[#L+1] = "Host:   " .. esc(ngx.var.host or "")
            end
            ngx.header.content_type = "text/plain; charset=utf-8"
            ngx.say(table.concat(L, "\n"))
        }
    }
LOC
    # 把生成的配置输出到 stdout（调用者会重定向到文件）
    cat /tmp/rp_location.$$
    rm -f /tmp/rp_location.$$
}


# ==============================================================================
# 十三、生成完整 nginx.conf
# ==============================================================================

make_nginx(){
    # 先重建白名单文件和 Lua 初始化脚本
    write_lua

    # 中国 IP 库缺失时，首次自动下载
    if [ "$CHINA_ONLY" = "1" ] && [ ! -f "$CHINA_IP_CONF" ]; then
        update_china_ip || true
    fi

    # server_name：域名模式用真实域名，IP 模式用通配符 _
    local sname="$DOMAIN"
    [ "$MODE" = "ip" ] && sname="_"

    # geo 块：用于判断 IP 是否在中国
    #   0.0.0.0/0 0  → 默认所有 IPv4 都不是中国
    #   ::/0 1       → 所有 IPv6 都当作中国（放行）
    #   include 里会覆盖成 1 表示中国的 IPv4 段
    local geo_block=""
    if [ "$CHINA_ONLY" = "1" ]; then
        geo_block="
    geo \$is_cn {
        include $CHINA_IP_CONF;
        0.0.0.0/0 0;
        ::/0 1;
    }
"
    fi

    # 生成 location 部分
    gen_proxy_location > /tmp/rp_loc.txt

    # ---------- 分支 1：域名 + HTTPS ----------
    if [ "$MODE" = "domain" ] && [ "$HTTPS" = "1" ]; then
        {
            cat <<EOF
worker_processes auto;
events { worker_connections 4096; }
http {
    include       mime.types;
    default_type  application/octet-stream;
    lua_shared_dict allow_domain 10m;
    init_by_lua_file $LUA;
$geo_block
    # 上游域名解析（用于动态反代）
    resolver 1.1.1.1 8.8.8.8 valid=300s ipv6=off;
    resolver_timeout 5s;

    # 性能相关
    sendfile on;
    tcp_nopush on;
    tcp_nodelay on;
    keepalive_timeout 65;

    # 上传大小不限制（Emby 可能有大文件）
    client_max_body_size 0;

    # 80 端口：ACME 验证 + 跳转 HTTPS
    server {
        listen 80;
        listen [::]:80;
        server_name $sname;
        location /.well-known/acme-challenge/ {
            root /var/www/acme;
            default_type text/plain;
        }
        location / {
            return 301 https://\$host\$request_uri;
        }
    }

    # 443 端口：HTTPS 反代
    server {
        listen 443 ssl;
        listen [::]:443 ssl;
        http2 on;
        server_name $sname;
        ssl_certificate     $SSL_DIR/$DOMAIN.fullchain.pem;
        ssl_certificate_key $SSL_DIR/$DOMAIN.key;
        ssl_protocols TLSv1.2 TLSv1.3;
        ssl_ciphers ECDHE-ECDSA-AES128-GCM-SHA256:ECDHE-RSA-AES128-GCM-SHA256:ECDHE-ECDSA-AES256-GCM-SHA384:ECDHE-RSA-AES256-GCM-SHA384:ECDHE-ECDSA-CHACHA20-POLY1305:ECDHE-RSA-CHACHA20-POLY1305;
        ssl_prefer_server_ciphers off;
        ssl_session_cache shared:SSL:10m;
        ssl_session_timeout 1d;
        ssl_session_tickets off;
        add_header Strict-Transport-Security "max-age=31536000; includeSubDomains" always;
EOF
            cat /tmp/rp_loc.txt
            cat <<EOF
    }
}
EOF
        } > "$NGINX"

    # ---------- 分支 2：IP 模式 / 域名但不开 HTTPS ----------
    else
        {
            cat <<EOF
worker_processes auto;
events { worker_connections 4096; }
http {
    include       mime.types;
    default_type  application/octet-stream;
    lua_shared_dict allow_domain 10m;
    init_by_lua_file $LUA;
$geo_block
    resolver 1.1.1.1 8.8.8.8 valid=300s ipv6=off;
    resolver_timeout 5s;
    sendfile on;
    tcp_nopush on;
    tcp_nodelay on;
    keepalive_timeout 65;
    client_max_body_size 0;

    server {
        listen 80;
        listen [::]:80;
        server_name $sname;
EOF
            cat /tmp/rp_loc.txt
            cat <<EOF
    }
}
EOF
        } > "$NGINX"
    fi
    rm -f /tmp/rp_loc.txt

    # 配置语法检查
    if ! openresty -t 2>/tmp/rp_test_err.txt; then
        red "❌ 配置检测失败："
        cat /tmp/rp_test_err.txt
        rm -f /tmp/rp_test_err.txt
        return 1
    fi
    rm -f /tmp/rp_test_err.txt

    # 通过检查 → 重启服务
    svc_restart
    green "✅ 配置已加载"
    blue "ℹ️ nginx.conf 大小: $(wc -c < "$NGINX") 字节"
}


# ==============================================================================
# 十四、功能菜单
# ==============================================================================

# 首次安装：装依赖、选模式、申请证书、生成全部配置
install(){
    header
    subheader "安装 / 初始化"

    install_pkg
    install_openresty || { pause; return; }

    # 选择部署模式
    echo
    echo -e "  \033[1m请选择部署模式：\033[0m"
    echo -e "    \033[32m[1]\033[0m 域名（可申请 HTTPS 证书）"
    echo -e "    \033[32m[2]\033[0m IP  （仅 HTTP，不需要证书）"
    echo
    read -p "  选择 [1/2]: " MODE_CHOICE
    case "$MODE_CHOICE" in
        2)
            MODE="ip"
            DOMAIN=""
            HTTPS="0"
            ;;
        *)
            MODE="domain"
            read -p "  绑定域名: " DOMAIN
            if [ -z "$DOMAIN" ]; then
                red "❌ 域名不能为空"
                pause
                return
            fi
            read -p "  开启 HTTPS？(y/N): " SSL_CHOICE
            [[ "$SSL_CHOICE" =~ ^[yY]$ ]] && HTTPS="1" || HTTPS="0"
            ;;
    esac

    # 初始化其他字段
    FILTER="0"
    ALLOW_DOMAIN=""
    CLIENT_FILTER="0"
    CLIENT_ALLOW="$DEFAULT_CLIENTS"
    CHINA_ONLY="1"
    CAMO="0"
    DEBUG="0"
    INSTALLED_VER="$VER"
    save

    # 下载中国 IP 库
    if [ "$CHINA_ONLY" = "1" ]; then
        update_china_ip || yellow "⚠️ IP 库更新失败，可稍后在菜单 [4] 重试"
    fi

    # 域名 + HTTPS 时申请证书
    if [ "$MODE" = "domain" ] && [ "$HTTPS" = "1" ]; then
        install_acme || { red "❌ acme 安装失败，回退 HTTP"; HTTPS="0"; save; }
        if [ "$HTTPS" = "1" ]; then
            issue_cert "$DOMAIN" || { red "❌ 证书失败，回退 HTTP"; HTTPS="0"; save; }
        fi
    fi

    # 生成全部配置
    make_systemd
    make_nginx
    make_logrotate
    svc_restart

    # 输出访问格式
    echo
    green "✅ 部署成功"
    echo -e "  \033[36m──────────────────────────────────────────\033[0m"
    if [ "$MODE" = "ip" ]; then
        LOCAL_IP=$(hostname -I | awk '{print $1}')
        echo -e "  访问格式: \033[1mhttp://$LOCAL_IP/目标地址\033[0m"
    elif [ "$HTTPS" = "1" ]; then
        echo -e "  访问格式: \033[1mhttps://$DOMAIN/目标地址\033[0m"
    else
        echo -e "  访问格式: \033[1mhttp://$DOMAIN/目标地址\033[0m"
    fi
    pause
}

# 升级：保留现有配置，仅补新字段、重建配置文件
upgrade(){
    header
    subheader "升级脚本"

    # 环境检查
    if [ ! -f "$CONF" ]; then
        red "❌ 未检测到已安装的配置，请先执行 [1] 安装"
        pause
        return
    fi
    if ! command -v openresty >/dev/null 2>&1; then
        red "❌ 未检测到 OpenResty，环境不完整，请先执行 [1] 安装"
        pause
        return
    fi

    blue "ℹ️ 已安装版本: ${INSTALLED_VER:-未知}"
    blue "ℹ️ 当前脚本版本: $VER"
    echo

    # 已经是最新版时，询问是否强制刷新
    if [ "${INSTALLED_VER:-}" = "$VER" ]; then
        yellow "⚠️ 已是最新版本"
        read -p "  仍要强制重新应用配置？(y/N): " FORCE
        [[ "$FORCE" =~ ^[yY]$ ]] || return
    fi

    # 提示升级会做什么
    echo -e "  \033[1m本次升级将执行：\033[0m"
    echo "    · 备份现有配置 (emby-rp.conf / nginx.conf / lua_init.lua)"
    echo "    · 补充新增配置字段"
    echo "    · 重新生成白名单文件 / lua_init.lua / camo_error.html / nginx.conf"
    echo "    · 重启 emby-proxy 服务"
    echo "    · 保留：模式、域名、证书、systemd、logrotate、中国 IP 库、各类白名单"
    echo
    read -p "  确认升级？(y/N): " OK
    [[ "$OK" =~ ^[yY]$ ]] || { yellow "已取消"; return; }

    # 备份
    local ts
    ts=$(date +%Y%m%d_%H%M%S)
    [ -f "$CONF" ]  && cp -a "$CONF"  "${CONF}.bak.$ts"
    [ -f "$NGINX" ] && cp -a "$NGINX" "${NGINX}.bak.$ts"
    [ -f "$LUA" ]   && cp -a "$LUA"   "${LUA}.bak.$ts"
    blue "ℹ️ 备份完成: *.bak.$ts"

    # 读取现有配置
    source "$CONF"

    # 补齐所有可能缺失的字段
    : "${MODE:=domain}"
    : "${DOMAIN:=}"
    : "${HTTPS:=0}"
    : "${CHINA_ONLY:=1}"
    : "${FILTER:=0}"
    : "${ALLOW_DOMAIN:=}"
    : "${CAMO:=0}"
    : "${CLIENT_FILTER:=0}"
    : "${DEBUG:=0}"
    if [ -z "${CLIENT_ALLOW+x}" ]; then
        CLIENT_ALLOW="$DEFAULT_CLIENTS"
        green "✅ 已注入默认客户端白名单（可进入 [3] 调整）"
    fi

    INSTALLED_VER="$VER"
    save

    # 重建配置（不动证书、不动 systemd、不动 logrotate）
    make_systemd
    if ! make_nginx; then
        red "❌ 升级失败，已保留备份，请检查上方报错"
        yellow "ℹ️ 可用备份恢复: cp -a ${CONF}.bak.$ts $CONF"
        pause
        return
    fi

    echo
    green "✅ 升级完成，当前版本: $VER"
    echo -e "  \033[36m──────────────────────────────────────────\033[0m"
    echo "  本版本变更："
    echo "    · Range 请求透传给 Emby，拖进度条更流畅、更省流量"
    echo
    echo "  累积功能："
    echo "    · 客户端白名单（User-Agent）—— 菜单 [3]"
    echo "    · 详细错误提示 + 伪装错误页 + 调试模式 —— 菜单 [5] / [10]"
    echo "    · 升级功能 —— 菜单 [9]"
    echo
    pause
}

# 更新证书
renew_cert(){
    header
    subheader "更新证书"

    if [ "$MODE" != "domain" ] || [ -z "$DOMAIN" ]; then
        red "❌ 当前不是域名模式，无法申请证书"
        pause
        return
    fi
    if [ "$HTTPS" != "1" ]; then
        HTTPS="1"
        save
    fi
    install_acme || { pause; return; }
    issue_cert "$DOMAIN" && make_nginx && green "✅ 证书已更新" || red "❌ 更新失败"
    pause
}

# 中国 IP 限制菜单
china_ip_menu(){
    while true; do
        header
        subheader "中国大陆 IP 限制"

        echo -n "  状态:   "
        [ "$CHINA_ONLY" = "1" ] && status_on || status_off
        [ -f "$CHINA_IP_CONF" ] && echo "  IPv4库: $(wc -l < "$CHINA_IP_CONF") 条"
        echo "  IPv6:   默认放行"
        echo
        echo -e "    \033[32m[1]\033[0m 开启限制"
        echo -e "    \033[32m[2]\033[0m 关闭限制"
        echo -e "    \033[32m[3]\033[0m 更新 IP 库"
        echo -e "    \033[32m[0]\033[0m 返回"
        echo
        read -p "  选择: " C
        case $C in
            1) CHINA_ONLY="1"; [ ! -f "$CHINA_IP_CONF" ] && update_china_ip ;;
            2) CHINA_ONLY="0" ;;
            3) update_china_ip ;;
            0) save; make_nginx; return ;;
            *) red "❌ 输入错误" ;;
        esac
        save
        make_nginx
    done
}

# 域名白名单菜单
white(){
    while true; do
        header
        subheader "域名白名单"

        echo -n "  状态:   "
        [ "$FILTER" = "1" ] && status_on || status_off
        echo "  列表:   ${ALLOW_DOMAIN:-无}"
        echo
        echo -e "    \033[32m[1]\033[0m 开启限制"
        echo -e "    \033[32m[2]\033[0m 关闭限制"
        echo -e "    \033[32m[3]\033[0m 添加域名"
        echo -e "    \033[32m[4]\033[0m 删除域名"
        echo -e "    \033[32m[5]\033[0m 清空域名"
        echo -e "    \033[32m[0]\033[0m 返回"
        echo
        read -p "  选择: " W
        case $W in
            1) FILTER="1" ;;
            2) FILTER="0" ;;
            3)
                # 添加域名
                read -p "  域名: " ADD
                [ -n "$ADD" ] && {
                    [ -z "$ALLOW_DOMAIN" ] && ALLOW_DOMAIN="$ADD" || ALLOW_DOMAIN="$ALLOW_DOMAIN|$ADD"
                }
                ;;
            4)
                # 删除域名：重建一个不含目标的新字符串
                read -p "  删除: " DEL
                NEW=""
                IFS="|" read -ra ARR <<< "$ALLOW_DOMAIN"
                for d in "${ARR[@]}"; do
                    [ "$d" != "$DEL" ] && [ -n "$d" ] && {
                        [ -z "$NEW" ] && NEW="$d" || NEW="$NEW|$d"
                    }
                done
                ALLOW_DOMAIN="$NEW"
                ;;
            5) ALLOW_DOMAIN="" ;;
            0) save; make_nginx; return ;;
            *) red "❌ 输入错误" ;;
        esac
        save
        make_nginx
    done
}

# 客户端白名单菜单
client_menu(){
    while true; do
        header
        subheader "客户端白名单（User-Agent）"

        echo -n "  状态:   "
        [ "$CLIENT_FILTER" = "1" ] && status_on || status_off
        echo "  说明:   开启后，仅放行 User-Agent 含下列关键字的客户端"
        echo
        # 带序号列出当前列表
        echo "  当前列表："
        if [ -n "$CLIENT_ALLOW" ]; then
            local idx=1
            IFS="|" read -ra ARR <<< "$CLIENT_ALLOW"
            for c in "${ARR[@]}"; do
                [ -n "$c" ] && { printf "    %2d. %s\n" "$idx" "$c"; idx=$((idx+1)); }
            done
        else
            echo "    （空）"
        fi
        echo
        echo -e "    \033[32m[1]\033[0m 开启限制"
        echo -e "    \033[32m[2]\033[0m 关闭限制"
        echo -e "    \033[32m[3]\033[0m 添加客户端关键字"
        echo -e "    \033[32m[4]\033[0m 删除客户端关键字"
        echo -e "    \033[32m[5]\033[0m 清空列表"
        echo -e "    \033[32m[6]\033[0m 重置为默认客户端"
        echo -e "    \033[32m[0]\033[0m 返回"
        echo
        read -p "  选择: " C
        case $C in
            1) CLIENT_FILTER="1"; save; make_nginx ;;
            2) CLIENT_FILTER="0"; save; make_nginx ;;
            3)
                read -p "  关键字: " ADD
                if [ -n "$ADD" ]; then
                    [ -z "$CLIENT_ALLOW" ] && CLIENT_ALLOW="$ADD" || CLIENT_ALLOW="$CLIENT_ALLOW|$ADD"
                fi
                save; make_nginx
                ;;
            4)
                read -p "  删除: " DEL
                NEW=""
                IFS="|" read -ra ARR <<< "$CLIENT_ALLOW"
                for c in "${ARR[@]}"; do
                    [ "$c" != "$DEL" ] && [ -n "$c" ] && {
                        [ -z "$NEW" ] && NEW="$c" || NEW="$NEW|$c"
                    }
                done
                CLIENT_ALLOW="$NEW"
                save; make_nginx
                ;;
            5) CLIENT_ALLOW=""; save; make_nginx ;;
            6) CLIENT_ALLOW="$DEFAULT_CLIENTS"; save; make_nginx ;;
            0) return ;;
            *) red "❌ 输入错误" ;;
        esac
    done
}

# 首页伪装菜单
camo_menu(){
    while true; do
        header
        subheader "首页伪装"

        echo -n "  状态:   "
        [ "$CAMO" = "1" ] && status_on || status_off
        echo "  说明:   开启后，根路径 / 错误页均返回博客风格页面"
        echo "          错误页会自动翻译为博客文案（如“这一页走丢了”）"
        echo "          关闭后，恢复详细的纯文本错误提示"
        echo
        echo -e "    \033[32m[1]\033[0m 开启伪装"
        echo -e "    \033[32m[2]\033[0m 关闭伪装"
        echo -e "    \033[32m[3]\033[0m 预览首页伪装"
        echo -e "    \033[32m[4]\033[0m 预览错误页伪装"
        echo -e "    \033[32m[0]\033[0m 返回"
        echo
        read -p "  选择: " C
        case $C in
            1) CAMO="1"; save; make_nginx ;;
            2) CAMO="0"; save; make_nginx ;;
            3)
                if [ -f "$CAMO_FILE" ]; then
                    echo
                    blue "ℹ️ 首页伪装: $CAMO_FILE"
                    echo "  大小: $(wc -c < "$CAMO_FILE") 字节"
                else
                    yellow "⚠️ 尚未生成，请先开启一次伪装"
                fi
                pause
                ;;
            4)
                if [ -f "$CAMO_ERROR_FILE" ]; then
                    echo
                    blue "ℹ️ 错误页伪装: $CAMO_ERROR_FILE"
                    echo "  大小: $(wc -c < "$CAMO_ERROR_FILE") 字节"
                    echo "  占位符: {{CODE}} {{TITLE}} {{DETAIL}} {{DEBUG}}"
                else
                    yellow "⚠️ 尚未生成，请先开启一次伪装"
                fi
                pause
                ;;
            0) return ;;
            *) red "❌ 输入错误" ;;
        esac
    done
}

# 高级设置：调试模式开关
advanced_menu(){
    while true; do
        header
        subheader "高级设置"

        echo -n "  调试模式: "
        [ "$DEBUG" = "1" ] && status_on || status_off
        echo "  说明:     开启后，错误页面会附加 UA / Host / Referer 等信息"
        echo "            伪装模式下也会在页面底部显示调试块"
        echo
        echo -e "    \033[32m[1]\033[0m 开启调试模式"
        echo -e "    \033[32m[2]\033[0m 关闭调试模式"
        echo -e "    \033[32m[0]\033[0m 返回"
        echo
        read -p "  选择: " C
        case $C in
            1) DEBUG="1"; save; make_nginx ;;
            2) DEBUG="0"; save; make_nginx ;;
            0) return ;;
            *) red "❌ 输入错误" ;;
        esac
    done
}

# 查看当前配置
show(){
    header
    subheader "当前配置"

    echo -e "  脚本版本: $VER"
    echo -e "  已安装:   ${INSTALLED_VER:-未知}"
    echo
    echo -e "  模式:     $([ "$MODE" = "ip" ] && echo "IP" || echo "域名")"
    if [ "$MODE" = "domain" ]; then
        echo -e "  域名:     $DOMAIN"
        echo -n "  HTTPS:    "; [ "$HTTPS" = "1" ] && status_on || status_off
    else
        LOCAL_IP=$(hostname -I | awk '{print $1}')
        echo -e "  本机IP:   $LOCAL_IP"
    fi
    echo -n "  中国IP:   "; [ "$CHINA_ONLY" = "1" ] && green "已开启（IPv6 放行）" || status_off
    echo -n "  首页伪装: "; [ "$CAMO" = "1" ] && status_on || status_off
    echo -n "  调试模式: "; [ "$DEBUG" = "1" ] && status_on || status_off
    echo -n "  域名白名单: "; [ "$FILTER" = "1" ] && status_on || status_off
    echo -e "  域名列表: ${ALLOW_DOMAIN:-无}"
    echo -n "  客户端过滤: "; [ "$CLIENT_FILTER" = "1" ] && status_on || status_off
    echo -e "  客户端列表: ${CLIENT_ALLOW:-无}"

    # 显示证书到期时间
    if [ "$MODE" = "domain" ] && [ "$HTTPS" = "1" ] && [ -f "$SSL_DIR/$DOMAIN.fullchain.pem" ]; then
        echo -n "  证书到期: "
        openssl x509 -in "$SSL_DIR/$DOMAIN.fullchain.pem" -noout -enddate 2>/dev/null | cut -d= -f2 || echo "未知"
    fi
    echo -e "  nginx.conf: $(wc -c < "$NGINX" 2>/dev/null || echo 0) 字节"
    echo -e "  日志保留:   7 天"
    pause
}

# 重载服务
reload(){
    header
    subheader "重载服务"

    if openresty -t >/dev/null 2>&1; then
        svc_reload
        green "✅ 重载成功"
    else
        red "❌ 配置错误"
        openresty -t
    fi
    pause
}

# 卸载
remove(){
    header
    subheader "卸载"

    yellow "将卸载 OpenResty、证书、配置、IP 库、logrotate、伪装页、白名单"
    echo
    read -p "  确认卸载？(y/N): " OK
    if [[ "$OK" =~ ^[yY]$ ]]; then
        svc_stop
        systemctl disable emby-proxy 2>/dev/null || true
        apt remove --purge -y openresty* >/dev/null 2>&1
        apt autoremove -y >/dev/null 2>&1
        rm -rf "$CONF" "$SERVICE" "$SSL_DIR" \
               "$ACME_HOME" "$ACME_WEBROOT" "$CHINA_IP_CONF" \
               "$ALLOW_FILE" "$CLIENT_FILE" "$LOGROTATE" \
               "$CAMO_FILE" "$CAMO_ERROR_FILE" \
               /etc/apt/sources.list.d/openresty.list \
               /usr/share/keyrings/openresty.gpg
        # 清掉 acme.sh 的定时任务
        crontab -l 2>/dev/null | grep -v 'acme.sh' | crontab - 2>/dev/null || true
        systemctl daemon-reload
        green "✅ 已卸载"
    else
        yellow "已取消"
    fi
    pause
}


# ==============================================================================
# 十五、主菜单
# ==============================================================================

menu(){
    while true; do
        header

        # 版本差异提示
        if [ -f "$CONF" ] && [ "${INSTALLED_VER:-}" != "$VER" ]; then
            yellow "⚠️ 检测到版本差异：已安装 ${INSTALLED_VER:-未知}  →  脚本 $VER"
            echo -e "   建议进入 \033[32m[9] 升级脚本\033[0m 应用新功能"
            echo
        fi

        echo -e "  \033[1m请选择操作：\033[0m"
        echo
        echo -e "    \033[32m[1]\033[0m  安装 / 初始化"
        echo -e "    \033[32m[2]\033[0m  域名白名单"
        echo -e "    \033[32m[3]\033[0m  客户端白名单"
        echo -e "    \033[32m[4]\033[0m  中国IP限制"
        echo -e "    \033[32m[5]\033[0m  首页伪装"
        echo -e "    \033[32m[6]\033[0m  查看配置"
        echo -e "    \033[32m[7]\033[0m  重载服务"
        echo -e "    \033[32m[8]\033[0m  更新证书"
        echo -e "    \033[32m[9]\033[0m  升级脚本"
        echo -e "    \033[32m[10]\033[0m 高级设置"
        echo -e "    \033[32m[11]\033[0m 卸载"
        echo -e "    \033[32m[0]\033[0m  退出"
        echo
        read -p "  选择: " M
        case $M in
            1) install ;;
            2) white ;;
            3) client_menu ;;
            4) china_ip_menu ;;
            5) camo_menu ;;
            6) show ;;
            7) reload ;;
            8) renew_cert ;;
            9) upgrade ;;
            10) advanced_menu ;;
            11) remove ;;
            0) clear; exit 0 ;;
            *) red "❌ 输入错误" ;;
        esac
    done
}


# ==============================================================================
# 十六、入口
# ==============================================================================

# 必须以 root 运行
if [ "$(id -u)" != "0" ]; then
    red "❌ 请使用 root 运行"
    exit 1
fi

# 读取配置
init

# 进入主菜单
menu
