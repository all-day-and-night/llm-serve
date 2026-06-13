# Stable Diffusion 이미지 생성 모델 성능 최적화 가이드

EKS GPU (A10G × 4, g5.12xlarge) 환경 기준으로 정리합니다.

---

## 1. 추론 속도 최적화 — 실행 플래그

AUTOMATIC1111 `WEBUI_FLAGS` 환경변수 또는 실행 인자로 적용합니다.

| 기법 | 속도 향상 | VRAM 변화 | 플래그 |
|---|---|---|---|
| **xFormers** | 10~40% | 감소 | `--xformers` |
| **Flash Attention (SDPA)** | 10~30% | 감소 | `--opt-sdp-attention` |
| **torch.compile** | 10~30% | 유지 | `--opt-sdp-no-mem-attn` |
| **TensorRT UNet** | 2~4x | 약간 증가 | A1111 TRT 확장 필요 |

### TensorRT 변환 (고급)

UNet / VAE / CLIP Text Encoder를 `.engine` 파일로 변환합니다.
- 첫 빌드: 10~20분 소요
- 이후 실행: 2~4x 빠름
- NGC API Key 필요: `nvcr.io` 로그인
- A1111 확장: `sd-webui-tensorrt` (NVIDIA 공식)

PoC에서는 **xFormers + SDPA 조합**으로 충분합니다.

---

## 2. 스텝 수 최적화 — 가장 큰 효과

디노이징 스텝 수를 줄이는 것이 단일 최고 효과 최적화입니다.

| 기법 | 스텝 수 | 원본(DDIM 50) 대비 | 비고 |
|---|---|---|---|
| **DDIM** | 50 | 1x | 기준선 |
| **DPM++ 2M Karras** | 20 | **2.5x** | 품질 유지, 권장 |
| **DPM++ SDE Karras** | 15~20 | 2~3x | 고품질, 약간 느림 |
| **Euler a** | 20~30 | 1.5~2x | 창의적 결과 |
| **LCM-LoRA** | 4~8 | **8~12x** | LoRA 형태로 기존 모델에 적용 |
| **SDXL-Lightning** | 4 | **12x** | Apache 2.0, ByteDance |
| **SDXL-Turbo** | 1~4 | **12x** | Apache 2.0, 저해상도 강함 |
| **SD-Turbo** | 1~4 | **12x** | SD 1.5 base |

### LCM-LoRA 적용 방법 (A1111)

```
1. LoRA 탭에서 lcm-lora-sdxl 또는 lcm-lora-sdv1-5 선택
2. Sampler: LCM
3. Steps: 4~8
4. CFG Scale: 1~2 (낮게)
```

### PoC 권장 설정

- 모델: SDXL 1.0
- 스케줄러: DPM++ 2M Karras
- 스텝: 20
- CFG Scale: 7
- 해상도: 1024×1024

---

## 3. 메모리 최적화

A10G 24GB에서는 SDXL 기준으로 기본 설정으로도 OOM 없이 동작합니다.
저사양 GPU나 고해상도 생성 시 아래 옵션을 활성화합니다.

| 기법 | VRAM 절감 | 속도 영향 | A1111 적용 |
|---|---|---|---|
| **FP16** | 50% | 빠름 | `--precision half` (기본값) |
| **VAE Slicing** | OOM 방지 | 약간 느림 | Settings > VAE > Slicing |
| **VAE Tiling** | 2048+ 가능 | 느림 | `--opt-split-attention` |
| **Attention Slicing** | ~30% 절감 | 느림 | Settings > Optimizations |
| **Medvram** | 대폭 절감 | 느림 | `--medvram` (8GB GPU용) |
| **Lowvram** | 최소 VRAM | 매우 느림 | `--lowvram` (4GB GPU용) |
| **no-half-vae** | 없음 | 없음 | `--no-half-vae` (색상 깨짐 방지) |

---

## 4. 캐싱 기법 — A1111 확장

### DeepCache

중간 UNet 특징(feature)을 스텝 간에 재사용합니다.

- 속도 향상: **2~2.5x**
- 품질 영향: 미미 (ratio ≤ 0.5에서 육안 차이 거의 없음)
- 설치: A1111 Extensions 탭 → `sd-webui-deepcache` 검색
- 권장 설정: `cache_interval=3`, `cache_branch_id=0`, `ratio=0.5`

### Token Merging (ToMe)

Attention 레이어에서 유사한 토큰을 병합합니다.

- 속도 향상: **20~60%**
- 품질 영향: merge ratio 0.5 이하에서 경미한 세부묘사 손실
- 설치: `sd-webui-tome`
- 권장 설정: `ratio=0.3` (속도/품질 균형)

### 두 기법 조합

DeepCache + ToMe 동시 사용 시 이론상 최대 3~4x 향상.
과도한 값(ratio > 0.7)은 품질 저하 위험.

---

## 5. Multi-GPU 전략

SD 계열 모델은 **Tensor Parallelism을 지원하지 않습니다**.

### 권장: 독립 Replica (Data Parallelism)

```
GPU 0 → SD Pod 1 (replica 1)
GPU 1 → SD Pod 2 (replica 2)
```

- K8s에서 `nvidia.com/gpu: 1`, `replicas: 2`
- 동시 처리량 2x
- 각 Pod는 완전히 독립적으로 요청 처리

```yaml
# k8s/stable-diffusion/deployment.yaml
replicas: 2
resources:
  limits:
    nvidia.com/gpu: 1
```

**주의**: PVC가 ReadWriteOnce면 동일 노드 내 두 Pod만 마운트 가능.
다른 노드로 확장하려면 EFS(ReadWriteMany) PVC로 교체 필요.

### 비권장: 단일 Pod에 GPU 2개

```yaml
nvidia.com/gpu: 2  # GPU 2개를 한 Pod에 할당
```

SD는 1개 GPU만 사용하므로 나머지 GPU는 유휴 상태. 자원 낭비.

---

## 6. K8s 인프라 레벨 최적화

### PVC 모델 캐시

```yaml
# k8s/stable-diffusion/pvc.yaml 참조
# Pod 재시작 시 모델 재다운로드 방지
# SD 1.5: ~4GB / SDXL: ~7GB
```

### Warm-up Request

Pod 시작 후 JIT 컴파일을 미리 트리거합니다.

```yaml
lifecycle:
  postStart:
    exec:
      command: ["/bin/sh", "-c",
        "sleep 30 && curl -s -X POST http://localhost:7860/sdapi/v1/txt2img
         -d '{\"prompt\":\"warmup\",\"steps\":1,\"width\":64,\"height\":64}'"]
```

### readinessProbe 튜닝

모델 로딩에 2~5분 소요되므로 `initialDelaySeconds`를 충분히 설정합니다.

```yaml
readinessProbe:
  httpGet:
    path: /sdapi/v1/sd-models
    port: 7860
  initialDelaySeconds: 120
  periodSeconds: 15
  failureThreshold: 40
```

### HPA (Horizontal Pod Autoscaler)

DCGM Exporter로 GPU utilization을 Prometheus에 노출 후 HPA 연동합니다.

```bash
# DCGM Exporter 설치
helm repo add gpu-helm-charts https://nvidia.github.io/dcgm-exporter/helm-charts
helm install dcgm-exporter gpu-helm-charts/dcgm-exporter -n gpu-operator
```

---

## 7. 모델별 권장 최적화 조합

| 모델 | VRAM (FP16) | 권장 스텝/스케줄러 | 핵심 최적화 |
|---|---|---|---|
| SD 1.5 | ~6GB | DPM++ 2M 20steps | xFormers + DeepCache |
| SDXL 1.0 | ~12GB | DPM++ 2M 25steps | xFormers + VAE Slicing |
| SDXL-Lightning | ~10GB | 4 steps (Lightning) | xFormers |
| SDXL-Turbo | ~10GB | 1~4 steps | xFormers |
| FLUX.1-schnell | ~24GB | 4 steps | A1111 미지원, diffusers 사용 |

**A10G 24GB × 환경 최적 조합**:
- SDXL 1.0 + DPM++ 2M Karras 25 steps + xFormers + DeepCache(ratio=0.5)
- 예상 생성 시간: 1024×1024 기준 ~3~5초
