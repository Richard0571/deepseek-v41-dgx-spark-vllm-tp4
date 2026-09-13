# DGX Spark ×4 · TP4 大模型推理部署指南

本指南讲一件事：**如何在 4 台 NVIDIA DGX Spark（GB10）上用 vLLM 的 TP4（张量并行 4 路）跑起一个大 MoE 模型**，
并把上下文开到 60 万 token 级别（600K）时**不把机器打死**。

这里的核心难点不是「怎么把服务拉起来」——那是社区配方已经解决的部分。真正难的是**统一内存**：
GB10 的 host 内存与 GPU 内存是**同一块**，所以「模型权重 + KV cache + 激活」全挤在一个池子里，
一旦触顶，机器会进入一种**只能断电恢复**的失效状态（本文称之为 **wedge**）。
本指南把「怎么起服」「怎么留足余量」「怎么在触顶前主动干预」三件事写成可照做的步骤。

> 本文用 **DeepSeek-V4.1-Flash** 作为实例模型（权重路径一律写 `<MODEL_DIR>`，可替换为任意同构 MoE 检查点）。
> 除实例参数外，拓扑、护栏、哨兵、预检、验收、排障各节与具体模型无关。

---

## 这套东西解决什么问题

| 问题 | 本指南给的答案 |
|---|---|
| 4 台机器怎么连、地址怎么排 | 独立 RoCE 网段 + 交换机一分二接线（[`docs/01`](docs/01-hardware-topology.md)） |
| 统一内存为什么会「假死」 | wedge 的成因与判据（[`docs/07`](docs/07-memory-safety.md)） |
| 触顶前怎么自动止损 | 宿主侧两相位内存哨兵（[`docs/02`](docs/02-host-preparation.md)、[`docs/07`](docs/07-memory-safety.md)） |
| 一个 500 GB 的模型怎么铺到 4 台 | 分片、Engram 离 GPU、局域网分发（[`docs/03`](docs/03-model-preparation.md)） |
| 为什么还需要一堆补丁 | 补丁意图与挂载机制（[`docs/04`](docs/04-patch-set.md)） |
| 起服前该拦什么 | 预检门禁与 md5 清单（[`docs/05`](docs/05-preflight.md)） |
| 参数为什么取这些值 | 逐项取值依据，含「GMU 是空转旋钮」这类反直觉结论（[`docs/06`](docs/06-launch-parameters.md)） |
| 怎么确认真的成了 | 从 `/health` 到 600K 请求的完整验收（[`docs/08`](docs/08-verification.md)） |
| 出事了怎么退 | 回滚（[`docs/09`](docs/09-rollback.md)） |
| 踩过的坑 | 真实事故复盘（[`docs/10`](docs/10-troubleshooting.md)） |
| 数字怎么算靠谱 | 测量纪律（[`docs/11`](docs/11-measurement-notes.md)） |

---

## 需要什么硬件

| 项 | 要求 |
|---|---|
| 节点 | **4 × NVIDIA DGX Spark**（GB10，统一内存约 128 GB / 121.7 GiB） |
| 高速互联 | 每台 1 张 ConnectX-7（multi-host 模式），每张 2 个逻辑口 |
| 交换机 | 1 台带 400G 笼的以太网交换机（示例：MikroTik CRS812） |
| 线缆 | 2 根「400G QSFP-DD → 2×200G」一分二被动铜缆 |
| 本地盘 | 每台 ≥ 4 TB NVMe（放权重与 Engram 表） |
| 网络规划 | 高速口用独立网段（本文示例 `10.100.24.0/24`），管理口 DHCP |

**最小可用规模是 4 台。** TP4 要求四台同时在线、同路径、同镜像；少一台服务起不来。

---

## 5 步快速开始

> 下文命令中 `<...>` 为需替换的占位符。所有命令在 head 节点（本文记作 `spark-01`）执行，除非标注 `每台`。

### 第 1 步 · 网络与地址就位

```bash
# 在每台确认高速口地址与链路速率
ip -4 -br addr show | grep -E '10\.100\.'
for i in 1 2 3 4; do ssh spark-0$i "cat /sys/class/net/enp1s0f0np0/speed"; done
```

期望：四台高速口地址与 [`docs/01`](docs/01-hardware-topology.md) 的地址表一致，口速 `200000`（Mb/s）。
⚠️ **高速口的编号顺序与节点编号顺序不一致**，写脚本前必读地址表。

### 第 2 步 · 内存护栏与哨兵

```bash
# 每台：内核护栏（持久化）。以下两步需要 root 权限。
install -m 644 /dev/stdin /etc/sysctl.d/99-tp4-guard.conf <<'EOF'
vm.min_free_kbytes = 1048576
vm.watermark_scale_factor = 200
EOF
sysctl --system && sysctl vm.min_free_kbytes vm.watermark_scale_factor

# head：起宿主侧哨兵（详见 docs/02）
bash /home/<USER>/memguard.sh start <容器名> 1024 2 5.0 60.0
```

⚠️ **绝对下限必须是 1024 MB，不要照抄成 8192 MB** —— 本配置的稳态余量本就只有几 GB，8192 会在几秒内误杀。
理由见 [`docs/07`](docs/07-memory-safety.md)。

### 第 3 步 · 模型与补丁就位

```bash
# 每台：权重到位（同路径，48 个分片，字节一致）
ls <MODEL_DIR>/*.safetensors | wc -l          # 期望 48
# 每台：Engram 表搬进 NVMe（否则 KV cache 没有空间）
# 见 docs/03
# 每台：补丁文件放到 patch 目录（从上游获取，见 docs/04）
ls <PATCH_DIR>/*.py && wc -l <PATCH_DIR>/mounts.txt
```

### 第 4 步 · 预检

```bash
# 在 head：dry-run 先看命令长什么样，再跑门禁
bash <LAUNCHER> --dry-run
bash <LAUNCHER> --self-test        # 证明 JSON 参数没被 shell 拆坏
bash <PREFLIGHT> --burn            # 预检含一次短时算力 burn
```

门禁全绿才允许起服。清单与失配处理见 [`docs/05`](docs/05-preflight.md)。

### 第 5 步 · 起服与验收

```bash
# head：真正起服（内含装哨兵 + 预检 + 水位门 + 长上下文预热）
bash <BOOT_SCRIPT>
# 验收：健康 → 最小请求 → KV 池断言 → 长上下文
bash <VERIFY_SCRIPT>
```

验收项逐条见 [`docs/08`](docs/08-verification.md)。**`/health` 返回 200 不等于代码没问题**——必须再发一个最小请求。

---

## 文档目录

| 文件 | 讲什么 |
|---|---|
| [`docs/01-hardware-topology.md`](docs/01-hardware-topology.md) | 硬件、RoCE 网段、交换机接线、地址表、实测带宽、散热与功耗 |
| [`docs/02-host-preparation.md`](docs/02-host-preparation.md) | 宿主侧前置：内核内存护栏 + 两相位内存哨兵 |
| [`docs/03-model-preparation.md`](docs/03-model-preparation.md) | 模型准备：分片、Engram 离 GPU、分发、下载纪律 |
| [`docs/04-patch-set.md`](docs/04-patch-set.md) | 补丁集：上游归属、每个补丁修什么、怎么自行获取 |
| [`docs/05-preflight.md`](docs/05-preflight.md) | 起服前门禁：检查项、md5 清单、失配处置 |
| [`docs/06-launch-parameters.md`](docs/06-launch-parameters.md) | 关键参数与逐项取值依据 |
| [`docs/07-memory-safety.md`](docs/07-memory-safety.md) | 统一内存的 wedge 失效模式 + 哨兵阈值为什么这么定 |
| [`docs/08-verification.md`](docs/08-verification.md) | 验收：健康、最小请求、KV 断言、长上下文、并发阶梯 |
| [`docs/09-rollback.md`](docs/09-rollback.md) | 回滚：备份、还原、重建耦合 |
| [`docs/10-troubleshooting.md`](docs/10-troubleshooting.md) | 排障表：真实踩过的坑 |
| [`docs/11-measurement-notes.md`](docs/11-measurement-notes.md) | 测量纪律：跨 boot 不可直比、丢冷样本、口径声明 |
| [`docs/12-engine-runtime-notes.md`](docs/12-engine-runtime-notes.md) | 引擎运行时行为：prefix cache 的真实复用/驱逐、带 tools 时强制保留历史思考 |

---

## 一条最重要的纪律

**这套系统的失效模式是「机器假死」，不是「进程报错」。** 所以本文所有流程都遵守两条硬规则：

1. **单机先行**：任何新参数组合，先在 1 台上跑通，再上 4 台。四台同时起新配置的代价可能是 4 台一起断电。
2. **无哨兵不起服**：宿主侧内存哨兵是最后一道保险。哨兵没起来，就不许起容器。

其余纪律见 [`docs/07`](docs/07-memory-safety.md) 与 [`docs/11`](docs/11-measurement-notes.md)。

---

## 数字口径

本文所有数字都标来源等级：

- **A 级**：实测（能指出哪条命令 / 哪行日志）
- **B 级**：引用他人测量（标来源与日期，注明「未自测」）
- **C 级**：推算（写出算式与全部输入）
- **D 级**：未核验（不作结论依据）

未标注者默认为 **A 级**。跨 boot 的数字只可看数量级，不可直接对比 —— 详见 [`docs/11`](docs/11-measurement-notes.md)。

---

## 上游与致谢

本指南的 vLLM 侧配方建立在公开的社区工作之上，主要来源：

- **`tonyd2wild/DeepSeek-V4.1-Flash-vLLM-DGX-Spark`** —— vLLM + DSpark + Engram 的 4×Spark 配方、
  七个补丁的原始出处、`v41bench.py` 基准脚本、以及 boot1–10 的失败史。
- **`MiaAI-Lab`** —— NCCL 连接缓冲与显存分配器相关的实测结论。
- **`Kai`** —— SM12x 页尺寸相关的补丁思路。
- 上游预构建镜像（示例）：`aidendle94/sparkrun-vllm-dsv41-gb10:production-1.0`。

具体到文件级的归属见 [`docs/04-patch-set.md`](docs/04-patch-set.md)。

---

## License

MIT —— 见 [`LICENSE`](LICENSE)。版权行中的占位符请按你的实际情况替换；
若你的项目需要其它许可（例如沿用上游补丁的许可），可直接替换本文件。
