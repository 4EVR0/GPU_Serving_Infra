#!/bin/bash
#
# Tailscale 등록 전용 (템플릿 무관) — 현재 vast.ai vLLM 템플릿용.
#
# 이 템플릿은 vLLM을 /opt/supervisor-scripts/vllm.sh + /etc/vllm-args.conf 로 띄우고,
# vLLM은 /metrics 를 기본 노출하므로 vLLM/Caddy 설정은 건드리지 않는다.
# (구버전 supervisor 'VLLM_ARGS=' 방식 템플릿은 setup_gpu.sh 참고 — 이 템플릿엔 비호환)
#
# 하는 일: tailscale 설치 + supervisor로 상시 실행 + 고정 호스트명으로 tailnet 가입.
#
# 수동:   ./setup_tailscale.sh <TAILSCALE_AUTH_KEY> [HOSTNAME]
# onstart: 환경변수 TAILSCALE_AUTH_KEY (+ TAILSCALE_HOSTNAME) 설정 후 인자 없이

set -e

TAILSCALE_AUTH_KEY="${1:-${TAILSCALE_AUTH_KEY:-}}"
TAILSCALE_HOSTNAME="${2:-${TAILSCALE_HOSTNAME:-vast-gpu-server-2}}"

if [ -z "$TAILSCALE_AUTH_KEY" ]; then
    echo "오류: Tailscale Auth Key 필요. (인자 또는 환경변수 TAILSCALE_AUTH_KEY)"
    echo "  키 발급: https://login.tailscale.com/admin/settings/keys (Reusable + Ephemeral)"
    exit 1
fi

echo "===== [1/3] Tailscale 설치 ====="
if command -v tailscale &>/dev/null; then
    echo "이미 설치됨, 스킵"
else
    curl -fsSL https://tailscale.com/install.sh | sh
fi

echo "===== [2/3] tailscaled supervisor 등록 (상시 실행) ====="
mkdir -p /var/run/tailscale /var/lib/tailscale
cat > /etc/supervisor/conf.d/tailscale.conf << 'EOF'
[program:tailscale]
command=tailscaled --tun=userspace-networking --state=/var/lib/tailscale/tailscaled.state --socket=/var/run/tailscale/tailscaled.sock
directory=/var/lib/tailscale
autostart=true
autorestart=true
stdout_logfile=/var/log/tailscaled.log
redirect_stderr=true
priority=10
EOF

pkill -f tailscaled 2>/dev/null || true
sleep 1
supervisorctl reread
supervisorctl update

echo "===== [3/3] tailnet 가입 (hostname=${TAILSCALE_HOSTNAME}) ====="
echo "tailscaled 대기 중..."
for i in $(seq 1 10); do
    tailscale status &>/dev/null 2>&1 && break
    sleep 2
done
tailscale up --auth-key="$TAILSCALE_AUTH_KEY" --hostname="$TAILSCALE_HOSTNAME"

TAILSCALE_IP=$(tailscale ip -4 2>/dev/null || echo "확인 필요")
echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "  Tailscale 등록 완료"
echo "  IP: ${TAILSCALE_IP}"
echo "  MagicDNS: ${TAILSCALE_HOSTNAME}.<tailnet>.ts.net"
echo ""
echo "  Mac .env (수정 불필요 — 같은 호스트명이면):"
echo "  GPU_SERVER_URL=http://${TAILSCALE_HOSTNAME}.tailb70036.ts.net:18000"
echo ""
echo "  메트릭 확인(모델 로딩 완료 후):"
echo "  curl http://${TAILSCALE_HOSTNAME}.tailb70036.ts.net:18000/metrics | head"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
