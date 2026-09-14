# 06 · 关键参数与取值依据（第一方配方，2026-09-14）

**这篇讲什么**：`scripts/v41-tuned-tp4.sh` 里每个关键参数的取值与依据。环境变量可在起服前覆盖（见脚本头部）。

---

## 1. 参数总表

| 参数 / 环境变量 | 默认值 | 依据 |
|---|---|---|
| `IMAGE` | `aidendle94/sparkrun-vllm-dsv41-gb10:production-1.0` | 四台 `RootFS.Layers` 48 行逐字相同（A） |
| `MODEL` | `/home/cq/models/DeepSeek-V4.1-Flash` | 四台各 48/48 本地分片 |
| `PATCH_DIR` | `/home/cq/v41patch` | 七个补丁 + `mounts.txt` |
| `PORT` | `8001` | 避开 `:8000` 常用占用 |
| `MASTER_PORT` | `25410` | rendezvous（joe 组法） |
| `TP` | `4` | 四节点 |
| `CTX` | **720896** | 614400 + 102400 + 4096 |
| `GPU_UTIL` | **0.80** | profiling 路径取 KV（**无 KVB**） |
| `MAXSEQS` | **8** | joe 1M 窗对照 |
| `MAXBATCH` | **8192** | joe 实测 16K 使 KV 掉 35.8% 且无 prefill 收益 |
| `BLOCK_SIZE` | **128** | Tony recipe |
| `DSPARK` | **5** | Tony boot10 / recipe |
| `MOE_BACKEND` | **b12x** | joe 对照表 KV 池最大腿 |
| `B12X_A16` | **1** | `VLLM_B12X_MOE_FP4_FORCE_A16=1` |
| `VISION` | `1` | 开多模态 |
| `IMAGES_PER_PROMPT` | **20** | 2026-09-14 晚重起实测 |
| `DSV41_ENGRAM_DISK` | **1** | **必须**；否则每 rank 118.81 GiB |
| CUDA graphs | `FULL_AND_PIECEWISE` | Tony recipe |
| `--engram-config` | `{"cpu_offload": false}` | 行在 NVMe，不 CPU offload |
| parsers | `deepseek_v41` | vLLM recipe |

**刻意不设**：`--kv-cache-memory-bytes`、`--default-chat-template-kwargs`（thinking 走 recipe 默认 ON）。

---

## 2. `--max-model-len = 720896`

```
614400  (600K prompt)
+ 102400 (100K output)
+   4096 (余量)
= 720896
```

客户端 `contextWindow` 可对齐 614400；引擎窗必须含输出预算。

---

## 3. 容量：profiling 路径（本配方无 KVB）

本部署**不设** `--kv-cache-memory-bytes` ⇒ vLLM 走 **memory profiling**，GMU 0.80 参与 KV 分配。

本 boot 实测（A，`docker logs` + `GET /v1/models`）：

| 项 | 值 |
|---|---|
| GPU KV | **2,552,135 tokens** |
| KV 体积 | **13.79 GiB** |
| 满窗倍数 | **3.54×** |
| 起服 GMU 闸 | 需 ≥ 97.35 GiB；快照 98.21 / 121.69 GiB |

⚠️ 若你曾用 KVB 档（如 5.9e9 → 1,722,343 tokens），**不可与本次跨 boot 直比**。

`--max-num-batched-tokens` 保持 **8192**：joe 记录 16K chunk 使 KV 掉 35.8%。

---

## 4. Engram-on-disk（决定性）

| 状态 | 每 rank 权重驻留（C） | 能否起服 |
|---|---|---|
| 无补丁 | 475.25 ÷ 4 = **118.81 GiB** | ❌ > ~114 GiB 可用 |
| 有补丁 | 日志约 **81.4 GiB** 级 + 盘上 23.6 GiB×2 不分配 | ✅ |

日志关键字（A）：

```
Engram table DISK-backed: ... 23.60 GiB not allocated
```

---

## 5. MoE：`b12x` + `FORCE_A16`

joe `dsv41/README.md` MoE 后端对照：本配置选 **b12x bf16 腿**（`VLLM_B12X_MOE_FP4_FORCE_A16=1`）以最大化 KV 池。

---

## 6. DSpark k=5

```json
{
  "method": "dspark",
  "num_speculative_tokens": 5,
  "enable_adaptive_verification": false
}
```

与 Tony boot10 / vLLM recipe 一致。CUDA graph capture sizes 由 `DSPARK` 与 `MAXSEQS` 自动生成。

---

## 7. 视觉 `image:20`

```bash
--limit-mm-per-prompt '{"image":20}' --mm-processor-cache-gb 1
```

2026-09-14 同会话五轮视觉压测 5/5（A）。此前 `image:4` 时第 5 轮会 400。

---

## 8. 思考模式

**不设** `--default-chat-template-kwargs`。vLLM recipe 默认 **thinking ON、effort 50**。

客户端可用 `chat_template_kwargs.thinking=false` 或 `reasoning_effort` 控每请求行为。

---

## 9. NCCL 与节点映射

脚本内 `NODE_ROCE`（rank 0..3）：

```
10.100.24.4  # spark-01
10.100.24.3  # spark-02
10.100.24.1  # spark-03
10.100.24.2  # spark-04
```

⚠️ **02 与 03 的 RoCE 尾号与节点号相反。**

`--distributed-executor-backend mp`，worker 3→2→1 先起，head 0 最后。

---

## 10. 环境变量速查

```bash
# 只看命令，不起服
DRYRUN=1 CTX=720896 PATCH_DIR=/home/cq/v41patch bash scripts/v41-tuned-tp4.sh

# 改窗（需重新 profiling，跨 boot 数字不可直比）
CTX=720896 GPU_UTIL=0.80 bash scripts/v41-tuned-tp4.sh
```
