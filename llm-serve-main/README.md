# EKS GPU LLM Serving 실습

EKS GPU 환경에서 vLLM, TensorRT-LLM, Triton, Stable Diffusion을 서빙하는 실습 레포지토리입니다.

## 아키텍처 개요

```
Local PC
  │
  │ kubectl port-forward 또는 LoadBalancer
  ▼
Kubernetes Service (llm-serve namespace)
  │
  ├── Option A: vLLM          → /v1/chat/completions (OpenAI 호환)
  ├── Option B: TensorRT-LLM  → /v1/chat/completions (OpenAI 호환)
  ├── Option C: Triton        → /v2/* (KServe V2 프로토콜)
  ├── Option D: Stable Diffusion → /sdapi/v1/txt2img
  └── Option E: KServe        → InferenceService CRD로 A/C를 추상화
        ├── kserve-vllm-gpu2 ServingRuntime → vLLM TP=2
        └── kserve-tritonserver (내장)      → Triton
  │
  ▼
EKS GPU Node: g5.12xlarge
  - NVIDIA A10G × 4 (24GB × 4 = 96GB VRAM)
  - NVIDIA Device Plugin
```

| 옵션 | 프레임워크 | 모델 | GPU 병렬 전략 | 용도 |
|---|---|---|---|---|
| A | vLLM | Qwen2.5-7B-Instruct | Tensor Parallel (TP=2) | LLM 빠른 PoC |
| B | TensorRT-LLM | Qwen2.5-7B-Instruct | Tensor Parallel (tp_size=2) | LLM 성능 최적화 |
| C | Triton + TRT-LLM | 커스텀 엔진 | TRT-LLM backend TP=2 | 엔터프라이즈 serving |
| D | Stable Diffusion (A1111) | SDXL 1.0 | Replica (GPU 1개/Pod) | 이미지 생성 |
| E | KServe (vLLM / Triton) | Qwen2.5-7B-Instruct | InferenceService 추상화 | 표준화된 model lifecycle |

---

## 사전 요구사항

### 필수 툴

```bash
aws --version        # AWS CLI v2
kubectl version      # 1.28+
eksctl version       # 0.180+
helm version         # 3.x
jq --version
```

### AWS 인증 (MFA)

```bash
# MFA 세션 발급 (12시간 유효)
source .aws/get-ssm.sh <MFA_CODE>

# 기존 세션 재사용
source .aws/.session-env

# 세션 확인
aws sts get-caller-identity
```

### 환경 변수

```bash
export CLUSTER_NAME=ai-serving-gpu2-eks
export AWS_REGION=ap-northeast-2
```

---

## 실습 순서

### Step 0 — 사전 확인

```bash
./scripts/00-check-prereqs.sh
```

### Step 1 — EKS 클러스터 생성 (~20분)

```bash
./scripts/01-create-cluster.sh
```

- `eks/cluster/cluster.yaml` 기반
- OIDC 활성화 (IRSA 지원)
- 리전: ap-northeast-2

### Step 2 — GPU NodeGroup 생성 (~10분)

```bash
./scripts/02-create-nodegroup.sh
```

- 인스턴스: **g5.12xlarge** (A10G × 4, 96GB VRAM)
- 비용: ~$16/hr on-demand. 실습 후 즉시 삭제 권장.
- `eks/nodegroup/gpu-nodegroup.yaml` 기반

```bash
# 노드 확인
kubectl get nodes -L accelerator,gpu-node
```

### Step 3 — NVIDIA Device Plugin + EBS CSI Driver 설치

```bash
./scripts/03-install-addons.sh
```

- **EBS CSI Driver** 설치 (`aws-ebs-csi-driver` addon) — EKS 1.22+ 에서 PVC 프로비저닝에 필수
- **gp3 StorageClass** 생성 및 기본 StorageClass로 설정 (EBS CSI provisioner: `ebs.csi.aws.com`)
- **NVIDIA Device Plugin** Helm 설치, GPU Feature Discovery(gfd) 활성화
- 설치 후 `nvidia.com/gpu` 리소스가 노드에 노출됨

> EKS 1.22부터 in-tree AWS EBS provisioner(`kubernetes.io/aws-ebs`)가 제거됐습니다.
> `gp3` StorageClass는 EBS CSI Driver 설치 후에만 사용 가능합니다.

```bash
# 검증: GPU 4개 표시 여부 확인
kubectl describe node -l gpu-node=true | grep -A8 "Capacity:"

# StorageClass 확인
kubectl get storageclass
```

### Step 4 — 공통 리소스 설정

```bash
./scripts/04-setup-common.sh
```

- `llm-serve` namespace 생성
- HuggingFace token secret 생성 (Qwen2.5-7B는 불필요, 구조 확보용)

```bash
# Gated 모델(Llama 등) 사용 시
export HF_TOKEN=hf_xxxxxxxxxx
./scripts/04-setup-common.sh
```

### Step 5 — GPU 테스트

```bash
./scripts/05-gpu-test.sh
```

nvidia-smi 출력으로 A10G 4개 인식 여부를 확인합니다.

### Step 6 — KServe 설치 (Option E 사용 시)

```bash
./scripts/06-install-kserve.sh
```

- cert-manager + KServe v0.13 설치
- RawDeployment 모드 설정 (Knative 불필요)
- `llm-serve` 네임스페이스 KServe 활성화

---

## 서빙 옵션

### Option A: vLLM

가장 빠르게 PoC할 수 있는 선택. OpenAI 호환 API를 즉시 제공합니다.

```bash
./scripts/10-deploy-vllm.sh apply    # 배포 (5~15분)
./scripts/10-deploy-vllm.sh status   # 상태 + GPU 확인
./scripts/10-deploy-vllm.sh logs     # 로그 (TP 초기화 확인)
./scripts/10-deploy-vllm.sh delete   # 삭제
```

**GPU 2개 Tensor Parallel** 설정 (`k8s/vllm/deployment.yaml`):
```yaml
args:
  - --tensor-parallel-size
  - "2"
resources:
  limits:
    nvidia.com/gpu: 2
```

### Option B: TensorRT-LLM

latency/throughput 최적화가 필요할 때. 첫 실행 시 TRT 엔진 빌드로 시간이 걸립니다.

```bash
# NGC 로그인 필요 (nvcr.io) — ngc-secret은 클러스터 etcd에 llm-serve 네임스페이스 범위로 저장됨
# 클러스터 삭제 시 함께 삭제되므로 재생성 필요
kubectl create secret docker-registry ngc-secret \
  --docker-server=nvcr.io \
  --docker-username='$oauthtoken' \
  --docker-password=<NGC_API_KEY> \
  -n llm-serve

./scripts/20-deploy-trtllm.sh apply   # 배포 (10~30분, TRT 빌드 포함)
./scripts/20-deploy-trtllm.sh status
./scripts/20-deploy-trtllm.sh delete
```

**NGC 이미지 버전 주의사항:**
- 사용 이미지: `nvcr.io/nvidia/tensorrt-llm/release:0.20.0`
- 태그 `0.17.0`~`0.19.0`은 NGC에 존재하지 않음. 사용 가능: `0.20.0`, `1.0.0`, `1.1.0`, `1.2.0`

**배포 시간 관련:**
- 이미지 크기 ~30GB + TRT 엔진 빌드로 첫 배포에 20~30분 소요
- `progressDeadlineSeconds: 1800` (30분)으로 설정 — 기본값(600s)으로는 deadline exceeded 발생

### Option C: Triton + TensorRT-LLM

다중 모델 운영, 표준 serving platform이 필요할 때.

```bash
./scripts/30-deploy-triton.sh apply
./scripts/30-deploy-triton.sh status
./scripts/30-deploy-triton.sh delete
```

**이미지 선택:**

| 이미지 | TRT-LLM backend | 용도 |
|--------|----------------|------|
| `tritonserver:24.12-py3` (현재) | 없음 | ONNX / PyTorch / Python 모델 서빙 |
| `tritonserver:24.12-trtllm-python-py3` | 포함 | TRT-LLM 엔진으로 LLM 서빙 시 사용 |

> TRT-LLM 엔진을 Triton으로 서빙하려면 `deployment.yaml`의 이미지를 `24.12-trtllm-python-py3`로 변경하세요.

**`--model-control-mode=explicit`** 설정으로 빈 model-repository 상태로도 기동 가능.
모델은 아래 API로 명시적 로드합니다:

```bash
curl -X POST http://localhost:8000/v2/repository/models/<model_name>/load
```

model-repository 구조:
```
/models/
  llama_trtllm/
    1/
      rank0.engine
      rank1.engine
    config.pbtxt
```

Triton API (KServe V2 프로토콜):
```bash
curl http://localhost:8000/v2/health/ready
curl http://localhost:8000/v2/models
```

### Option D: Stable Diffusion (AUTOMATIC1111)

텍스트 → 이미지 생성. xFormers + FP16이 기본 활성화됩니다.

```bash
./scripts/35-deploy-sd.sh apply     # 배포 (모델 다운 포함 5~10분)
./scripts/35-deploy-sd.sh status
./scripts/35-deploy-sd.sh scale 2   # GPU 2개 동시 활용 (replica 확장)
./scripts/35-deploy-sd.sh delete
```

**ai-dock 이미지 주의사항:**
- 컨테이너 내부 API 포트: **17860** (ai-dock 기본값). Service는 `7860 → 17860`으로 매핑
- ai-dock 이미지가 `--no-half`를 기본 추가하므로, `--no-half-vae`와 함께 사용 시 충돌 발생
  - `AssertionError: --no-half and --no-half-vae conflict with --precision half`
  - 해결: `WEBUI_FLAGS`에서 `--no-half-vae` 제거
- EBS PVC는 root 소유로 마운트됨 → initContainer(`busybox`)로 `/models` 디렉토리 권한 수정 필요

### Option E: KServe

raw Deployment/Service 대신 **InferenceService CRD** 한 장으로 모델 lifecycle을 관리합니다.
storage initializer가 HuggingFace / PVC에서 모델을 `/mnt/models`로 내려받고, ServingRuntime이 서빙합니다.

> 사전 조건: Step 6 (`06-install-kserve.sh`) 완료 후 실행

```bash
./scripts/60-deploy-kserve-vllm.sh apply    # ServingRuntime + InferenceService 배포
./scripts/60-deploy-kserve-vllm.sh status   # ISVC 상태 + GPU 확인
./scripts/60-deploy-kserve-vllm.sh logs     # storage-initializer / vLLM 로그
./scripts/60-deploy-kserve-vllm.sh delete   # 삭제
```

**raw Deployment(Option A)와 KServe(Option E) 비교:**

| 항목 | Option A (raw) | Option E (KServe) |
|---|---|---|
| 리소스 | Deployment + Service | InferenceService (CRD) |
| 모델 다운로드 | vLLM 컨테이너가 HF에서 직접 | storage initializer → `/mnt/models` |
| 트래픽 분산 | 수동 | canary / traffic split 내장 |
| 오토스케일 | HPA 직접 구성 | Knative 또는 KEDA 연동 가능 |
| 프로토콜 | OpenAI API | V2 Inference Protocol + OpenAI API |

**KServe 핵심 파일:**

```
k8s/kserve/
  cluster-serving-runtime-vllm.yaml   # vLLM TP=2 커스텀 ServingRuntime
  vllm-inferenceservice.yaml          # hf://Qwen/Qwen2.5-7B-Instruct 로드
  triton-inferenceservice.yaml        # pvc:// 기존 model-repository 재사용
```

**API 테스트 (vLLM InferenceService):**

```bash
# port-forward — KServe가 생성한 Service 이름은 ISVC 이름과 동일
kubectl port-forward svc/vllm-qwen -n llm-serve 8080:80

curl http://localhost:8080/v1/chat/completions \
  -H "Content-Type: application/json" \
  -d '{
    "model": "Qwen/Qwen2.5-7B-Instruct",
    "messages": [{"role": "user", "content": "KServe로 서빙 중이야?"}],
    "max_tokens": 128
  }' | jq '.choices[0].message.content'
```

---

## 로컬 테스트

별도 터미널에서 port-forward를 실행 후 API를 테스트합니다.

```bash
# 터미널 1: port-forward
./scripts/40-port-forward.sh vllm    # localhost:8000
./scripts/40-port-forward.sh trtllm  # localhost:8000
./scripts/40-port-forward.sh triton  # localhost:8000/8001/8002
./scripts/40-port-forward.sh sd      # localhost:7860

# 터미널 2: API 테스트
./scripts/50-test-api.sh vllm
./scripts/50-test-api.sh sd
```

### vLLM / TRT-LLM 직접 호출 예시

```bash
# 모델 목록
curl http://localhost:8000/v1/models | jq

# Chat Completions
curl http://localhost:8000/v1/chat/completions \
  -H "Content-Type: application/json" \
  -d '{
    "model": "Qwen/Qwen2.5-7B-Instruct",
    "messages": [{"role": "user", "content": "안녕하세요!"}],
    "max_tokens": 256
  }' | jq '.choices[0].message.content'

# GPU 2개 사용 확인
kubectl exec -n llm-serve \
  $(kubectl get pod -n llm-serve -l app=vllm -o jsonpath='{.items[0].metadata.name}') \
  -- nvidia-smi
```

### Stable Diffusion 직접 호출 예시

```bash
# 이미지 생성 (DPM++ 2M Karras, 20 steps)
curl -X POST http://localhost:7860/sdapi/v1/txt2img \
  -H "Content-Type: application/json" \
  -d '{
    "prompt": "a futuristic GPU server in space, cinematic",
    "negative_prompt": "blurry, low quality",
    "steps": 20,
    "sampler_name": "DPM++ 2M Karras",
    "width": 1024,
    "height": 1024,
    "cfg_scale": 7,
    "seed": 42
  }' | jq -r '.images[0]' | base64 -d > output.png

open output.png  # macOS
```

---

## 이미지 생성 모델 최적화 요약

상세 내용: [`docs/sd-optimization.md`](docs/sd-optimization.md)

| 카테고리 | 기법 | 효과 |
|---|---|---|
| 실행 플래그 | xFormers, Flash Attention | 10~40% 속도 향상 |
| 스텝 최적화 | DPM++ 2M Karras (20 steps) | 2.5x 향상 |
| 스텝 최적화 | LCM-LoRA (4~8 steps) | 8~12x 향상 |
| 스텝 최적화 | SDXL-Lightning (4 steps) | 12x 향상 |
| 캐싱 | DeepCache | 2~2.5x 추가 향상 |
| 캐싱 | Token Merging (ToMe) | 20~60% 추가 향상 |
| Multi-GPU | Replica 2개 (GPU 1개/Pod) | Throughput 2x |
| TensorRT | UNet/VAE 엔진 변환 | 2~4x 향상 |

---

## 정리 (비용 절감)

```bash
./scripts/99-teardown.sh k8s        # K8s 리소스만 삭제
./scripts/99-teardown.sh nodegroup  # GPU NodeGroup 삭제 (비용 차단)
./scripts/99-teardown.sh cluster    # EKS 클러스터 삭제
./scripts/99-teardown.sh all        # 전체 삭제 (확인 프롬프트 있음)
```

> g5.12xlarge는 ~$16/hr입니다. 실습 후 반드시 nodegroup 또는 cluster를 삭제하세요.

---

## 디렉토리 구조

```
llm-serve/
├── .aws/
│   ├── get-ssm.sh              # MFA 세션 발급 스크립트
│   └── credentials             # Base AWS 키 (gitignored)
├── eks/
│   ├── cluster/cluster.yaml    # eksctl ClusterConfig
│   └── nodegroup/
│       └── gpu-nodegroup.yaml  # GPU ManagedNodeGroup (g5.12xlarge)
├── helm/
│   └── nvidia-device-plugin-values.yaml
├── k8s/
│   ├── common/
│   │   ├── namespace.yaml
│   │   └── gpu-test.yaml
│   ├── vllm/                   # Option A
│   ├── trtllm/                 # Option B
│   ├── triton/                 # Option C (PVC 포함)
│   ├── stable-diffusion/      # Option D (PVC 포함)
│   └── kserve/                 # Option E
│       ├── cluster-serving-runtime-vllm.yaml  # vLLM TP=2 ServingRuntime
│       ├── vllm-inferenceservice.yaml         # hf:// 스토리지 초기화
│       └── triton-inferenceservice.yaml       # pvc:// 기존 PVC 재사용
├── scripts/
│   ├── 00-check-prereqs.sh
│   ├── 01~05-*.sh              # 인프라 구성
│   ├── 06-install-kserve.sh   # KServe 설치 (Option E 전제)
│   ├── 10~35-deploy-*.sh       # 서빙 옵션 배포
│   ├── 40-port-forward.sh
│   ├── 50-test-api.sh
│   ├── 60-deploy-kserve-vllm.sh  # KServe vLLM 배포 관리
│   └── 99-teardown.sh
└── docs/
    └── sd-optimization.md      # 이미지 생성 최적화 상세 가이드
```

---

## 주의사항

- **`.aws/.session-env`, `.aws/credentials`는 gitignore 처리됨** — 절대 커밋하지 마세요.
- **TensorRT-LLM, Triton 이미지**는 `nvcr.io` NGC 로그인이 필요합니다.
- **vLLM-Omni `--omni` 플래그**는 존재하지 않습니다. 이미지 생성은 Option D (Stable Diffusion)를 사용하세요.
- **HF 캐시는 emptyDir** (Pod 재시작 시 재다운로드). 반복 실습 시 PVC/EFS 전환을 권장합니다.
