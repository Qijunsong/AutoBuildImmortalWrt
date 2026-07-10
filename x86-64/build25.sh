#!/bin/bash
# Log file for debugging
# 目前支持少部分第三方软件apk 通过打开shell/apk-custom-packages.sh的注释来集成
source shell/apk-custom-packages.sh
echo "第三方apk软件包: $CUSTOM_PACKAGES"
LOGFILE="/tmp/uci-defaults-log.txt"
echo "Starting 99-custom.sh at $(date)" >> $LOGFILE

# 将代表分区大小的变量重命名，防止与编译器的 PROFILE 冲突
ROOTFS_SIZE="${PROFILE:-256}" 
echo "预设根文件系统分区大小为: ${ROOTFS_SIZE} MB"
echo "Include Docker: $INCLUDE_DOCKER"

# 是否单独集成 CloudDrive2 核心程序（推荐保持 "yes"，防止仓库源里缺核心二进制）
INTEGRATE_CD2_CORE="yes"

# 明确核心绝对路径，根绝因执行路径切换导致的“找不到文件”问题
BASE_DIR="/home/build/immortalwrt"
FILES_DIR="$BASE_DIR/files"

echo "Create pppoe-settings"
mkdir -p "$FILES_DIR/etc/config"

# 创建pppoe配置文件 yml传入环境变量ENABLE_PPPOE等 写入配置文件 供99-custom.sh读取
cat << EOF > "$FILES_DIR/etc/config/pppoe-settings"
enable_pppoe=${ENABLE_PPPOE}
pppoe_account=${PPPOE_ACCOUNT}
pppoe_password=${PPPOE_PASSWORD}
EOF

echo "cat pppoe-settings"
cat "$FILES_DIR/etc/config/pppoe-settings"

if [ -z "$CUSTOM_PACKAGES" ]; then
  echo "⚪️ 未选择 任何第三方软件包"
else
  # ============= 同步第三方插件库==============
  echo "🔄 正在同步第三方软件仓库 Cloning run file repo..."
  git clone --depth=1 https://github.com/wukongdaily/apk.git /tmp/store-apk-repo

  # 拷贝 run/x86 下所有 run 文件和apk文件 到 extra-packages 目录
  mkdir -p "$BASE_DIR/extra-packages"
  cp -r /tmp/store-apk-repo/run/x86/* "$BASE_DIR/extra-packages/"

  echo "✅ Run files copied to extra-packages:"
  # 解压并拷贝apk到packages目录
  sh shell/apk-prepare-packages.sh
  ls -lah "$BASE_DIR/packages/"
fi

# 输出调试信息
echo "$(date '+%Y-%m-%d %H:%M:%S') - 开始构建固件..."

# ============= imm仓库内的插件==============
PACKAGES=""
PACKAGES="$PACKAGES curl"
PACKAGES="$PACKAGES luci-i18n-diskman-zh-cn"
PACKAGES="$PACKAGES luci-i18n-firewall-zh-cn"
PACKAGES="$PACKAGES luci-theme-argon"
PACKAGES="$PACKAGES luci-app-argon-config"
PACKAGES="$PACKAGES luci-i18n-argon-config-zh-cn"
#25.12
PACKAGES="$PACKAGES luci-i18n-package-manager-zh-cn"
PACKAGES="$PACKAGES luci-i18n-ttyd-zh-cn"

# 文件管理器与 SFTP
PACKAGES="$PACKAGES openssh-sftp-server"
PACKAGES="$PACKAGES luci-i18n-filemanager-zh-cn"

# 🔥【加回 CloudDrive2】只留界面和中文语言包，移除了会导致报错的纯 clouddrive2 字段
PACKAGES="$PACKAGES luci-app-clouddrive2 luci-i18n-clouddrive2-zh-cn"

# Passwall 2 及其核心组件（⚠️已彻底移除了导致报错的旧版 shadowsocks-libev-ss-server）
PACKAGES="$PACKAGES luci-app-passwall2 luci-i18n-passwall2-zh-cn xray-core hysteria sing-box chinadns-ng geoview shadowsocks-rust-ssserver kmod-fuse"

# ======== shell/apk-custom-packages.sh =======
PACKAGES="$PACKAGES $CUSTOM_PACKAGES"

# 判断是否需要编译 Docker 插件
if [ "$INCLUDE_DOCKER" = "yes" ]; then
    PACKAGES="$PACKAGES luci-i18n-dockerman-zh-cn"
    echo "Adding package: luci-i18n-dockerman-zh-cn"
fi

# 若构建openclash 则添加内核
if echo "$PACKAGES" | grep -q "luci-app-openclash"; then
    echo "✅ 已选择 luci-app-openclash，添加 openclash core"
    mkdir -p "$FILES_DIR/etc/openclash/core"
    
    # Download clash_meta
    META_URL="https://raw.githubusercontent.com/vernesong/OpenClash/core/master/meta/clash-linux-amd64-v1.tar.gz"
    wget -qO- $META_URL | tar xOvz > "$FILES_DIR/etc/openclash/core/clash_meta"
    chmod +x "$FILES_DIR/etc/openclash/core/clash_meta"
    
    # Download GeoIP and GeoSite
    wget -q https://github.com/Loyalsoldier/v2ray-rules-dat/releases/latest/download/geoip.dat -O "$FILES_DIR/etc/openclash/GeoIP.dat"
    wget -q https://github.com/Loyalsoldier/v2ray-rules-dat/releases/latest/download/geosite.dat -O "$FILES_DIR/etc/openclash/GeoSite.dat"
    
    # Download latest openclash Client
    URL=$(curl -s https://api.github.com/repos/vernesong/OpenClash/releases/latest \
      | grep "browser_download_url.*apk" \
      | head -n1 \
      | cut -d '"' -f 4)
    echo "OpenClash latest apk: $URL"
    if [ -n "$URL" ]; then
        wget "$URL" -P "$BASE_DIR/packages/"
    fi
else
    echo "⚪️ 未选择 luci-app-openclash"
fi

if echo "$PACKAGES" | grep -q "luci-app-ssr-plus"; then
    echo "✅ 已选择 luci-app-ssr-plus，添加 mihomo core"
    mkdir -p "$FILES_DIR/usr/bin"
    # Download mihomo
    MIHOMO_URL="https://github.com/MetaCubeX/mihomo/releases/download/v1.19.24/mihomo-linux-amd64-compatible-v1.19.24.gz"
    wget -qO- "$MIHOMO_URL" | gzip -dc > "$FILES_DIR/usr/bin/mihomo"
    chmod +x "$FILES_DIR/usr/bin/mihomo"
    echo "✅ 已下载 mihomo core"
    ls -lah "$FILES_DIR/usr/bin"
else
    echo "⚪️ 未选择 luci-app-ssr-plus"
fi

# ✨ 独立下载并打包官方 CloudDrive2 Linux x86_64 核心二进制程序
if [ "$INTEGRATE_CD2_CORE" = "yes" ]; then
    echo "✅ 正在从官方源拉取 CloudDrive2 v1.0.11 Linux x86_64 核心..."
    mkdir -p "$FILES_DIR/usr/bin"
    
    # 依据你提供的资产配置精准直链
    CD2_URL="https://github.com/cloud-fs/cloud-fs.github.io/releases/download/v1.0.11/clouddrive-2-linux-x86_64-1.0.11.tgz"
    
    mkdir -p /tmp/cd2-unpack
    wget -qO- "$CD2_URL" | tar -xzvC /tmp/cd2-unpack
    
    # 提取核心文件至固件 /usr/bin/clouddrive
    if [ -f "/tmp/cd2-unpack/clouddrive-2/clouddrive" ]; then
        cp /tmp/cd2-unpack/clouddrive-2/clouddrive "$FILES_DIR/usr/bin/clouddrive"
    elif [ -f "/tmp/cd2-unpack/clouddrive" ]; then
        cp /tmp/cd2-unpack/clouddrive "$FILES_DIR/usr/bin/clouddrive"
    fi
    
    chmod +x "$FILES_DIR/usr/bin/clouddrive"
    rm -rf /tmp/cd2-unpack
    echo "✅ CloudDrive2 核心程序已成功注入到 /usr/bin/clouddrive"
else
    echo "⚪️ 未启用 CloudDrive2 核心集成"
fi

# 构建镜像
echo "$(date '+%Y-%m-%d %H:%M:%S') - Building image with the following packages:"
echo "$PACKAGES"

# 执行编译
make image PROFILE="generic" PACKAGES="$PACKAGES" FILES="$FILES_DIR" ROOTFS_PARTSIZE=$ROOTFS_SIZE

if [ $? -ne 0 ]; then
    echo "$(date '+%Y-%m-%d %H:%M:%S') - Error: Build failed!"
    exit 1
fi

echo "$(date '+%Y-%m-%d %H:%M:%S') - Build completed successfully."
