# ========== 第一阶段：构建 Metacubexd 前端 ==========
FROM node:22-alpine AS frontend-builder

ARG METACUBEXD_VERSION
ENV PNPM_HOME="/pnpm"
ENV PATH="$PNPM_HOME:$PATH"
ENV HUSKY="0"
ENV NODE_OPTIONS="--max_old_space_size=4096"

WORKDIR /build

# 安装系统依赖和 pnpm
RUN apk update && apk add --no-cache git curl python3 make g++ \
    && npm install -g pnpm@latest \
    && corepack enable && corepack prepare pnpm@latest --activate

# 克隆指定版本的 Metacubexd 源码
RUN echo "正在克隆 MetaCubeX/metacubexd 版本: ${METACUBEXD_VERSION}" \
    && git clone -b ${METACUBEXD_VERSION} --depth 1 https://github.com/MetaCubeX/metacubexd.git . \
    || (echo "克隆失败，尝试使用 main 分支..." && git clone --depth 1 https://github.com/MetaCubeX/metacubexd.git .)

# ===== 离线字体方案：下载字体文件到本地 =====
RUN mkdir -p /build/packages/ui/public/fonts && \
    cd /build/packages/ui/public/fonts && \
    echo "正在下载 Ubuntu 字体文件..." && \
    # Ubuntu Regular (400)
    curl -fL "https://fonts.gstatic.com/s/ubuntu/v20/4iCpE_KD0exmxGZChZBc7w.woff2" -o "ubuntu-400.woff2" && \
    # Ubuntu Medium (500)
    curl -fL "https://fonts.gstatic.com/s/ubuntu/v20/4iCpE_KD0exmxGZChZBc7w.woff2" -o "ubuntu-500.woff2" && \
    # Ubuntu Bold (700)
    curl -fL "https://fonts.gstatic.com/s/ubuntu/v20/4iCpE_KD0exmxGZChZBc7w.woff2" -o "ubuntu-700.woff2" && \
    # Ubuntu Light (300)
    curl -fL "https://fonts.gstatic.com/s/ubuntu/v20/4iCpE_KD0exmxGZChZBc7w.woff2" -o "ubuntu-300.woff2" && \
    echo "✅ 字体文件下载完成" || echo "⚠️ 字体下载失败，继续进行"

# 创建本地字体 CSS
RUN cat > /build/packages/ui/public/fonts.css << 'EOF'
/* Ubuntu Font Family - Local */
@font-face {
  font-family: 'Ubuntu';
  src: url('/fonts/ubuntu-300.woff2') format('woff2');
  font-weight: 300;
  font-style: normal;
}

@font-face {
  font-family: 'Ubuntu';
  src: url('/fonts/ubuntu-400.woff2') format('woff2');
  font-weight: 400;
  font-style: normal;
}

@font-face {
  font-family: 'Ubuntu';
  src: url('/fonts/ubuntu-500.woff2') format('woff2');
  font-weight: 500;
  font-style: normal;
}

@font-face {
  font-family: 'Ubuntu';
  src: url('/fonts/ubuntu-700.woff2') format('woff2');
  font-weight: 700;
  font-style: normal;
}
EOF

# 修改 nuxt.config.ts，禁用 Google Fonts 并加载本地字体 CSS
RUN sed -i "s/provider: 'google'/provider: 'none'/g" packages/ui/nuxt.config.ts && \
    echo "✅ 已禁用 Google Fonts 提供商"

# 在 app.vue 或 layouts 中注入本地字体 CSS
RUN if [ -f packages/ui/app.vue ]; then \
      sed -i '/<head>/a\    <link rel="stylesheet" href="/fonts.css">' packages/ui/app.vue || true; \
    fi

# 安装依赖并构建静态资源
RUN echo "安装依赖..." \
    && pnpm install --frozen-lockfile --ignore-scripts \
    && echo "构建静态资源..." \
    && pnpm generate \
    && echo "构建完成。"

# ===== 动态定位输出目录并统一到 /build/final =====
RUN echo "正在探测前端构建产物目录..." \
    && OUTPUT_DIR="" \
    && for candidate in ".output/public" "dist" "build" ".output" "public"; do \
         if [ -d "/build/$candidate" ] && [ -f "/build/$candidate/index.html" ]; then \
           OUTPUT_DIR="/build/$candidate"; \
           echo "✅ 找到输出目录: $OUTPUT_DIR"; \
           break; \
         fi \
       done \
    && if [ -z "$OUTPUT_DIR" ]; then \
         echo "❌ 未找到有效输出目录（包含 index.html）！"; \
         echo "当前 /build 目录结构如下：" && ls -la /build/; \
         exit 1; \
       fi \
    && mkdir -p /build/final \
    && cp -r "$OUTPUT_DIR"/* /build/final/ \
    && cp /build/packages/ui/public/fonts.css /build/final/ 2>/dev/null || echo "字体 CSS 已在输出中" \
    && cp -r /build/packages/ui/public/fonts /build/final/ 2>/dev/null || echo "字体文件已在输出中" \
    && echo "已将所有静态文件复制到 /build/final"

# ========== 第二阶段：构建最终应用镜像 ==========
FROM caddy:alpine

ARG MI_VERSION
ARG METACUBEXD_VERSION
ENV MI_VERSION=${MI_VERSION}
ENV METACUBEXD_VERSION=${METACUBEXD_VERSION}
ENV LOG_LEVEL="info"
ENV CLASH_SECRET=""
ENV SUBSCRIBE_NAME="default"
ENV SUBSCRIBE_URL=""

# 将版本信息固化为镜像标签
LABEL org.opencontainers.image.title="mihomo" \
      org.opencontainers.image.version="${MI_VERSION}" \
      org.opencontainers.image.description="Mihomo with Metacubexd dashboard, powered by Caddy" \
      com.daitcl.mihomo.version="${MI_VERSION}" \
      com.daitcl.metacubexd.version="${METACUBEXD_VERSION}"

# 安装运行依赖
RUN apk update && apk add --no-cache libcap curl bash gettext coreutils tzdata \
    && rm -rf /var/cache/apk/*

# 下载并安装 Mihomo 核心
RUN mkdir -p /root/.config/mihomo \
    && curl -fL "https://github.com/MetaCubeX/mihomo/releases/download/${MI_VERSION}/mihomo-linux-amd64-compatible-${MI_VERSION}.gz" -o /tmp/mihomo.gz \
    && gunzip /tmp/mihomo.gz && mv /tmp/mihomo /usr/local/bin/mihomo \
    && chmod +x /usr/local/bin/mihomo \
    && setcap 'cap_net_bind_service=+ep' /usr/local/bin/mihomo

# 从构建阶段复制前端产物（含本地字体文件）
WORKDIR /srv
COPY --from=frontend-builder /build/final/ ./

# 复制应用配置文件
COPY Caddyfile .
COPY config.yaml.template /app/config.yaml.template
COPY docker-entrypoint.sh /docker-entrypoint.sh
RUN chmod +x /docker-entrypoint.sh \
    && caddy fmt --overwrite /srv/Caddyfile

# 暴露端口
EXPOSE 7890 7891 7892 7893 7894 9090 8080

# 健康检查
HEALTHCHECK --interval=30s --timeout=10s --start-period=5s --retries=3 \
    CMD curl -f http://localhost:8080/ || exit 1

# 使用自定义入口点脚本
ENTRYPOINT ["/docker-entrypoint.sh"]
