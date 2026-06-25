# GPU_Serving_Infra

4EVR0 추천 시스템의 **LLM 추론 서버(vLLM) 프로비저닝** 인프라.
Vast.ai GPU 인스턴스를 빌린 뒤, 앱(Mac)이 항상 같은 주소로 접속할 수 있는
vLLM 서버로 만들어주는 설정 스크립트와 가이드.

> 백엔드 앱 코드는 여기 없음 — 그건 [`4EVR0-Server`](https://github.com/4EVR0/4EVR0-Server)(Mac에서 실행).
> 이 repo는 **GPU 박스를 tailnet에 붙이는 일**만 담당한다. (vLLM `/metrics` 는 현재 템플릿에서 기본 노출됨)

---

## 역할 (시스템에서의 위치)

```
[Mac] 백엔드 앱(4EVR0-Server) ──Tailscale──▶ [GPU] vLLM 추론  ← 이 repo가 세팅하는 대상
                              ──Tailscale──▶ [EC2] Neo4j
```

GPU 인스턴스가 하는 일은 **vLLM으로 모델을 서빙하는 것**뿐. 추천 파이프라인 조율은 Mac 백엔드가 한다.

## 스크립트 선택 (vast.ai 템플릿에 따라)

| 스크립트 | 언제 | 하는 일 |
|----------|------|---------|
| **`setup_tailscale.sh`** ⭐ | **현재 vast.ai vLLM 템플릿** (vLLM을 `/opt/supervisor-scripts/vllm.sh` + `/etc/vllm-args.conf` 로 띄움) | Tailscale 등록만. vLLM `/metrics` 는 **기본 노출**이라 메트릭 설정 불필요. |
| `setup_gpu.sh` (레거시) | 구버전 템플릿 (supervisor `vllm.conf` 에 `VLLM_ARGS=` 인라인) | vLLM `--enable-metrics` + Caddy `/metrics` + Tailscale. **현재 템플릿엔 비호환** (vllm.conf에 VLLM_ARGS 없음 → sed가 헛돔). |

> 2026-06 검증: 현재 템플릿은 `vllm serve ... $(cat /etc/vllm-args.conf)` 로 띄우고
> `/metrics` 에 `vllm:...` 가 **기본 노출**됨 → **`setup_tailscale.sh`** 만 쓰면 됨.

## 의존성 / 전제
- **Vast.ai vLLM 템플릿** — `vllm` / `supervisor` 미리 설치. 모델 서빙은 템플릿이 담당.
- **Tailscale 인증 키** — Reusable + Ephemeral 권장 (`.env.example` 참고).
- Python 의존성 없음(순수 셸 + 시스템 도구). tailscale은 없으면 스크립트가 설치.

## `setup_tailscale.sh` 가 하는 일
1. tailscale 설치 (없으면)
2. `tailscaled` 를 supervisor 로 상시 실행 등록
3. **`tailscale up --hostname=<고정이름>`** → tailnet 에 고정 주소로 가입

핵심은 [3] — Vast.ai는 인스턴스마다 공인 IP가 바뀌지만, **고정 호스트명**으로 등록하면
MagicDNS 주소(`vast-gpu-server-2.tailb70036.ts.net`)가 항상 같아서 **Mac의 `.env`를 안 고쳐도 된다.**

---

## 사용법 ① 수동 (새 인스턴스 빌릴 때)

```bash
# 1. Vast.ai vLLM 인스턴스 생성 후 SSH 접속
ssh -p <포트> root@<IP>

# 2. 스크립트만 가져와 실행 (전체 repo clone 불필요)
#    <TAILSCALE_AUTH_KEY> 는 꺾쇠 빼고 실제 키(tskey-auth-...)로 교체
curl -fsSL https://raw.githubusercontent.com/4EVR0/GPU_Serving_Infra/main/setup_tailscale.sh \
  | bash -s tskey-auth-xxxx vast-gpu-server-2

# 3. vLLM 로딩 확인 (모델 최초 다운로드 시 수 분)
tail -f /var/log/portal/vllm.log    # "Application startup complete" 뜨면 완료
```

완료되면 스크립트가 `GPU_SERVER_URL=http://vast-gpu-server-2.tailb70036.ts.net:18000` 을 안내한다.
같은 호스트명으로 등록했다면 Mac `.env` 수정 불필요.

## 사용법 ② 자동 (Vast.ai onstart) — 권장

새 인스턴스를 빌릴 때마다 SSH로 수동 실행하는 대신, **인스턴스 부팅 시 자동 실행**되게 한다.
`setup_tailscale.sh` 는 인자가 없으면 **환경변수**(`TAILSCALE_AUTH_KEY`, `TAILSCALE_HOSTNAME`)를 읽는다.

> ⚠️ **기존 onstart를 통째로 지우지 말 것.** 마지막 `entrypoint.sh` 가 vLLM을 띄우는 줄이라
> 지우면 서빙이 안 된다. 템플릿 기본 줄은 **유지**하고 Tailscale 등록만 **추가**한다.

### 설정 (Vast.ai 인스턴스 생성 화면)

1. **Tailscale 키 발급** — [admin/settings/keys](https://login.tailscale.com/admin/settings/keys) →
   **Reusable + Ephemeral** 체크 (`tskey-auth-...`).

2. **환경변수(Environment)** 에 추가:
   ```
   TAILSCALE_AUTH_KEY=tskey-auth-xxxxxxxx
   TAILSCALE_HOSTNAME=vast-gpu-server-2
   ```

3. **On-start Script** — 기존 줄 유지 + Tailscale 추가 (`entrypoint.sh` 는 반드시 마지막):
   ```bash
   # (템플릿 기본) vLLM 인자
   echo "--compilation-config '{\"cudagraph_capture_sizes\": [1,2,3,4,5,6,7,8]}'" > /etc/vllm-args.conf;

   # Tailscale 등록 (백그라운드 — entrypoint를 막지 않게)
   bash <(curl -fsSL https://raw.githubusercontent.com/4EVR0/GPU_Serving_Infra/main/setup_tailscale.sh) &

   # (템플릿 기본) vLLM 시작 — 반드시 마지막, 절대 삭제 금지
   entrypoint.sh
   ```

4. **Template로 저장** → 다음부터 이 템플릿으로 빌리면 부팅과 동시에 Tailscale 자동 등록.
   (vLLM `/metrics` 는 기본 노출이라 별도 작업 불필요)

### 검증 (Mac에서)
```bash
tailscale status | grep vast-gpu-server-2                        # tailnet에 떴나
curl -s http://vast-gpu-server-2.tailb70036.ts.net:18000/v1/models   # vLLM 모델 응답하나
```

> ⚠️ onstart 환경변수에 키가 저장되니 **Reusable + Ephemeral** 키 + GPU 노드용 ACL/태그를 좁게.
> Ephemeral 키면 인스턴스 destroy 시 tailnet 노드도 자동 제거되어 호스트명 충돌도 안 난다.
> (vast.ai UI의 정확한 필드명/위치는 버전에 따라 다를 수 있음 — Environment / On-start 칸 확인)

---

## 운영 팁

### 호스트명 충돌 방지 (destroy → 재생성 워크플로)
인스턴스를 destroy하고 새로 빌리면, 이전 노드가 tailnet에 `vast-gpu-server-2`로 남아
새 노드가 `vast-gpu-server-2-1` 을 받아버린다(→ Mac이 못 찾음). 해결:
- **권장: Ephemeral auth key** — 노드가 오프라인 되면 tailnet에서 **자동 제거** → 이름이 비워져 충돌 없음.
- 수동: [admin/machines](https://login.tailscale.com/admin/machines) 에서 이전 노드 삭제.

### 콜드스타트(모델 재다운로드) 줄이기
destroy 시 디스크가 날아가 모델(~18GB)을 매번 다시 받는다. 줄이려면:
- **Vast.ai persistent storage(볼륨)** 에 `--download-dir`(`/workspace/models`)를 두기 → 재다운로드 스킵.
- 또는 모델을 구운 커스텀 이미지 사용.

### vLLM 실행 인자 (현재 기준)
```
--kv-cache-dtype turboquant_k8v4 --max-num-seqs 8 --enable-auto-tool-choice
--tool-call-parser hermes --download-dir /workspace/models
--host 0.0.0.0 --port 18000 --enable-metrics
```
서빙 모델은 vast.ai 템플릿/이미지가 결정한다(현재 `Qwen/Qwen3.5-9B`).
> Mac `.env`의 `GPU_MODEL` 이 **실제 서빙 모델과 일치**해야 한다(불일치 시 404 → 추천이 규칙기반으로 폴백).

---

## 확인 (Mac에서)
```bash
# tailnet에 떴나
tailscale status | grep vast-gpu-server-2

# vLLM이 어떤 모델을 서빙 중인가
curl -s http://vast-gpu-server-2.tailb70036.ts.net:18000/v1/models
```
