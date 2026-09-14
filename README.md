# DGX Spark ×4 · DeepSeek-V4.1-Flash · vLLM TP4 部署指南

在 **4 台 NVIDIA DGX Spark（GB10）** 上用 vLLM **TP4** 跑 **DeepSeek-V4.1-Flash**，窗 **720896**（614400 prompt + 102400 output + 4096）、**image:20**、**Engram-on-disk**。

> **2026-09-14 更新**：本仓库已切换为**第一方配方**（Tony 七补丁 + joe 4 节点 mp 组法 + vLLM 官方 recipe 口径）。
> 旧版 KVB / `749568` / `image:4` 方案已废弃。详见 [`CHANGELOG.md`](CHANGELOG.md)。

---

## 配方来源（全部第一方）

| 来源 | 取了什么 |
|---|---|
| [tonyd2wild/DeepSeek-V4.1-Flash-vLLM-DGX-Spark](https://github.com/tonyd2wild/DeepSeek-V4.1-Flash-vLLM-DGX-Spark) | 七个 bind-mount 补丁、`DSV41_ENGRAM_DISK=1`、`--block-size 128`、CUDA graph / DSpark 口径 |
| [josephdrose/joe-spark-patches](https://github.com/josephdrose/joe-spark-patches) `dsv41/` | 4 节点 `mp` 组法、`b12x` MoE 后端对照 |
| [recipes.vllm.ai/deepseek-ai/DeepSeek-V4.1-Flash](https://recipes.vllm.ai/deepseek-ai/DeepSeek-V4.1-Flash) | tokenizer / parser / DSpark spec / `VLLM_ENGINE_READY_TIMEOUT_S` |

---

## 仓库内容

| 路径 | 说明 |
|---|---|
| [`scripts/v41-tuned-tp4.sh`](scripts/v41-tuned-tp4.sh) | **现役起服脚本**（四台、哨兵硬闸、worker 先 head 后） |
| [`patch/`](patch/) | 七个补丁 + `mounts.txt`（与 Tony 上游同树，已含 md5 可核） |
| [`docs/`](docs/) | 拓扑、护栏、参数依据、验收、排障 |

---

## 现役配置摘要（A 级，2026-09-14 本 boot）

| 项 | 值 |
|---|---|
| 入口 | `http://<head>:8001/v1`，模型名 `deepseek-v4.1-flash` |
| 镜像 | `aidendle94/sparkrun-vllm-dsv41-gb10:production-1.0`（四台同一颗，判据是 `RootFS.Layers` digest） |
| 窗 | `--max-model-len **720896**` |
| Engram | `DSV41_ENGRAM_DISK=1` + `--engram-config '{"cpu_offload": false}'`（**必须**，否则每 rank 118.81 GiB > 可用 ~114 GiB） |
| MoE | `--moe-backend b12x` + `VLLM_B12X_MOE_FP4_FORCE_A16=1` |
| 投机 | DSpark k=5，`enable_adaptive_verification: false` |
| 图 | CUDA graphs `FULL_AND_PIECEWISE` |
| 其它 | `gmu 0.80`、`seqs 8`、`batched 8192`、`block-size 128` |
| 视觉 | `--limit-mm-per-prompt '{"image":20}'` |
| KV 池 | **2,552,135 tokens** / 13.79 GiB / 满窗 **3.54×**（本 boot profiling 路径，无 KVB） |

性能（同 boot）：单流 **88.4 tok/s**、prefill **≈1950 tok/s**、241K needle 命中、image 输入正确；同会话五轮视觉压测 **5/5**。

---

## 5 步快速开始

### 1 · 网络与地址

四台高速口（RoCE `10.100.24.x`）与节点编号**不一致** —— 必读 [`docs/01-hardware-topology.md`](docs/01-hardware-topology.md)。

| SSH 别名 | RoCE |
|---|---|
| spark-01 | `10.100.24.4` |
| spark-02 | `10.100.24.3` |
| spark-03 | `10.100.24.1` |
| spark-04 | `10.100.24.2` |

### 2 · 内存护栏与哨兵

```bash
# 每台：内核护栏（需 root）
vm.min_free_kbytes = 1048576
vm.watermark_scale_factor = 200

# head：宿主侧哨兵（加载期相位，ABS 下限 1024 MB，不得放宽）
/home/cq/v41-mg-phase.sh start
```

详见 [`docs/02-host-preparation.md`](docs/02-host-preparation.md)、[`docs/07-memory-safety.md`](docs/07-memory-safety.md)。

### 3 · 模型与补丁

```bash
# 每台：权重 48/48 分片，同路径
ls /home/cq/models/DeepSeek-V4.1-Flash/*.safetensors | wc -l

# 每台：把本仓库 patch/ 拷到同一目录（示例 /home/cq/v41patch/）
scp -r patch/ spark-01:/home/cq/v41patch/
# worker 02/03/04 同样
```

⚠️ **补丁必须四台都有**。只放 head 会让 worker 挂载失败。

### 4 · 预检（dry-run）

```bash
ssh spark-01 'DRYRUN=1 CTX=720896 PATCH_DIR=/home/cq/v41patch bash /path/to/v41-tuned-tp4.sh'
```

确认四 rank 都有镜像行、`-e DSV41_ENGRAM_DISK=1`、七个 `-v .../v41patch/...` 挂载。

### 5 · 起服与验收

```bash
# 起服（哨兵不在岗会 exit 3）
ssh spark-01 'CTX=720896 PATCH_DIR=/home/cq/v41patch bash /home/cq/v41-tuned-tp4.sh'

# 验收
curl -s http://10.100.24.4:8001/v1/models
# 见 docs/08-verification.md
```

清场：

```bash
for n in 10.100.24.4 10.100.24.3 10.100.24.1 10.100.24.2; do
  ssh -n $n 'docker rm -f vllm_dsv41'
done
```

---

## 为什么必须 Engram-on-disk

不打补丁：每 rank `475.25 GiB ÷ 4 = 118.81 GiB`（C），本机每台可用约 **114 GiB** ⇒ 装不下。

打补丁后日志（A）：

```
Engram table DISK-backed: ... 23.60 GiB not allocated
```

每台省 **47.2 GiB**。四台各有完整 48 分片本地副本时，Engram 行从本地 NVMe 读，**不需要 NFS**。

**2026-09-14 事故**：未打补丁直接起 TP4 ⇒ spark-03 **wedge**（ping 通、SSH banner 超时）。`docker --memory` cap 在统一内存上**拦不住**驱动代持页。详见 [`docs/10-troubleshooting.md`](docs/10-troubleshooting.md)。

---

## 文档目录

| 文件 | 内容 |
|---|---|
| [`docs/01-hardware-topology.md`](docs/01-hardware-topology.md) | RoCE 拓扑、地址表、接线 |
| [`docs/02-host-preparation.md`](docs/02-host-preparation.md) | 护栏 + 哨兵 |
| [`docs/03-model-preparation.md`](docs/03-model-preparation.md) | 权重、Engram、分发 |
| [`docs/04-patch-set.md`](docs/04-patch-set.md) | 补丁说明（本仓库 `patch/` 已含文件） |
| [`docs/05-preflight.md`](docs/05-preflight.md) | 起服前检查 |
| [`docs/06-launch-parameters.md`](docs/06-launch-parameters.md) | **现役参数与依据** |
| [`docs/07-memory-safety.md`](docs/07-memory-safety.md) | wedge 与哨兵 |
| [`docs/08-verification.md`](docs/08-verification.md) | 验收清单 |
| [`docs/09-rollback.md`](docs/09-rollback.md) | 回滚 |
| [`docs/10-troubleshooting.md`](docs/10-troubleshooting.md) | 踩坑表 |
| [`docs/11-measurement-notes.md`](docs/11-measurement-notes.md) | 测量纪律 |
| [`docs/12-engine-runtime-notes.md`](docs/12-engine-runtime-notes.md) | 引擎运行时 |

---

## 硬纪律

1. **单机先行**：新参数组合先在 1 台跑通，再上 4 台。
2. **无哨兵不起服**：脚本 `[0/4] guard check` 会验；哨兵没挂就 `exit 3`。
3. **算出装不下就不要起**：统一内存上 docker memory cap 不是保险。
4. **跨 boot 数字不可直比**：同 boot、丢冷样本、重复 3 次报中位（见 docs/11）。

---

## License

MIT —— 见 [`LICENSE`](LICENSE)。补丁文件遵循上游 Tony 仓库许可。
