# EKS GPU 2장 기반 LLM / 이미지 생성 서빙 아키텍처 및 실행 계획

## 0. 목적

EKS 환경에서 GPU 2개를 사용하는 AI 모델 서빙 구성을 다음 3가지 우선순위로 정리한다.

1. vLLM / vLLM-Omni
   - 빠르게 띄우기 좋음
   - 설정 단순
   - OpenAI compatible API 바로 제공
   - 이미지 생성 모델은 vLLM-Omni 검토

2. TensorRT-LLM
   - 성능 최적화가 중요할 때
   - 엔진 빌드, 모델 변환, 운영 튜닝 감수 가능할 때
   - LLM 및 일부 Visual Gen 최적화 검토

3. Triton + TensorRT-LLM
   - 사내 표준 inference serving 플랫폼이 Triton일 때
   - 여러 모델, 여러 backend, autoscaling, model repository 구조가 필요할 때

공통 전제는 다음과 같다.

- EKS 클러스터 1개
- GPU 노드 1대
- 단일 Pod가 GPU 2개를 할당받음
- 로컬 PC에서 EKS LoadBalancer 또는 port-forward로 API 호출 테스트
- 최초 검증은 최소 자원으로 시작

---

## 1. 공통 아키텍처

```text
Local PC
  |
  | HTTP / OpenAI compatible API
  v
AWS LoadBalancer 또는 kubectl port-forward
  |
  v
Kubernetes Service
  |
  v
Inference Pod
  - vLLM / vLLM-Omni
  - TensorRT-LLM
  - Triton + TensorRT-LLM
  |
  v
EKS GPU Node
  - NVIDIA Driver
  - NVIDIA Device Plugin
  - nvidia.com/gpu: 2 이상
```

공통으로 중요한 Kubernetes 설정은 아래이다.

```yaml
resources:
  requests:
    nvidia.com/gpu: 2
  limits:
    nvidia.com/gpu: 2
```

이 설정은 Pod에 GPU 2개를 할당한다. 다만 이것만으로 모델이 GPU 2개에 자동 분산되지는 않는다. 프레임워크별 병렬 옵션을 추가해야 한다.

| 방식 | GPU 2개 할당 | 모델 2-GPU 사용 옵션 |
|---|---|---|
| vLLM | `nvidia.com/gpu: 2` | `--tensor-parallel-size 2` |
| vLLM-Omni | `nvidia.com/gpu: 2` | `--omni`, 모델별 병렬 옵션 검토 |
| TensorRT-LLM | `nvidia.com/gpu: 2` | `--tp_size 2` 또는 엔진 빌드 시 TP=2 |
| Triton 일반 | `nvidia.com/gpu: 2` | `instance_group`으로 복제 |
| Triton + TensorRT-LLM | `nvidia.com/gpu: 2` | TensorRT-LLM backend TP/world size 설정 |

---

## 2. 최소 EKS 자원 구성

### 2.1 권장 최소 구성

처음 PoC는 아래 정도로 시작한다.

```text
Region: ap-northeast-2
EKS: 1 cluster
GPU node group: 1 node
Instance: g5.12xlarge 또는 g5.4xlarge 이상
Pod GPU request: 2
Service exposure: LoadBalancer 또는 port-forward
```

주의:

- `g5.xlarge`는 GPU 1개라서 GPU 2개 Pod를 띄울 수 없다.
- GPU 2개가 필요한 Pod는 한 노드 안에서 GPU 2개를 확보해야 한다.
- 최소 비용을 더 낮추려면 GPU 2개 이상 제공 인스턴스 타입을 확인해서 선택한다.
- 이미지 생성 모델은 VRAM 요구량이 모델마다 다르므로 GPU 2개로 안 될 수 있다.

---

## 3. 로컬 CLI 준비

```bash
aws --version
kubectl version --client
eksctl version
helm version
```

```bash
export AWS_REGION=ap-northeast-2
export CLUSTER_NAME=ai-serving-gpu2-eks
```

```bash
aws sts get-caller-identity
```

---

## 4. EKS 클러스터 생성

기존 EKS가 있으면 이 단계는 생략한다.

```bash
eksctl create cluster \
  --name ${CLUSTER_NAME} \
  --region ${AWS_REGION} \
  --version 1.30 \
  --without-nodegroup
```

```bash
aws eks update-kubeconfig \
  --region ${AWS_REGION} \
  --name ${CLUSTER_NAME}
```

```bash
kubectl get nodes
```

---

## 5. GPU NodeGroup 생성

GPU 2개 Pod를 안정적으로 띄우기 위해 GPU가 2개 이상인 노드를 사용한다. 예시는 `g5.12xlarge`이다.

```bash
eksctl create nodegroup \
  --cluster ${CLUSTER_NAME} \
  --region ${AWS_REGION} \
  --name gpu-g5 \
  --node-type g5.12xlarge \
  --nodes 1 \
  --nodes-min 1 \
  --nodes-max 1 \
  --managed \
  --node-volume-size 300 \
  --node-labels accelerator=nvidia,gpu-node=true
```

확인:

```bash
kubectl get nodes -L accelerator,gpu-node
```

---

## 6. NVIDIA Device Plugin 설치

```bash
helm repo add nvdp https://nvidia.github.io/k8s-device-plugin
helm repo update
```

```bash
helm upgrade --install nvdp nvdp/nvidia-device-plugin \
  --namespace nvidia-device-plugin \
  --create-namespace \
  --set gfd.enabled=true
```

확인:

```bash
kubectl get pods -n nvidia-device-plugin
kubectl describe node -l gpu-node=true | grep -A8 "Capacity"
```

`nvidia.com/gpu`가 보여야 한다.

---

## 7. GPU 테스트 Pod

```bash
cat <<'YAML' > gpu-test.yaml
apiVersion: v1
kind: Pod
metadata:
  name: gpu-test
spec:
  restartPolicy: Never
  nodeSelector:
    gpu-node: "true"
  tolerations:
    - key: "nvidia.com/gpu"
      operator: "Exists"
      effect: "NoSchedule"
  containers:
    - name: cuda
      image: nvidia/cuda:12.4.1-base-ubuntu22.04
      command: ["nvidia-smi"]
      resources:
        limits:
          nvidia.com/gpu: 1
YAML
```

```bash
kubectl apply -f gpu-test.yaml
kubectl logs gpu-test
kubectl delete pod gpu-test
```

---

## 8. Hugging Face Token Secret

Gated model 또는 private model을 쓰는 경우 필요하다.

```bash
export HF_TOKEN=hf_xxxxxxxxxxxxxxxxx
```

```bash
kubectl create secret generic hf-token \
  --from-literal=HF_TOKEN=${HF_TOKEN}
```

---

# Option A. 1순위: vLLM / vLLM-Omni

## A-1. 선택 기준

vLLM은 가장 빠르게 PoC하기 좋은 선택이다.

- LLM text generation: vLLM
- 이미지 생성 모델: vLLM-Omni 검토
- OpenAI compatible API를 빠르게 제공해야 할 때 적합

## A-2. vLLM LLM 아키텍처

```text
Local PC
  -> LoadBalancer / port-forward
  -> Service vllm:8000
  -> vLLM Pod
      - nvidia.com/gpu: 2
      - --tensor-parallel-size 2
  -> GPU Node
```

## A-3. vLLM Deployment

```bash
cat <<'YAML' > vllm-deployment.yaml
apiVersion: apps/v1
kind: Deployment
metadata:
  name: vllm
  labels:
    app: vllm
spec:
  replicas: 1
  selector:
    matchLabels:
      app: vllm
  template:
    metadata:
      labels:
        app: vllm
    spec:
      nodeSelector:
        gpu-node: "true"
      tolerations:
        - key: "nvidia.com/gpu"
          operator: "Exists"
          effect: "NoSchedule"
      containers:
        - name: vllm
          image: vllm/vllm-openai:latest
          imagePullPolicy: IfNotPresent
          ports:
            - containerPort: 8000
          env:
            - name: HUGGING_FACE_HUB_TOKEN
              valueFrom:
                secretKeyRef:
                  name: hf-token
                  key: HF_TOKEN
            - name: HF_HOME
              value: /root/.cache/huggingface
          command:
            - vllm
            - serve
          args:
            - meta-llama/Llama-3.1-8B-Instruct
            - --host
            - 0.0.0.0
            - --port
            - "8000"
            - --tensor-parallel-size
            - "2"
            - --dtype
            - auto
            - --gpu-memory-utilization
            - "0.90"
            - --max-model-len
            - "8192"
          resources:
            requests:
              cpu: "8"
              memory: "32Gi"
              nvidia.com/gpu: 2
            limits:
              cpu: "16"
              memory: "64Gi"
              nvidia.com/gpu: 2
          volumeMounts:
            - name: shm
              mountPath: /dev/shm
            - name: hf-cache
              mountPath: /root/.cache/huggingface
          readinessProbe:
            httpGet:
              path: /health
              port: 8000
            initialDelaySeconds: 60
            periodSeconds: 10
            failureThreshold: 30
      volumes:
        - name: shm
          emptyDir:
            medium: Memory
            sizeLimit: 8Gi
        - name: hf-cache
          emptyDir:
            sizeLimit: 200Gi
YAML
```

```bash
kubectl apply -f vllm-deployment.yaml
```

## A-4. vLLM-Omni 이미지 생성 Deployment 예시

이미지 생성 모델은 vLLM-Omni의 `--omni` 경로를 검토한다.

```bash
cat <<'YAML' > vllm-omni-image-deployment.yaml
apiVersion: apps/v1
kind: Deployment
metadata:
  name: vllm-omni-image
  labels:
    app: vllm-omni-image
spec:
  replicas: 1
  selector:
    matchLabels:
      app: vllm-omni-image
  template:
    metadata:
      labels:
        app: vllm-omni-image
    spec:
      nodeSelector:
        gpu-node: "true"
      tolerations:
        - key: "nvidia.com/gpu"
          operator: "Exists"
          effect: "NoSchedule"
      containers:
        - name: vllm-omni
          image: vllm/vllm-openai:latest
          imagePullPolicy: IfNotPresent
          ports:
            - containerPort: 8000
          env:
            - name: HUGGING_FACE_HUB_TOKEN
              valueFrom:
                secretKeyRef:
                  name: hf-token
                  key: HF_TOKEN
          command:
            - vllm
            - serve
          args:
            - Qwen/Qwen-Image
            - --omni
            - --host
            - 0.0.0.0
            - --port
            - "8000"
          resources:
            requests:
              cpu: "8"
              memory: "48Gi"
              nvidia.com/gpu: 2
            limits:
              cpu: "16"
              memory: "96Gi"
              nvidia.com/gpu: 2
          volumeMounts:
            - name: shm
              mountPath: /dev/shm
            - name: hf-cache
              mountPath: /root/.cache/huggingface
      volumes:
        - name: shm
          emptyDir:
            medium: Memory
            sizeLimit: 16Gi
        - name: hf-cache
          emptyDir:
            sizeLimit: 300Gi
YAML
```

주의:

- `Qwen/Qwen-Image`는 예시 모델이다.
- 실제 이미지 생성 모델별로 필요한 vLLM-Omni image, dependency, VRAM, 지원 옵션을 확인해야 한다.
- 운영에서는 LLM용 vLLM과 이미지 생성용 vLLM-Omni를 별도 Deployment/Service로 분리하는 것이 좋다.

---

# Option B. 2순위: TensorRT-LLM

## B-1. 선택 기준

TensorRT-LLM은 vLLM보다 준비 과정은 길지만 최적화 여지가 크다.

- latency/throughput 최적화가 중요할 때
- NVIDIA GPU에 맞춘 엔진 빌드가 가능할 때
- 모델 변환, quantization, engine cache, 배포 자동화를 감수할 수 있을 때

## B-2. TensorRT-LLM 아키텍처

```text
Local PC
  -> LoadBalancer / port-forward
  -> Service trtllm:8000
  -> TensorRT-LLM Pod
      - nvidia.com/gpu: 2
      - trtllm-serve --tp_size 2
      - 또는 사전 빌드된 engine 사용
  -> GPU Node
```

## B-3. 빠른 PoC: trtllm-serve 직접 실행

```bash
cat <<'YAML' > trtllm-deployment.yaml
apiVersion: apps/v1
kind: Deployment
metadata:
  name: trtllm
  labels:
    app: trtllm
spec:
  replicas: 1
  selector:
    matchLabels:
      app: trtllm
  template:
    metadata:
      labels:
        app: trtllm
    spec:
      nodeSelector:
        gpu-node: "true"
      tolerations:
        - key: "nvidia.com/gpu"
          operator: "Exists"
          effect: "NoSchedule"
      containers:
        - name: trtllm
          image: nvcr.io/nvidia/tensorrt-llm/release:latest
          imagePullPolicy: IfNotPresent
          ports:
            - containerPort: 8000
          env:
            - name: HUGGING_FACE_HUB_TOKEN
              valueFrom:
                secretKeyRef:
                  name: hf-token
                  key: HF_TOKEN
          command:
            - trtllm-serve
          args:
            - meta-llama/Llama-3.1-8B-Instruct
            - --host
            - 0.0.0.0
            - --port
            - "8000"
            - --tp_size
            - "2"
          resources:
            requests:
              cpu: "8"
              memory: "48Gi"
              nvidia.com/gpu: 2
            limits:
              cpu: "16"
              memory: "96Gi"
              nvidia.com/gpu: 2
          volumeMounts:
            - name: shm
              mountPath: /dev/shm
            - name: model-cache
              mountPath: /root/.cache
      volumes:
        - name: shm
          emptyDir:
            medium: Memory
            sizeLimit: 16Gi
        - name: model-cache
          emptyDir:
            sizeLimit: 300Gi
YAML
```

```bash
kubectl apply -f trtllm-deployment.yaml
```

## B-4. 운영형: 엔진 빌드 후 서빙

운영에서는 아래 흐름을 권장한다.

```text
1. 모델 다운로드
2. TensorRT-LLM engine build
3. engine artifact를 S3/EFS/EBS/PVC에 저장
4. Pod 시작 시 engine mount
5. trtllm-serve 또는 Triton backend로 engine serving
```

예시 구조:

```text
s3://my-model-bucket/trtllm-engines/llama-8b-tp2/
  config.json
  rank0.engine
  rank1.engine
```

K8s에서는 initContainer로 S3에서 engine을 내려받거나, EFS/PVC를 mount한다.

---

# Option C. 3순위: Triton + TensorRT-LLM

## C-1. 선택 기준

Triton은 단순히 LLM 하나를 빠르게 띄우는 도구라기보다 inference serving platform에 가깝다.

- 사내 표준 serving layer가 Triton일 때
- 모델 repository 관리가 필요할 때
- TensorRT, ONNX, Python backend, TensorRT-LLM backend를 함께 운영할 때
- autoscaling, metrics, multi-model serving을 표준화하고 싶을 때

## C-2. Triton + TensorRT-LLM 아키텍처

```text
Local PC
  -> LoadBalancer / port-forward
  -> Service triton:8000/8001/8002
  -> Triton Server Pod
      - HTTP: 8000
      - gRPC: 8001
      - Metrics: 8002
      - TensorRT-LLM backend
      - model repository mounted
      - nvidia.com/gpu: 2
  -> GPU Node
```

## C-3. Triton model repository 예시 구조

```text
/model-repository/
  llama_trtllm/
    1/
      engine files 또는 backend artifacts
    config.pbtxt
```

Triton 일반 TensorRT 모델 복제 예시는 다음과 같다.

```protobuf
name: "my_tensorrt_model"
platform: "tensorrt_plan"
max_batch_size: 8

instance_group [
  {
    kind: KIND_GPU
    count: 1
    gpus: [0]
  },
  {
    kind: KIND_GPU
    count: 1
    gpus: [1]
  }
]
```

위 설정은 모델을 GPU 2개에 쪼개는 것이 아니라 GPU 0, GPU 1에 각각 복제하는 방식이다.

LLM을 GPU 2개에 나누려면 Triton + TensorRT-LLM backend에서 TP=2 engine/backend 설정을 사용한다.

## C-4. Triton Deployment 예시

```bash
cat <<'YAML' > triton-trtllm-deployment.yaml
apiVersion: apps/v1
kind: Deployment
metadata:
  name: triton-trtllm
  labels:
    app: triton-trtllm
spec:
  replicas: 1
  selector:
    matchLabels:
      app: triton-trtllm
  template:
    metadata:
      labels:
        app: triton-trtllm
    spec:
      nodeSelector:
        gpu-node: "true"
      tolerations:
        - key: "nvidia.com/gpu"
          operator: "Exists"
          effect: "NoSchedule"
      containers:
        - name: triton
          image: nvcr.io/nvidia/tritonserver:latest
          imagePullPolicy: IfNotPresent
          ports:
            - containerPort: 8000
            - containerPort: 8001
            - containerPort: 8002
          command:
            - tritonserver
          args:
            - --model-repository=/models
            - --http-port=8000
            - --grpc-port=8001
            - --metrics-port=8002
          resources:
            requests:
              cpu: "8"
              memory: "48Gi"
              nvidia.com/gpu: 2
            limits:
              cpu: "16"
              memory: "96Gi"
              nvidia.com/gpu: 2
          volumeMounts:
            - name: model-repository
              mountPath: /models
            - name: shm
              mountPath: /dev/shm
      volumes:
        - name: model-repository
          persistentVolumeClaim:
            claimName: triton-model-repository-pvc
        - name: shm
          emptyDir:
            medium: Memory
            sizeLimit: 16Gi
YAML
```

```bash
kubectl apply -f triton-trtllm-deployment.yaml
```

주의:

- 위 YAML은 Triton 서버 구동 뼈대이다.
- 실제 TensorRT-LLM backend 구동은 backend 포함 이미지, model repository 구성, engine artifact, config.pbtxt 설정이 추가로 필요하다.
- 사내 표준 Triton 이미지가 있다면 해당 이미지를 우선 사용한다.

---

## 9. 공통 Service 구성

### 9.1 ClusterIP Service

내부 또는 port-forward 테스트용이다.

```bash
cat <<'YAML' > ai-serving-service.yaml
apiVersion: v1
kind: Service
metadata:
  name: ai-serving
spec:
  type: ClusterIP
  selector:
    app: vllm
  ports:
    - name: http
      port: 8000
      targetPort: 8000
YAML
```

```bash
kubectl apply -f ai-serving-service.yaml
```

주의: selector의 `app: vllm`은 테스트 대상에 맞게 바꾼다.

```text
vLLM: app: vllm
vLLM-Omni: app: vllm-omni-image
TensorRT-LLM: app: trtllm
Triton: app: triton-trtllm
```

---

## 10. 외부 API 노출

### 10.1 간단한 PoC: LoadBalancer Service

로컬 PC에서 EKS 외부 IP/DNS로 직접 호출하려면 `LoadBalancer` 타입을 사용한다.

```bash
cat <<'YAML' > ai-serving-lb.yaml
apiVersion: v1
kind: Service
metadata:
  name: ai-serving-lb
spec:
  type: LoadBalancer
  selector:
    app: vllm
  ports:
    - name: http
      port: 80
      targetPort: 8000
YAML
```

```bash
kubectl apply -f ai-serving-lb.yaml
kubectl get svc ai-serving-lb -w
```

주소 확인:

```bash
export API_URL=http://$(kubectl get svc ai-serving-lb -o jsonpath='{.status.loadBalancer.ingress[0].hostname}')
echo ${API_URL}
```

보안 주의:

- PoC에서는 LoadBalancer를 쓸 수 있지만 운영에서는 인증/인가/API Gateway/Ingress/WAF/PrivateLink 등을 검토한다.
- 모델 API를 인터넷에 무인증으로 공개하지 않는다.

### 10.2 더 안전한 로컬 테스트: port-forward

외부 LoadBalancer를 만들지 않고 로컬에서만 테스트한다.

```bash
kubectl port-forward svc/ai-serving 8000:8000
```

```bash
export API_URL=http://localhost:8000
```

---

## 11. 로컬 호출 테스트

### 11.1 vLLM / TensorRT-LLM OpenAI Chat API 테스트

```bash
curl ${API_URL}/v1/models | jq
```

```bash
curl ${API_URL}/v1/chat/completions \
  -H "Content-Type: application/json" \
  -d '{
    "model": "meta-llama/Llama-3.1-8B-Instruct",
    "messages": [
      {
        "role": "user",
        "content": "GPU 2개로 서빙되는지 짧게 설명해줘."
      }
    ],
    "max_tokens": 256,
    "temperature": 0.2
  }' | jq
```

### 11.2 vLLM-Omni 이미지 생성 API 테스트

```bash
curl -X POST ${API_URL}/v1/images/generations \
  -H "Content-Type: application/json" \
  -d '{
    "prompt": "a futuristic data center on EKS with two GPUs, realistic, high detail",
    "size": "1024x1024",
    "seed": 42
  }' | jq -r '.data[0].b64_json' | base64 -d > output.png
```

### 11.3 Triton Health 테스트

```bash
curl ${API_URL}/v2/health/ready
curl ${API_URL}/v2/models
```

Triton은 OpenAI API가 기본이 아니므로, TensorRT-LLM backend 구성 또는 별도 frontend가 필요할 수 있다.

---

## 12. GPU 2개 사용 여부 확인

```bash
POD=$(kubectl get pod -l app=vllm -o jsonpath='{.items[0].metadata.name}')
kubectl describe pod ${POD} | grep -A8 -i "Limits"
```

```bash
kubectl exec -it ${POD} -- nvidia-smi
```

vLLM 로그에서 tensor parallel 관련 로그를 확인한다.

```bash
kubectl logs deploy/vllm -f
```

---

## 13. 이미지 생성 모델 고려 사항

이미지 생성 모델은 LLM과 운영 특성이 다르다.

```text
LLM
- token streaming
- KV cache 중요
- OpenAI Chat Completions API 중심
- vLLM 또는 TensorRT-LLM 적합

Image Generation
- diffusion/DiT pipeline
- step 수, 해상도, scheduler 영향 큼
- request latency가 길 수 있음
- GPU memory peak가 모델별로 큼
- vLLM-Omni, Diffusers custom server, ComfyUI API, Triton Python backend 등 검토
```

추천 구조:

```text
/api/chat
  -> vLLM 또는 TensorRT-LLM

/api/images/generations
  -> vLLM-Omni 또는 별도 image generation server

공통 Gateway
  -> 인증/인가
  -> rate limit
  -> request size 제한
  -> 로깅/모니터링
```

PoC에서는 하나씩 따로 띄운다.

```text
1. vLLM LLM Pod 검증
2. vLLM-Omni image Pod 검증
3. 필요 시 TensorRT-LLM 성능 비교
4. 사내 표준화가 필요하면 Triton + TensorRT-LLM 전환 검토
```

---

## 14. 운영 전환 체크리스트

- LoadBalancer 무인증 공개 금지
- Private subnet / internal NLB / ALB Ingress / API Gateway 검토
- HF cache 또는 engine artifact는 PVC/EFS/S3로 분리
- GPU node autoscaling은 Karpenter 또는 Cluster Autoscaler 검토
- Prometheus/Grafana로 GPU, latency, throughput 모니터링
- request timeout과 max tokens/image size 제한
- 모델별 readinessProbe 조정
- 배포 시 rolling update보다 recreate 전략 검토
- PodDisruptionBudget 검토
- image tag는 `latest` 대신 고정 버전 사용

---

## 15. 최종 선택 가이드

### 빠른 PoC

```text
vLLM + LoadBalancer 또는 port-forward
```

### 이미지 생성 PoC

```text
vLLM-Omni + /v1/images/generations
```

### LLM 성능 최적화

```text
TensorRT-LLM + TP=2 engine
```

### 사내 표준 serving platform

```text
Triton + TensorRT-LLM backend + model repository
```

### 가장 현실적인 진행 순서

```text
1. EKS GPU node + NVIDIA device plugin 구성
2. gpu-test Pod로 nvidia-smi 확인
3. vLLM LLM을 GPU 2개로 띄움
4. 로컬에서 port-forward 또는 LoadBalancer로 호출
5. vLLM-Omni로 이미지 생성 모델 별도 검증
6. 성능 요구사항이 생기면 TensorRT-LLM 벤치마크
7. 여러 모델 운영/표준화 요구가 생기면 Triton + TensorRT-LLM 검토
```
