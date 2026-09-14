#!/usr/bin/env bash
# v41-tuned-tp4.sh — DeepSeek-V4.1-Flash, 4x DGX Spark, TP4, Engram-on-disk.
#
# 来源（全部第一方；不使用本仓库任何已废的自制 boot/env/recipe）：
#   · 七个 bind-mount 补丁 + DSV41_ENGRAM_DISK + block-size 128 + graph/DSpark 口径：
#       tonyd2wild/DeepSeek-V4.1-Flash-vLLM-DGX-Spark  docs/RECIPE.md（boot10 服务配置）
#   · b12x bf16 选 KV 池最大那条腿（VLLM_B12X_MOE_FP4_FORCE_A16=1）：
#       josephdrose/joe-spark-patches  dsv41/README.md 的 MoE 后端对照表
#   · tokenizer / parser / dspark / ready timeout：recipes.vllm.ai/deepseek-ai/DeepSeek-V4.1-Flash
#   · 网卡名 / IP / 内存 / 权重路径：2026-09-14 本机实测
#
# 为什么必须 Engram-on-disk：不打补丁时每 rank 118.81 GiB（475.25/4），本机每台实测
# 可用约 114 GiB ⇒ 装不下，且会把节点推进 reclaim thrash（2026-09-14 17:44 spark-03
# 实测 wedge）。补丁把 189 GiB 的 Engram 表留在盘上，每 rank 降到约 81.4 GiB。
#
# 本机比上游更优的一点：四台各有完整 48 分片本地副本，Engram 行直接从本地 NVMe 读，
# 天然等价于上游 boot10 的 node-local rows，不需要 NFS，也不需要 engram_local.py。
set -uo pipefail

IMAGE="${IMAGE:-aidendle94/sparkrun-vllm-dsv41-gb10:production-1.0}"
MODEL="${MODEL:-/home/cq/models/DeepSeek-V4.1-Flash}"
PATCH_DIR="${PATCH_DIR:-/home/cq/v41patch}"
SERVED="${SERVED:-deepseek-v4.1-flash}"
PORT="${PORT:-8001}"
MASTER_PORT="${MASTER_PORT:-25410}"
NAME="${NAME:-vllm_dsv41}"

TP="${TP:-4}"
CTX="${CTX:-720896}"
GPU_UTIL="${GPU_UTIL:-0.80}"
MAXSEQS="${MAXSEQS:-8}"
MAXBATCH="${MAXBATCH:-8192}"
BLOCK_SIZE="${BLOCK_SIZE:-128}"
EAGER="${EAGER:-0}"
CGMODE="${CGMODE:-FULL_AND_PIECEWISE}"
CG_SIZES="${CG_SIZES:-}"
DSPARK="${DSPARK:-5}"
MOE_BACKEND="${MOE_BACKEND:-b12x}"
B12X_A16="${B12X_A16:-1}"
VISION="${VISION:-1}"
IMAGES_PER_PROMPT="${IMAGES_PER_PROMPT:-20}"
OOM_ADJ="${OOM_ADJ:-500}"
POLL_N="${POLL_N:-200}"
CACHE_HOST="${CACHE_HOST:-/home/cq/v41-cache}"

# rank 0..3 -> spark-01/02/03/04。全部走 RoCE 高速口（NCCL 与 rendezvous 同口）。
NODE_ROCE=(10.100.24.4 10.100.24.3 10.100.24.1 10.100.24.2)
HEAD_DIST="${NODE_ROCE[0]}"

SSH_OPTS="-n -o BatchMode=yes -o StrictHostKeyChecking=no -o ConnectTimeout=8"
sshto()   { ssh $SSH_OPTS "${NODE_ROCE[$1]}" "$2"; }
sshpipe() { ssh -o BatchMode=yes -o StrictHostKeyChecking=no -o ConnectTimeout=8 \
              "${NODE_ROCE[$1]}" 'cat > /tmp/v41-tuned-launch.sh && bash /tmp/v41-tuned-launch.sh'; }

MOUNT_ARGS=""
while read -r f rel; do
  [ -z "$f" ] && continue
  MOUNT_ARGS="$MOUNT_ARGS -v $PATCH_DIR/$f:/usr/local/lib/python3.12/dist-packages/vllm/$rel:ro"
done < "$PATCH_DIR/mounts.txt"

NCCL_ENV="-e NCCL_NET=IB -e NCCL_IB_DISABLE=0 -e NCCL_IB_HCA=rocep1s0f0,roceP2p1s0f0 \
 -e NCCL_IB_GID_INDEX=3 -e NCCL_IB_ROCE_VERSION_NUM=2 -e NCCL_IB_TC=104 -e NCCL_NET_GDR_LEVEL=5 \
 -e NCCL_CROSS_NIC=1 -e NCCL_NET_PLUGIN=none -e NCCL_IB_SUBNET_AWARE_ROUTING=1 -e NCCL_IB_MERGE_NICS=0 \
 -e NCCL_CUMEM_ENABLE=0 -e NCCL_WIN_ENABLE=0 -e NCCL_IGNORE_CPU_AFFINITY=1 -e NCCL_IB_TIMEOUT=22 \
 -e NCCL_IB_RETRY_CNT=7 -e NCCL_SOCKET_IFNAME=enp1s0f0np0 -e GLOO_SOCKET_IFNAME=enp1s0f0np0 \
 -e NCCL_NVLS_ENABLE=0 -e NCCL_DEBUG=${NCCL_DEBUG:-WARN}"

ARCH_ENV="-e CUTE_DSL_ARCH=sm_121a -e TORCH_CUDA_ARCH_LIST=12.1a -e FLASHINFER_CUDA_ARCH_LIST=12.1a \
 -e CUDA_DEVICE_ORDER=PCI_BUS_ID -e PYTORCH_CUDA_ALLOC_CONF=expandable_segments:True"

SAFE_ENV="-e MAX_JOBS=2 -e FLASHINFER_NVCC_THREADS=1 -e VLLM_USE_FLASHINFER_SAMPLER=0 \
 -e TILELANG_CACHE_DIR=/cache/tilelang -e TRITON_CACHE_DIR=/cache/triton \
 -e VLLM_CACHE_ROOT=/cache/vllm-cache -e VLLM_ENGINE_READY_TIMEOUT_S=3600 \
 -e VLLM_ALLOW_LONG_MAX_MODEL_LEN=1 -e HF_HUB_OFFLINE=1"

ENGRAM_ENV="-e DSV41_ENGRAM_DISK=1"

B12X_ENV="-e B12X_COMPILE_CACHE_DIR=/cache/b12x/compile -e B12X_ROCE_CACHE_DIR=/cache/b12x/roce"
[ -n "$B12X_A16" ] && B12X_ENV="$B12X_ENV -e VLLM_B12X_MOE_FP4_FORCE_A16=$B12X_A16"

EAGER_ARG=""; GRAPH_ARG=""; GRAPH_ENV=""
if [ "$EAGER" = 1 ]; then
  EAGER_ARG="--enforce-eager"
else
  if [ -z "$CG_SIZES" ]; then
    CG_SIZES=$( { seq "$DSPARK" "$DSPARK" $((DSPARK * MAXSEQS));
                  seq $((DSPARK + 1)) $((DSPARK + 1)) $(((DSPARK + 1) * MAXSEQS)); } \
                | sort -n -u | paste -sd, - )
  fi
  GRAPH_ARG='--compilation-config "{\"cudagraph_mode\":\"'"$CGMODE"'\",\"cudagraph_capture_sizes\":['"$CG_SIZES"']}"'
  GRAPH_ENV="-e VLLM_USE_BREAKABLE_CUDAGRAPH=1"
fi

MOE_ARG=""; [ -n "$MOE_BACKEND" ] && MOE_ARG="--moe-backend $MOE_BACKEND"
SPEC_ARG=""
[ -n "$DSPARK" ] && SPEC_ARG='--speculative-config "{\"method\":\"dspark\",\"num_speculative_tokens\":'"$DSPARK"',\"draft_sample_method\":\"probabilistic\",\"rejection_sample_method\":\"block\",\"enable_adaptive_verification\":false}"'
VISION_ARG="--language-model-only"
[ "$VISION" = 1 ] && VISION_ARG='--limit-mm-per-prompt "{\"image\":'"$IMAGES_PER_PROMPT"'}" --mm-processor-cache-gb 1'
PARSER_ARG="--enable-auto-tool-choice --tool-call-parser deepseek_v41 --reasoning-parser deepseek_v41"

runscript() {
  local r="$1" hl=""
  [ "$r" != 0 ] && hl="--headless"
  cat <<EOF
set -uo pipefail
docker rm -f $NAME >/dev/null 2>&1 || true
mkdir -p $CACHE_HOST
docker run -d --name $NAME --network host --ipc host --shm-size 32g --gpus all \\
 --cap-add IPC_LOCK --ulimit memlock=-1 --ulimit stack=67108864 --ulimit nofile=1048576:1048576 \\
 --device /dev/infiniband:/dev/infiniband --restart no --init --oom-score-adj $OOM_ADJ \\
 -v $MODEL:$MODEL:ro \\
 -v $CACHE_HOST:/cache \\
$MOUNT_ARGS \\
 -e VLLM_HOST_IP=${NODE_ROCE[$r]} \\
 $ENGRAM_ENV $NCCL_ENV $ARCH_ENV $SAFE_ENV $GRAPH_ENV $B12X_ENV \\
 --entrypoint /bin/bash $IMAGE -lc '
 exec vllm serve $MODEL \\
 --served-model-name $SERVED \\
 --host 0.0.0.0 --port $PORT \\
 --tensor-parallel-size $TP \\
 --gpu-memory-utilization $GPU_UTIL \\
 --max-model-len $CTX --max-num-seqs $MAXSEQS --max-num-batched-tokens $MAXBATCH \\
 --block-size $BLOCK_SIZE \\
 --engram-config "{\\"cpu_offload\\": false}" \\
 --tokenizer-mode deepseek_v41 \\
 --enable-chunked-prefill \\
 $EAGER_ARG $GRAPH_ARG $MOE_ARG $SPEC_ARG $VISION_ARG $PARSER_ARG \\
 --distributed-executor-backend mp \\
 --nnodes $TP --node-rank $r --master-addr $HEAD_DIST --master-port $MASTER_PORT $hl
 '
EOF
}

if [ "${DRYRUN:-0}" = 1 ]; then
  echo "### DRYRUN ctx=$CTX util=$GPU_UTIL seqs=$MAXSEQS batch=$MAXBATCH block=$BLOCK_SIZE eager=$EAGER cg=[$CG_SIZES] dspark=$DSPARK moe=$MOE_BACKEND a16=$B12X_A16 vision=$VISION"
  for r in 0 1 2 3; do echo "===== rank $r -> ${NODE_ROCE[$r]} ====="; runscript "$r"; echo; done
  exit 0
fi

echo ">>> [0/4] guard check"
for r in 0 1 2 3; do
  g=$(sshto "$r" "pgrep -f 'v41-mg-load.sh __watch' >/dev/null && echo guard-on || echo GUARD-OFF")
  a=$(sshto "$r" "awk '/MemAvailable/{print \$2}' /proc/meminfo")
  echo "  ${NODE_ROCE[$r]} $g availKB=$a"
  if [ "$g" = "GUARD-OFF" ]; then echo ">>> ABORT: memory guard not running on ${NODE_ROCE[$r]}"; exit 3; fi
done

echo ">>> [1/4] clearing $NAME on all four"
for r in 0 1 2 3; do sshto "$r" "docker rm -f $NAME >/dev/null 2>&1 || true"; done
sleep 3

echo ">>> [2/4] workers 3,2,1"
for r in 3 2 1; do
  echo "  rank $r -> ${NODE_ROCE[$r]}"
  runscript "$r" | sshpipe "$r"
  sleep 4
done
echo ">>> [3/4] head 0 -> ${NODE_ROCE[0]}"
runscript 0 | sshpipe 0

echo ">>> [4/4] polling head :$PORT"
for i in $(seq 1 "$POLL_N"); do
  sleep 15
  if sshto 0 "curl -s --max-time 4 localhost:$PORT/v1/models 2>/dev/null" | grep -q "$SERVED"; then
    echo ">>> OK: $SERVED UP after ~$((i*15))s"; exit 0
  fi
  st=$(sshto 0 "docker inspect -f '{{.State.Status}}' $NAME 2>/dev/null" || echo unknown)
  if [ "$st" = exited ]; then echo ">>> FAIL: head exited at ~$((i*15))s"; exit 1; fi
  if [ $((i % 4)) = 0 ]; then
    line="  ${i}x15s head=$st"
    for r in 0 1 2 3; do
      a=$(sshto "$r" "awk '/MemAvailable/{print int(\$2/1024)}' /proc/meminfo" 2>/dev/null || echo NA)
      line="$line | r$r=${a}MB"
    done
    echo "$line"
  fi
done
echo ">>> FAIL: timed out"; exit 2
