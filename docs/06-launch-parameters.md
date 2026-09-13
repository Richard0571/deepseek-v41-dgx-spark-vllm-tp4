# 06 · 关键参数与取值依据

**这篇讲什么**：起服命令里每个关键参数的取值、为什么取这个值，以及两条**反直觉但有源码级证据**的结论（GMU 是空转旋钮；带 tools 时引擎强制保留历史思考）。

---

## 1. 参数总表

| 参数 | 取值 | 依据 |
|---|---|---|
| `--tensor-parallel-size` | **4** | 四台节点 |
| `--distributed-executor-backend` | `mp` | 多进程执行器 |
| `--nnodes` / `--node-rank` | `4` / `0..3` | rank 0 = head，其余加 `--headless` |
| `--master-addr` / `--master-port` | `10.100.24.4` / **`29541`** | 端口**避开**另一个常用服务占用的 `29500` |
| `--host` / `--port` | `0.0.0.0` / **`8001`** | **不要用 `8000`**（常被另一个服务占用） |
| `--served-model-name` | `deepseek-v4.1-flash` | 对外模型名 |
| `--gpu-memory-utilization` | **0.80** | 见第 3 节（**设了 KVB 之后它只是启动校验**） |
| `--kv-cache-memory-bytes` | **5900000000** | **真正的容量旋钮**，1:1 生效 |
| `--max-num-batched-tokens` | **2048** | 见第 4 节（与 KVB 成对） |
| `--max-model-len` | **749568** | 见第 2 节 |
| `--max-num-seqs` | **8** | 并发上限 |
| `--block-size` | **128** | 页尺寸契约（见 [`docs/04`](04-patch-set.md)） |
| `--moe-backend` | **`b12x`** | 见第 6 节 |
| `--speculative-config` | `{"method":"dspark","num_speculative_tokens":5, ...}` | 见第 7 节 |
| `--compilation-config` | `{"cudagraph_mode":"FULL_AND_PIECEWISE","cudagraph_capture_sizes":[...]}` | 见第 7 节 |
| `--enforce-eager` | 关（走 CUDA graph） | |
| `--enable-prefix-caching` | 开 | 见 [`docs/12`](12-engine-runtime-notes.md) |
| `--default-chat-template-kwargs` | `{"thinking": false}` | 请求级思考开关的默认值 |
| `--limit-mm-per-prompt` | `{"image":4}` | 多模态上限 |
| `--mm-processor-cache-gb` | `1` | 多模态处理器缓存 |
| `--tool-call-parser` / `--reasoning-parser` | 与模型匹配的解析器名 | ⚠️ 不同引擎的解析器名**拼写不同**，不要混用 |

---

## 2. `--max-model-len = 749568` 是怎么来的

直觉上「600K 上下文」应该写 `600000`。**不行。**

引擎把 **prompt + generation 之和**当作上限来校验。要同时支持
「600Ki prompt」+「128Ki completion」，就必须：

```
614400 (600Ki prompt)
+ 131072 (128Ki completion)
+   4096 (余量)
= 749568
```

写成 600000 的话，一个 600K 的请求会因为「加上输出会超窗」而被拒。

> 这也是为什么「另一个引擎的 262144 / 1048576 配方」不能直接搬过来 ——
> 它们的窗语义与完成长度预算是分开的。

---

## 3. ⭐ `--kv-cache-memory-bytes` 才是容量旋钮

### 3.1 先看旧做法为什么错

在没有设 KVB 的配置里，容量由 `--gpu-memory-utilization`（GMU）决定：
引擎做一次 memory profiling，把「GPU 上还剩多少」乘上利用率，剩下的给 KV cache。
在这种模式下，**同一个 GMU 在不同起服之间会给出差别很大的 KV 池**
（实测同一配置下池量在 1,257,647 到 2,761,867 之间浮动，**±31%**），
取决于起服瞬间的页缓存与碎片状态 —— 这让「KV 达标」不可复现。

### 3.2 设了 KVB 之后发生什么

**只要设了 `--kv-cache-memory-bytes`，引擎就跳过 memory profiling，KV 直接取该字节数。**

⇒ `--gpu-memory-utilization` **降级为一个启动前置校验**，不再参与分配。

这条结论有源码级证据（取值分支 + 起服日志两处互证），也有**反例实测**：

| 实验 | GMU | KVB | 结果 |
|---|---|---|---|
| 基线 | 0.80 | 7.0e9 | KV **1,943,028** |
| 只降 GMU | **0.78** | 7.0e9 | KV **1,943,028**（**一字不差**） |

**GMU 拧到底，KV 一点没变。** 而把 KVB 从 7.0e9 降到 5.9e9 ⇒ KV 从 1,943,028 降到 **1,722,343**
（与预测的 −1.024 GB 误差 2.5%）。这就是「谁是旋钮」的对照。

> ⚠️ **所以「降 GMU 换余量」是无效操作**。要换余量，改 KVB。
> 这条反直觉结论本身值得记住：**在花小时级机时跑 A/B 之前，先花几分钟确认「这个旋钮真的接在待测链路上吗」**。

### 3.3 KV 是可复现的（设了 KVB 之后）

| MAXB | boot 1 | boot 2 | 结论 |
|---|---|---|---|
| 4096 | **1,637,699** | **1,637,699** | 逐位一致 |
| 2048 | **1,722,343** | **1,722,343** | 逐位一致 |

⇒ 设了 KVB 之后，**KV 由 (KVB, MAXB) 决定，逐 boot 逐位可复现**。
此前记录的「同配置跨 boot KV ±31%」是**没设 KVB 时的分配抽签**，那条结论**已被推翻**。

### 3.4 容量账（本配置）

| 项 | 值 |
|---|---|
| KV 池 | **1,722,343 tokens** |
| 并发倍数（相对 749568） | **2.30×** |
| `num_gpu_blocks` | 42,679 |
| KV 内存预算 | 5,900,000,000 B |

---

## 4. 为什么 `--max-num-batched-tokens` 取 2048（而且与 KVB 成对）

| MAXB | KV tokens | 深闲时 head 最低余量 | prefill |
|---|---|---|---|
| **2048** | **1,722,343**（+5.2%） | **7,338 MB** | 略慢 |
| 4096 | 1,637,699 | 4,523 MB | 略快（+0.5%…+3.7%） |
| 8192 | — | — | **明显更慢（−5.3%…−11.5%）** |

- **decode 吞吐分不出**（A/B 交替 4 boot 的配对差落在 boot 间极差内；C1 的方向随口径翻转）。
- **KV 多 5.2%、余量多约 2.8 GB** —— 在「零 wedge 是第一约束」的前提下，这比 3% 的 prefill 差更值钱。
- **8192 是真差的一档**，不要用。

### ⚠️ 成对关系（这一条最容易改错）

**GMU 与 KVB 是成对的。**

- 设了 KVB ⇒ 跳过 profiling ⇒ **GMU 只剩启动校验**。
- **不设** KVB ⇒ 回到 profiling ⇒ **此时 GMU 才是容量旋钮**。

⇒ **只把 GMU 从 0.82 降到 0.80 而 KVB 仍为空，KV 池会比原来更小。**
所以「降 GMU」与「设 KVB」必须**一起改**，不能单改一个。

---

## 5. 参数单一真源

**把参数集中到一个环境文件里，脚本只读它。**

```bash
# <PARAM_ENV_FILE>（变量名按你的脚本约定，这里用无前缀的短名）
GMU=0.80
KVB=5900000000
MAXB=2048
WARM=300000,614400
```

优先级约定：**显式传的环境变量 > 真源文件 > 脚本内默认值**。

两处踩过的坑：

| 坑 | 现象 | 处置 |
|---|---|---|
| 真源文件带 CRLF | 参数读成 `0.80\r`，整个参数被污染 | 推送前后核 `tr -cd '\r' | wc -c` 为 `0` |
| 生成器覆盖 launcher | 有的脚本会从 `.new` 模板生成 launcher，**模板落后就会把现役参数回退** | 改 launcher 后**必须**把 `.new` 同步为同一份内容；更好的是加**阻断式门闩**（不一致就拒绝覆盖） |

**推荐做法**：起服脚本在**缺真源文件时 `exit` 而不是用内置默认值** ——
「宁可起不来，也不要静默用错值」。唯一例外是安全网脚本：它缺文件时应该**告警 + 回退默认**，
因为**安全网绝不能因为缺配置文件而失效**。

---

## 6. `--moe-backend b12x`

- 引擎的 `moe_backend=auto` **不会**自动选中 `b12x`（源码里明写需要「显式 opt in」）。
- 上游实测 `b12x` 比默认后端快 **10.2%–12.7%**。
- ⚠️ **正确值是 `b12x`**，不是一个带前缀的近亲名字 —— 那个名字是给**另一种量化格式**用的，
  在本模型的量化格式下会直接报 `ValueError`。

---

## 7. 投机解码与 CUDA graph

| 参数 | 取值 |
|---|---|
| 方法 | `dspark`，`num_speculative_tokens = 5` |
| 自适应验证 | `false` |
| cudagraph 模式 | `FULL_AND_PIECEWISE` |
| **capture sizes** | `5,6,10,12,15,18,20,24,25,30,35,36,40,42,48` |

**capture sizes 必须逐个显式列出**：这些是 **decode-batch 的 token 数**
（≈ `num_seqs × (k+1)`），与 `max-model-len` 无关。
上游有实测：一个「看起来很自然」的值（42）会被**静默截断到 40**，在并发 6 时造成 **−12%** 的损失 ——
所以 40 与 42 **都要在表里**。

---

## 8. Engram 落盘开关

| 环境变量 | 取值 | 作用 |
|---|---|---|
| `ENGRAM_DISK` | `1` | 开启 Engram SSD offload |
| `ENGRAM_LOCAL` | `1` | 用节点本地行（而非共享存储） |
| `ENGRAM_THREADS` | `32` | 读线程数 |
| `ENGRAM_CHUNK` | `16` | 分块大小 |

对应的补丁与挂载见 [`docs/04`](04-patch-set.md)。

---

## 9. NCCL 与集合通信

| 变量 | 取值 |
|---|---|
| `NCCL_NET` | `IB` |
| `NCCL_IB_HCA` | `rocep1s0f0,roceP2p1s0f0`（两个逻辑口） |
| `NCCL_SOCKET_IFNAME` | `enp1s0f0np0,enP2p1s0f0np0` |
| `GLOO_SOCKET_IFNAME` / `TP_SOCKET_IFNAME` | `enp1s0f0np0` |
| `NCCL_NVLS_ENABLE` | **0**（本硬件无 NVSwitch） |
| `NCCL_CROSS_NIC` | 1 |
| `NCCL_IB_MERGE_NICS` | 0 |
| `NCCL_CUMEM_ENABLE` | 0 |
| `NCCL_MAX_NCHANNELS` / `MIN_NCHANNELS` | 8 / 4 |
| `NCCL_IB_TC` | 106 |
| `NCCL_BUFFSIZE` | **1048576** |
| `NCCL_LL128_BUFFSIZE` | **262144** |
| `NCCL_PROTO` | `^LL128`（排除 LL128，省缓冲） |

### 为什么显式把缓冲调小

上游实测：NCCL 曾**每节点分配 512 × 9.19 MiB = 约 4.7 GiB 的 pinned host 内存**
（表现为不可回收的共享内存）。把上面三项调小后压到**约 139 MB**，
直接换回约 **6 GB** 可用内存。

**在统一内存机上，「内存就是速度」** —— 一个通信库的默认缓冲就能决定你能不能开长上下文。

---

## 10. 容器参数

```text
--network host --ipc host
--shm-size 32g
--memory 112g --memory-swap 112g
--ulimit memlock=-1:-1
--cap-add IPC_LOCK
--device /dev/infiniband:/dev/infiniband
--oom-score-adj 500
--gpus all
```

外加：

| 挂载 | 用途 |
|---|---|
| `<MODEL_DIR>` → 容器内模型路径（**只读**） | 权重 |
| 缓存目录 → `/cache`（**可写**） | 编译/内核缓存，避免每次重建重编 |
| entrypoint 脚本（**只读**） | 启动入口 |
| 7 条补丁（**只读**） | 见 [`docs/04`](04-patch-set.md) |
| Engram 本地目录（**只读**） | 见 [`docs/03`](03-model-preparation.md) |

### 显存分配器

`PYTORCH_CUDA_ALLOC_CONF=expandable_segments:True`

> ⚠️ **两个来源结论相反**：有公开结论称在某引擎上开启会导致
> 「超过 64 query token 的 prefill 返回 NaN logits」；
> 但在本 vLLM 线上实测**关闭它会显著缩小 KV 池（约 −25%）**。
>
> ⇒ 本指南取**开启**，并在验收里加一条**长 prefill 正确性检查**（[`docs/08`](08-verification.md)）。
> 这是「不同引擎不能互搬结论」的一个实例 —— 换引擎时必须重新实测。

### 缓存与超时

| 环境变量 | 取值 | 用途 |
|---|---|---|
| `VLLM_ENGINE_READY_TIMEOUT_S` | `3600` | 加载 475 GiB 检查点要很久 |
| `VLLM_EXECUTE_MODEL_TIMEOUT_SECONDS` | `1800` | 长 prefill 会跑很久 |
| `VLLM_ALLOW_LONG_MAX_MODEL_LEN` | `1` | 允许超长窗 |
| `HF_HUB_OFFLINE` / `TRANSFORMERS_OFFLINE` | `1` | 离线，避免意外联网 |
| `MAX_JOBS` | `2` | **限制编译并行**（编译风暴是 wedge 主因） |
| 编译缓存目录 env | `/cache/...` | 挂在可写卷上 |

---

### 关于鉴权

引擎支持 `--api-key` 参数，也支持从一个**只读文件**读取（例如通过一个 `API_KEY_FILE` 之类的
环境变量指向该文件）。**本文不给任何具体值，也不给任何本机路径。**

⚠️ 两点注意：

1. 以命令行参数注入时，容器的参数列表里会**明文可见**（`docker inspect` 就能看到）。
   要降低暴露面，优先用「从只读文件读」的方式。
2. 引擎日志会回显完整的服务端参数。**排障时不要把引擎日志全文外发。**

---

## 11. 模型加载与超时预算

| 阶段 | 典型耗时 | 备注 |
|---|---|---|
| 权重加载 | **约 9 分钟起** | 四台并行读 |
| 装权 + CUDA graph 捕获 | 到 READY 约 **15–21 分钟** | 冷启动请按 **约 21 分钟**留余量，**不要 8 分钟就判失败** |

---


## 12. 参数检查清单

- [ ] `--max-model-len` 覆盖「prompt + 输出 + 余量」
- [ ] 设了 `--kv-cache-memory-bytes`（**否则 KV 不可复现**）
- [ ] **GMU 与 KVB 一起改**（不要单改 GMU）
- [ ] `--max-num-batched-tokens` = 2048（不要用 8192）
- [ ] `--moe-backend` 拼写正确（`b12x`）
- [ ] capture sizes **逐项列出** 40 与 42
- [ ] NCCL 缓冲三项已调小
- [ ] `MAX_JOBS=2`（限制编译并行）
- [ ] 端口不是 `8000`、master port 不是 `29500`
- [ ] 参数真源文件是 LF、无 CR
- [ ] 参数真源单一（脚本内不再留一份会静默生效的默认值）
- [ ] 起服后 `docker inspect` 打印**实际生效**的三个关键参数并与预期核对
