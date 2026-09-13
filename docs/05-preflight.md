# 05 · 起服前门禁（preflight）

**这篇讲什么**：容器创建之前必须先过的自动检查，以及**清单里那个自指的坑**（把 manifest 自己也钉了 md5）。门禁存在的意义是：把「起服后 20 分钟才发现不对」变成「起服前 30 秒就拦住」。

---

## 1. 门禁查什么

预检脚本在**四台**上各跑一遍，然后汇总。判据与失败处置：

| # | 检查项 | 期望 | 不过怎么办 |
|---|---|---|---|
| 1 | 内核内存护栏 | `min_free_kbytes=1048576`、`watermark_scale_factor=200` | 补护栏（[`docs/02`](02-host-preparation.md)），不要跳过 |
| 2 | 镜像同一性 | **四台层列表 hash 完全一致** | 重新分发镜像；不要按「镜像 ID」判，要按**层列表 hash** |
| 3 | 补丁 md5 清单 | 四台都 `N/N` | 见第 2 节（**这是最容易踩的**） |
| 4 | 内存水位 | `MemAvailable` ≥ 门槛 | 先回收页缓存（[`docs/02`](02-host-preparation.md) §7），不要硬上 |
| 5 | 哨兵在岗 | 四台都有对应容器的哨兵进程 | 起哨兵；**没哨兵不许起服** |
| 6 | 端口`8000` 未被占用 | 必须 **0 个**监听 | 有别的服务在跑 ⇒ 停掉它，或换端口 |
| 7 | **算力 burn** | 四台各做 10 s fp16 burn，**低于 50 TFLOPS 拒绝起服** | 说明 GPU 处于 latch 慢态 ⇒ 见第 4 节 |
| 8 | 备用数据/挂载 | NFS、节点本地 Engram 副本、跨节点 md5 一致 | 补数据 |

### 第 2 条为什么按「层列表 hash」而不是「镜像 ID」

同一份镜像在不同节点上 `docker inspect` 出来的顶层 ID 可能不同（构建/解包差异），
但**层列表**是一致的。按层列表 hash 判同一性，能既抓住真漂移、又避免误报。

```bash
docker inspect <镜像> --format '{{range .RootFS.Layers}}{{.}}{{"\n"}}{{end}}' | sha256sum
```

四台的这个 hash 必须相同（实测示例：47 个层）。

### 第 3 条为什么容易踩

补丁的 md5 清单长这样（示意）：

```
<md5> sparse_swa.py
<md5> attention.py
<md5> flashinfer_sparse.py
<md5> engram.py
<md5> weight_utils.py
<md5> model_state.py
<md5> sparse_attn_indexer.py
<md5> mounts.txt          ← ⚠️ 注意这一行
```

**清单把 manifest 文件（`mounts.txt`）自己也钉了。**
清单里钉的值是「7 行版」的 md5。

---

## 2. ⚠️ 那个自指的坑：加一个补丁 = 清单必然失配

这是一个**结构性耦合**，不是 bug —— 但不知道它的人一定会撞。

- 预检脚本：从 `<PATCH_DIR>/mounts.txt` **逐条读清单并校验 md5**（含 `mounts.txt` 自己那一条）。
- 起服脚本：从**同一个** `mounts.txt` **生成 `-v` 挂载**。

⇒ 你要加一个补丁，就得往 `mounts.txt` 加一行 ⇒ 它的 md5 必然变 ⇒
**清单里钉住的那个值必然失配** ⇒ 门禁 `FAIL` ⇒ 四台容器**不放** ⇒ 服务中断。

### 现场实录（失败形态）

```
=== gates
  WARN 10.100.24.4 no memguard watch for '<容器名>' yet
  PASS 10.100.24.3 memguard watching '<容器名>'
  PASS 10.100.24.1 memguard watching '<容器名>'
  PASS 10.100.24.2 memguard watching '<容器名>'
  PASS image layer list identical on all four: layers=47 sha256=...
  FAIL 10.100.24.4 patch md5 7/8 (expect 8/8)     ← 唯一失配
  INFO head :8000 listen=0 (must stay untouched)
=== FAIL — do NOT launch
```

注意两个细节：

1. **只有 head 失配** —— 因为 `mounts.txt` 只在 head 上被改过；三台 worker 还是旧内容 ⇒ 8/8。
2. **新增的那个补丁文件根本没被清单校验** —— 它不在清单里。所以「清单失配」不是因为新文件有问题，
   而是因为**清单自己**变了。

而且这次失败是**破坏性的**：起服脚本在预检之前已经做了清场（`docker rm -f`）⇒ **服务中断**，
且**不会自动恢复**，必须手工回滚再起一次。

### 正确处置

**加补丁时，必须同步更新清单里的那一条**：

```bash
# 1) 备份（改动前必备份；回滚靠备份恢复，不要靠反向编辑）
cp -a <PATCH_DIR>/mounts.txt <PATCH_DIR>/mounts.txt.bak-<日期>-<原因>

# 2) 追加补丁行（用 echo，天然以空格连接参数并加换行）
echo <新文件名> <容器内相对路径> >> <PATCH_DIR>/mounts.txt

# 3) 记下新 md5
md5sum <PATCH_DIR>/mounts.txt

# 4) 把预检脚本里那条 mounts.txt 的期望值改成第 3 步的新值
#    同时更新 <PATCH_DIR>/README 的 md5 表（若有）
```

### 三条可选项（按推荐度）

| 选项 | 做法 | 代价 |
|---|---|---|
| **A（推荐）** | 更新清单里的 `mounts.txt` 期望值，保留**全部**安全门禁 | 一次 boot（约 20–40 分钟服务中断） |
| B | 用起服脚本自带的跳过开关（如 `SKIP_PREFLIGHT=1`） | **绕过整段预检**，包括算力 burn 门。**不建议** |
| C | 放弃本次部署，回滚 | 服务已回基线 |

**更好的长期做法**：把 `mounts.txt` 从清单里**删掉**，改为校验「第 1 列列出的文件是否都存在且 md5 正确」——
即让清单不再自指。这样加补丁就不需要动门禁。

---

## 3. 保留的钩子：dry-run 与 self-test

起服脚本应支持「只看不跑」：

```bash
bash <LAUNCHER> --dry-run      # 打印将要执行的命令，不创建容器、不碰 GPU
bash <LAUNCHER> --self-test    # 证明 JSON 参数经 shell 重解析后没被拆坏
```

`--self-test` 很重要：整条命令会被 `ssh` 和 `bash -c` **重新分词一次**，
bare quote 会被剥掉、逗号会被大括号展开。所以 JSON 参数必须**自带单引号**。
self-test 的做法是把自己的 argv 用 shell 重新解析后逐个打印，并断言几个 JSON 字面量仍完整。

⚠️ **dry-run 本身有一个安全问题**：如果命令里用了 `-e KEY="$(cat <密钥文件>)"`，
dry-run 的输出会带明文。**不要把 dry-run 输出落盘、转发或贴到任何地方**（详见 [`docs/10`](10-troubleshooting.md)）。

---

## 4. 算力 burn 门（防「latch 慢态」）

**动机**：GPU 时钟可能进入一个「latch（锁死）= 慢态」，
频率掉到约 **700–950 MHz**（正常约 **2171–2190 MHz**，上限 2200 MHz）。
这种状态下**一切都会正常跑，但所有性能数字都会被静默污染**。

**做法**：四台各做约 10 秒的 fp16 burn，测 TFLOPS。

| 判据 | 值 |
|---|---|
| 健康基线 | **75–90 TFLOPS**（2.2–2.4 GHz，≥80 W） |
| latch 态 | 约 700–950 MHz |
| **门禁阈值** | **< 50 TFLOPS ⇒ 拒绝起服** |

⚠️ 解除 latch 通常需要**断电**（不是重启）。这是一个物理动作，**不要自行安排**。

---

## 5. 预检失败后怎么办

1. **不要重试同一套参数** —— 先读日志，定位是哪一条 `FAIL`。
2. **head 失配 + worker 正常** ⇒ 十有八九是第 2 节的 `mounts.txt` 耦合。
3. **回滚到可起服状态**（[`docs/09`](09-rollback.md)），先把服务拉回来。
4. 修好清单，**再**安排一次新的起服窗口。
5. 记录：失败形态、根因、是否已修 —— 写进你项目的排障账。

---

## 6. 门禁检查清单

- [ ] 四台 `sysctl` 运行时值正确
- [ ] 四台镜像层列表 hash 相同
- [ ] 四台补丁 md5 均 `N/N`（N = 7 + manifest）
- [ ] 四台 `MemAvailable` 过门槛
- [ ] 四台哨兵在岗（且 pidfile 与 `ps` 一致）
- [ ] `:8000` 无监听
- [ ] 四台 burn ≥ 50 TFLOPS
- [ ] `--dry-run` 输出与预期参数一致
- [ ] `--self-test` 返回 PASS（JSON 未被拆坏）
- [ ] dry-run 输出**未落盘**
