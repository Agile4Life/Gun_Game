# Saltline là một file HTML tĩnh duy nhất (Three.js + code game đã bundle),
# nên chỉ cần một web server tĩnh. Dùng nginx bản "unprivileged": chạy bằng user
# thường (không phải root) và lắng nghe cổng 8080 bên trong container.
FROM nginxinc/nginx-unprivileged:1.27-alpine

# Cấu hình nginx riêng (gzip, cache, header bảo mật)
COPY nginx.conf /etc/nginx/conf.d/default.conf

# Đổi tên thành index.html để truy cập thẳng bằng "/"
COPY saltline_1.html /usr/share/nginx/html/index.html

EXPOSE 8080

HEALTHCHECK --interval=30s --timeout=3s --start-period=5s --retries=3 \
  CMD wget -q --spider http://127.0.0.1:8080/healthz || exit 1
