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

## 스크립트 — `setup_tailscale.sh`

이 repo는 스크립트 **하나**만 쓴다: **`setup_tailscale.sh`** (Tailscale 등록 전용).

현재 vast.ai vLLM 템플릿은 vLLM을 `/opt/supervisor-scripts/vllm.sh` + `/etc/vllm-args.conf` 로 띄우고
`/metrics` 를 **기본 노출**하므로, 이 repo가 할 일은 **GPU 박스를 tailnet에 고정 호스트명으로 붙이는 것**뿐.
vLLM 인자·모델은 vast.ai Environment(`VLLM_MODEL`/`VLLM_ARGS`) + `/etc/vllm-args.conf` 가 결정한다
(→ [vLLM 실행 인자](#vllm-실행-인자--실제-설정-소스-2026-07-검증)).

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
   HF_TOKEN=hf_xxxxxxxx          # HF 다운로드 인증 (rate limit 해제·가속). 미설정 시 로그에 unauthenticated 경고
   VLLM_MODEL=cyankiwi/Qwen3.5-9B-AWQ-4bit   # 채택 모델(AWQ int4, 이슈 #37) — 템플릿 기본값(bf16) 오버라이드
   ```
   > **모델은 AWQ int4 채택** (4EVR0-Server#37, 2026-07-07): bf16 대비 decode **2.4×**·동시 처리량 **2.25×**,
   > judge 품질 게이트 통과. 가중치 17.7GB→**5.3GB**라 콜드스타트 다운로드도 1/3.
   > Mac `.env` 의 `GPU_MODEL` 도 같은 값으로 맞출 것.
   > **접속**: 템플릿 기본 `VLLM_ARGS` 는 `--host 127.0.0.1`(localhost 전용)이라 `:18000` 외부 접근 불가.
   > 아래 On-start 가 `/etc/vllm-args.conf` 에 `--host 0.0.0.0` 을 덧붙여 오버라이드한다.
   > **콜드스타트를 줄이려면 인스턴스 생성 시 `/workspace` 에 영구 볼륨을 마운트**할 것 (아래 [콜드스타트 줄이기](#콜드스타트-줄이기--영구-볼륨)).

3. **On-start Script** — 기존 줄 유지 + Tailscale 추가 (`entrypoint.sh` 는 반드시 마지막):
   ```bash
   # vLLM 추가 인자 — vllm.sh 가 VLLM_ARGS 뒤에 append 함 (argparse 마지막 값 우선)
   #   --host 0.0.0.0          : Tailscale에서 :18000 접근 가능 (템플릿 기본 127.0.0.1 오버라이드)
   #   --enable-prefix-caching : 공유 시스템 프롬프트 prefill 재사용
   echo "--host 0.0.0.0 --enable-prefix-caching --compilation-config '{\"cudagraph_capture_sizes\": [1,2,3,4,5,6,7,8]}'" > /etc/vllm-args.conf;

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

### 콜드스타트 줄이기 — 영구 볼륨
> 측정 근거: `4EVR0-Server/review/2026-07-04-coldstart-measurement-summary.md`, `2026-07-04-coldstart-improvement-plan.md`

**신규 카드 콜드스타트 ~6분의 대부분은 "매 destroy마다 날아가는 것을 다시 만드는" 비용이다:**
- 가중치 다운로드 **~150–216s**(`/workspace/models`), torch.compile **~39–49s** + 첫 요청 컴파일 꼬리 **~3–4s**.
- 원인: **`/workspace` 가 컨테이너 overlay 디스크**(별도 볼륨 아님) → **destroy 시 전부 소멸**.

**핵심 — `/workspace` 에 vast.ai 영구 볼륨 마운트.** 모델·HF캐시·compile캐시가 **전부 `/workspace` 하위**라
**볼륨 1개로 전부 영속화**된다:

| 경로 | 무엇 (env) | 영속화 효과 |
|---|---|---|
| `/workspace/models` | 가중치 (`--download-dir`) | 다운로드 ~216s 제거 |
| `/workspace/.vllm_cache` | torch.compile 캐시 (`VLLM_CACHE_ROOT`) | compile ~39s + **첫 요청 꼬리 소멸** |
| `/workspace/.hf_home` | HF 캐시 (`HF_HOME`) | 재다운로드 방지 보조 |

→ **적용 시 콜드스타트 ~6분 → ~90초**(로드 4s + cudagraph/KV ~87s만 남음) **+ 첫 요청 꼬리 0** 기대.
compile 캐시는 **GPU 아키텍처·vLLM 버전 종속** → **같은 스펙 재대여** 시 최대 효과.

**보조 수단:**
- **`HF_TOKEN`** (Environment): 미설정 시 unauthenticated rate limit로 다운로드가 느리다(로그 경고). 캐시 미스 시 가속.
- **AWQ 채택 효과** (#37): 가중치 17.7GB→**5.3GB** → 다운로드·로드·볼륨 요구량 모두 ~1/3.
- **대안**: 모델·캐시를 구운 **커스텀 Docker 이미지** — 재현성·이식성 우위, 볼륨 비용 없음.

**디스크 크기 주의**: 기본 24GB는 모델 1개 전용으로 빠듯하다 — bf16(18G)+AWQ(5.3G) 동시 보관 불가로
`No space left on device` 크래시를 실제로 겪음(#37 Q1). **모델 A/B(양자화 비교 등)를 할 거면 32GB+ 로 대여할 것.**

### vLLM 실행 인자 — 실제 설정 소스 (2026-07 검증)
템플릿의 `/opt/supervisor-scripts/vllm.sh` 가 아래 형태로 띄운다:
```
vllm serve $VLLM_MODEL $VLLM_ARGS $AUTO_PARALLEL_ARGS $(cat /etc/vllm-args.conf)
```
즉 **설정 소스는 3곳**(박스에서 확인한 현재 값):

| 소스 | 위치 | 현재 값 |
|---|---|---|
| `VLLM_MODEL` | vast.ai Environment | `cyankiwi/Qwen3.5-9B-AWQ-4bit` (**AWQ 채택**, #37 — 이전 bf16 `Qwen/Qwen3.5-9B`) |
| `VLLM_ARGS` | vast.ai Environment | `--max-num-seqs 8 --max-model-len 32000 --enable-auto-tool-choice --tool-call-parser qwen3_coder --reasoning-parser qwen3 --download-dir /workspace/models --host 127.0.0.1 --port 18000` |
| `AUTO_PARALLEL_ARGS` | vllm.sh 자동 | `--tensor-parallel-size 1` (GPU_COUNT) |
| `/etc/vllm-args.conf` | onstart 이 씀 (마지막 append) | `--compilation-config '{"cudagraph_capture_sizes":[1..8]}'` |

관련 캐시 경로 env: `VLLM_CACHE_ROOT=/workspace/.vllm_cache`, `HF_HOME=/workspace/.hf_home`
(둘 다 `/workspace` 하위 → [영구 볼륨](#콜드스타트-줄이기--영구-볼륨) 대상).

> ⚠️ **`--host 127.0.0.1` 문제**: 템플릿 기본값이라 vLLM이 **localhost 전용 바인딩** → Tailscale로
> `:18000` 직결 불가(`GPU_SERVER_URL` 안 붙음). onstart의 `--host 0.0.0.0` 로 오버라이드해야 함.
> ⚠️ **인라인 sed로 인자 수정 금지**: 현재 템플릿은 `VLLM_ARGS` 를 **환경변수**로 받으므로 `supervisor
> vllm.conf` 의 `VLLM_ARGS=` 를 sed로 고치는 (구버전) 방식은 헛돈다(무효). 인자는 **Environment** 또는
> **`/etc/vllm-args.conf`**(위 onstart) 로만 바꾼다.
> ⚠️ **실행 중 인스턴스의 모델 교체 = `/etc/environment` 수정** (2026-07-07 #37 Q1에서 확인):
> vast Environment 값은 컨테이너의 `/etc/environment` 에 저장되고, `vllm.sh` 가 기동 때마다 이를 재소싱한다.
> 따라서 supervisor `environment=` 오버라이드는 **덮여서 무효** — `/etc/environment` 의 `VLLM_MODEL` 을
> sed 로 바꾸고 vLLM 을 재기동해야 한다. (재기동 시 `pkill -9 -f "EngineCor[e]"` 로 GPU 회수 확인 필수)

서빙 모델은 `VLLM_MODEL` 이 결정(**현재 `cyankiwi/Qwen3.5-9B-AWQ-4bit`** — AWQ int4 채택, #37).
Mac `.env` 의 `GPU_MODEL` 이 이와 **일치**해야 한다(불일치 시 404 → 추천이 규칙기반으로 폴백).

### Prefix caching 확인

현재 템플릿에서는 `/etc/vllm-args.conf`에 `--enable-prefix-caching`을 명시한다.
기존 인스턴스는 해당 파일에서 `--no-enable-prefix-caching`을 제거하고
`--enable-prefix-caching`을 추가한 뒤 vLLM을 재시작해야 한다.

```bash
# GPU 서버에서 설정/기동 로그 확인
cat /etc/vllm-args.conf
supervisorctl restart vllm
tail -f /var/log/portal/vllm.log  # "Application startup complete"까지 대기

# Mac에서 런타임 설정 확인: enable_prefix_caching="True"여야 함
curl -s http://vast-gpu-server-2.tailb70036.ts.net:18000/metrics \
  | grep 'vllm:cache_config_info'

# 동일한 prefix를 쓰는 요청을 2회 이상 보낸 뒤 token 단위 query/hit 확인
curl -s http://vast-gpu-server-2.tailb70036.ts.net:18000/metrics \
  | grep -E 'vllm:prefix_cache_(queries|hits)_total\{' \
  | grep -v created
```

---

## 확인 (Mac에서)
```bash
# tailnet에 떴나
tailscale status | grep vast-gpu-server-2

# vLLM이 어떤 모델을 서빙 중인가
curl -s http://vast-gpu-server-2.tailb70036.ts.net:18000/v1/models
```
