# 04 · 补丁集

**这篇讲什么**：这套部署需要挂哪些补丁、每个补丁解决什么问题、归属是谁、以及**如何自行获取**。本文**不包含补丁源码**（版权与体积原因）。

---

## 1. 为什么需要补丁

本模型在 GB10（SM12x）上有三类「没有补丁就跑不起来」的问题，全部来自**新硬件 + 新模型**的组合：

1. **页尺寸契约不匹配**：模型的 attention 后端声明支持的 block size 集合与引擎默认取值取不到交集，
   直接报 `No common block size for N`。
2. **稀疏注意力内核的约束**：某条 indexer 路径只接受 32 或 64 states/block，而该模型是 ratio 1/2。
3. **大表必须离 GPU**：Engram n-gram 表占全权重的 40%（见 [`docs/03`](03-model-preparation.md)），
   必须走 SSD offload；而引擎默认既不会跳过这两张表、也不会在正确的时机预取它们。

这三类都**不是**「调参能绕开」的，所以必须打补丁。

---

## 2. 归属与出处

**补丁不是本指南作者写的。** 它们来自公开的社区工作，请按原出处引用与遵守其许可：

| 来源 | 关系 |
|---|---|
| **`tonyd2wild/DeepSeek-V4.1-Flash-vLLM-DGX-Spark`** | vLLM 线的 4×Spark 配方；**下表中 7 个补丁的原始出处**（含 `patch/` 目录与 md5 表）；`bench/v41bench.py` 基准脚本；boot1–10 的失败史 |
| **`Kai`** | `attention.py` 中 **SM12x 页尺寸**部分的思路 |
| **`MiaAI-Lab`** | NCCL 连接缓冲与显存分配器相关的实测结论（见 [`docs/06`](06-launch-parameters.md)） |
| 上游预构建镜像（示例） | `aidendle94/sparkrun-vllm-dsv41-gb10:production-1.0` |

**2026-09-14 起**：本仓库 [`patch/`](../patch/) 已包含七个补丁与 `mounts.txt`，可直接拷到四台 `<PATCH_DIR>`。仍建议与 [Tony 上游](https://github.com/tonyd2wild/DeepSeek-V4.1-Flash-vLLM-DGX-Spark) md5 表互核。

---

## 3. 补丁清单（文件名 / 挂载到哪 / 修什么）

挂载目标根目录记作 `<SITE>`（容器内的 `vllm` 包目录，例如
`/usr/local/lib/python3.12/dist-packages/vllm`）。表中「相对路径」都是相对 `<SITE>`。

| # | 补丁文件 | 挂载到（相对 `<SITE>`） | 修什么问题 |
|---|---|---|---|
| 1 | `sparse_swa.py` | `v1/attention/backends/mla/sparse_swa.py` | 增加 `get_swa_block_size()` 钩子，让 SWA 页尺寸可被上层正确解析 |
| 2 | `attention.py` | `models/deepseek_v4_1/attention.py` | **SM12x 页尺寸**（Kai）+ indexer 64-state 页；修正 `_o_proj` 的 block size 判定 |
| 3 | `flashinfer_sparse.py` | `models/deepseek_v4_1/nvidia/flashinfer_sparse.py` | SM12x 的 64-state 压缩页 + 64-token SWA 后端 |
| 4 | `engram.py` | `models/deepseek_v4_1/common/engram.py` | Engram **落盘**、**rank-offset 修复**、共享并行读池、`EngramDiskStager`、节点本地行 |
| 5 | `weight_utils.py` | `model_executor/model_loader/weight_utils.py` | 让 loader **跳过**两张 Engram 表（它们不走 GPU） |
| 6 | `model_state.py` | `models/deepseek_v4_1/nvidia/model_state.py` | Engram 行在 `prepare_inputs` 里**预取**，即**在 CUDA-graph 捕获的 forward 之前** |
| 7 | `sparse_attn_indexer.py` | `model_executor/layers/sparse_attn_indexer.py` | SM12x 的 decode top-k 改走 `top_k_per_row_decode`（绕开在某机宽 logits 下会崩的另一条路径） |

**归属**：#2 的页尺寸部分归 **Kai**；其余归 `tonyd2wild` 仓的 `patch/`（其中 Engram 的本地行适配起于 `0xSero`）。

### 第 7 条为什么关键

另一条路径（`persistent_topk`）有一个硬件红线：
**一行需要的 block 数超过本机的 SM 数时失败**，而它的回退路径需要 **128 KB 共享内存/块**，
本机只有 **99 KB**。

⇒ 在很宽的 logits 下，一个中等长度的请求就能把机器打死。
第 7 条补丁把 SM12x 上的条件改成**无条件**走另一条实现，从而绕开它。

⚠️ **但要注意验证边界**：上游实测该替代实现在 **300K 行宽以内**与参考实现精确一致；
**300,000 以上未验证**。所以把上下文开到 600K 时，这一条属于**未验证区**，
必须当**风险实验**做（见 [`docs/08`](08-verification.md)）。

---

## 4. 挂载机制（mounts.txt）

补丁**不是**打进镜像的，而是**运行时 bind mount 覆盖**。这样容器重建后补丁仍在。
（⚠️ 前提是**经脚本重建**：手工 `docker run` 不会读这份清单，补丁会**静默丢失**。）

### 清单文件格式

`mounts.txt` —— 每行两个字段，**半角空格**分隔：

```text
sparse_swa.py v1/attention/backends/mla/sparse_swa.py
attention.py models/deepseek_v4_1/attention.py
flashinfer_sparse.py models/deepseek_v4_1/nvidia/flashinfer_sparse.py
engram.py models/deepseek_v4_1/common/engram.py
weight_utils.py model_executor/model_loader/weight_utils.py
model_state.py models/deepseek_v4_1/nvidia/model_state.py
sparse_attn_indexer.py model_executor/layers/sparse_attn_indexer.py
```

| 字段 | 含义 |
|---|---|
| 第 1 列 | `<PATCH_DIR>` 下的文件名 |
| 第 2 列 | 相对 `<SITE>` 的目标路径 |

行内**不要**写 `:ro`、不要写前缀 —— 脚本会拼成：

```
-v <PATCH_DIR>/<第1列>:<SITE>/<第2列>:ro
```

### 三个必须知道的细节

| 细节 | 说明 |
|---|---|
| **只在 head 被读** | 清单在 head 上被解析并展开成完整的 `docker run`；展开后的命令再经 `ssh` 发到三台 worker |
| **但补丁文件四台都要有** | 因为 `-v` 的**源路径是各节点本地路径**，worker 上不存在就会挂成空目录 |
| **文件必须 LF、末尾带回车** | 带 CRLF 会让第 2 列变成 `…\r`，挂载路径就错了。推完用 `cat -A` 看一眼每行结尾是 `$` |

### 可选行的条件跳过

若关闭 Engram 落盘（`ENGRAM_DISK != 1`），第 4/5/6 行（`engram.py` / `weight_utils.py` / `model_state.py`）
应被跳过 —— 否则会挂上一个与当前模式不匹配的实现。

### 验证挂载真的生效

```bash
docker inspect <容器名> --format '{{json .Mounts}}' | python3 -m json.tool
# 逐条确认：RW=false、Source 是本地补丁文件、Destination 是容器内目标路径
# 再确认目标是【普通文件】而不是空目录：
docker exec <容器名> stat -c '%F %s' <SITE>/models/deepseek_v4_1/common/engram.py
```

**「挂载点存在」不等于「补丁生效」**：如果 `Source` 写错，docker 会创建一个空目录，
`docker inspect` 看起来仍然「有 7 条 mount」。**必须核容器内目标是普通文件且尺寸与宿主端一致。**

---

## 5. 如何自行获取补丁

1. 打开上游仓 `tonyd2wild/DeepSeek-V4.1-Flash-vLLM-DGX-Spark`。
2. 取它的 `patch/` 目录：里面是 7 个 `.py`/`.diff` 文件 + 一份 `mounts.txt` + 一份带 md5 的 `README`。
3. **逐个核 md5**：上游 README 给了每个文件的 md5。你拿到的文件必须与之一致。
4. 若上游更新了版本，**先读它的 commit 说明**再决定是否跟进 —— 补丁与引擎版本是绑定的。

```bash
# 取到后本地核一遍（与上游 README 的 md5 表对照）
for f in *.py; do md5sum "$f"; done
wc -l mounts.txt
```

### 关于「多加一个补丁」

若你要**在 7 个之外再加一个补丁**（例如覆盖某个 tokenizer/编码模块）：

1. 把新文件放进 `<PATCH_DIR>`；
2. 在 `mounts.txt` **追加一行**（文件名取一个不含路径分隔符的别名，第 2 列写真容器路径）；
3. **同步更新预检的 md5 清单** —— 见 [`docs/05`](05-preflight.md)，
   这里有**一个必踩的坑**：预检把 `mounts.txt` 自己也钉了 md5，所以「加一行」会让清单失配。
4. 重建容器，并**发一个最小请求**验证。

---

## 6. 补丁集检查清单

- [ ] 7 个补丁文件在**四台**的 `<PATCH_DIR>` 下都存在
- [ ] 每个文件是 LF、无 CR
- [ ] 每个文件的 md5 与上游 README 表一致
- [ ] `mounts.txt` 是 7 行、LF、末尾有换行
- [ ] `docker inspect` 显示 7 条 `RW=false` 的 patch mount
- [ ] 容器内 7 个目标都是**普通文件**且尺寸与宿主端一致
- [ ] 若新增了补丁：预检清单已同步（否则起服会被门禁拦下）
