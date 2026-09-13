# 09 · 回滚

**这篇讲什么**：在改动之前先留下什么、改动之后怎么退回去，以及**独占声明必须释放**（不释放会卡住后续所有流程）。

---

## 1. 改动前的三个动作

### 1.1 独占声明（同一批节点同时只允许一个编排者）

两个编排者同时操作同一批节点，会互相毁数据、互相覆盖状态。**起服 / 长跑前先检查、先声明。**

```bash
# 1) 检查有没有别的编排在跑
ps -eo pid,ppid,etime,args | grep -E "launch|bench|longctx|verify|stage[123]" | grep -v grep

# 2) 写独占声明（含 pid、标签、起止时间）
cat > /tmp/CLAIM-<标签>.txt <<EOF
label=<标签>
host=$(hostname)
time=$(date -u +%FT%TZ)
pid=$$
EOF

# 3) 同时 touch 守护脚本的 hold 文件（让它在本轮巡检时跳过动作）
touch /tmp/<GUARD>.hold
```

### 1.2 备份（每个要改的文件都留一份带原因与日期的备份）

```bash
cp -a <文件> <文件>.bak-<YYYYMMDD>-<原因>
md5sum <文件>.bak-<YYYYMMDD>-<原因>       # 记下备份的 md5
```

**备份命名必须带日期 + 原因**。只写 `.bak` 会在第二次改动时被覆盖，
回滚时你不知道退回的是哪一个版本。

### 1.3 记录指纹

对每个要改的文件记下 `md5sum` 与 `wc -l`。改完后**立刻复核**：

```bash
md5sum <文件>   # 应与预期的新值一致
```

> ⚠️ **改大文件必须核对增删行数。** 用数组切片之类的批量写法很容易把文件写坏
> （实测过一次：想插 1 行，结果顶部重复了 5 行）。
> 改完做 `diff --stat` 或 `wc -l` 前后对比，坏了立刻从备份恢复重做。

---

## 2. 按改动类型回滚

### 2.1 补丁 / 挂载

| 场景 | 回滚动作 |
|---|---|
| 只加了补丁文件、**没**改 `mounts.txt` | 删掉新文件即可（它不参与挂载） |
| 改了 `mounts.txt` | `cp -a <PATCH_DIR>/mounts.txt.bak-<日期>-<原因> <PATCH_DIR>/mounts.txt`，**再重建容器** |
| 同时改了预检的 md5 清单 | 一并恢复（否则下次预检仍会拦） |

**回滚靠备份恢复，不要靠反向编辑。** 反向编辑（手工删掉刚加的那一行）
在文件被别处改动过时会产生静默错误。

### 2.2 起服参数

| 场景 | 回滚动作 |
|---|---|
| 改了参数真源文件 | `cp -a <参数文件>.bak-<日期> <参数文件>`；核 **CR 数 = 0** |
| 改了 launcher 脚本 | `cp -a <launcher>.bak-<日期> <launcher>`；然后**必须** `bash -n` 语法检查 |

```bash
# 改完 / 回滚后必做
bash -n <脚本>            # 语法
bash <脚本> --dry-run     # 看生成结果（不要只看脚本本身）
```

### 2.3 哨兵 / 护栏

| 场景 | 回滚动作 |
|---|---|
| 改了哨兵阈值 | `cp -a <哨兵>.bak-<日期> <哨兵>`；用 `status` 确认在岗 |
| 改了 `sysctl` 文件 | 恢复文件 + `sysctl --system` + 复核运行时值 |
| 改了守护脚本（有定时器周期性 exec 它） | ⚠️ 先 `touch` hold 文件，用**原子写**覆盖（临时文件 + `mv`），确认 **CR = 0**，改完再删 hold |

### 2.4 容器

```bash
# 四台一起清场（不要只清一台，会留半死态）
for ip in 10.100.24.4 10.100.24.3 10.100.24.1 10.100.24.2; do
  ssh -n -o BatchMode=yes $ip 'bash /home/<USER>/memguard.sh stop <容器名> >/dev/null 2>&1; \
                               bash /home/<USER>/memguard-load.sh stop <容器名> >/dev/null 2>&1; \
                               docker rm -f <容器名> >/dev/null 2>&1'
done
```

**两个相位的哨兵都要停**（[`docs/02`](02-host-preparation.md) §6）。

---

## 3. ⚠️ 重建的耦合：改了之后「重建 ≠ 生效」

这套部署里有几处**生成器 ↔ 现役文件**的耦合，回滚时特别容易漏：

| 耦合 | 现象 | 处置 |
|---|---|---|
| **生成器模板（`.new`）** | 若 launcher 由模板生成，模板落后 ⇒ 下次生成会把 launcher **打回旧版**（实测曾一次回退 51 行 + 三项安全修复） | 改 launcher 后**必须**把模板同步为同一份内容；更好的是加**阻断式门闩**（内容不一致就拒绝覆盖） |
| **`mounts.txt` 与预检清单** | 见 [`docs/05`](05-preflight.md) §2 | 两者必须一起改 / 一起回滚 |
| **手工 `docker run`** | 补丁**静默丢失**（清单不被读） | 只允许经脚本重建 |

**回滚后必须验证「生成结果」而不是「脚本本身」**：跑一次 dry-run，确认生成的命令里
镜像行、`-e` 行、挂载行、参数都在位。

---

## 4. 回滚后必须做的验证

```bash
# 1) 四台容器在岗
for i in 1 2 3 4; do ssh spark-0$i 'docker ps --format "{{.Names}} {{.Status}}"'; done

# 2) 服务可用
curl -s -o /dev/null -w '%{http_code}\n' http://10.100.24.4:8001/health
curl -s -o /dev/null -w '%{http_code}\n' http://10.100.24.4:8001/v1/models

# 3) 最小请求（防「健康但每个请求 500」）
curl -s http://10.100.24.4:8001/v1/chat/completions \
  -H 'Content-Type: application/json' \
  -d '{"model":"<模型名>","messages":[{"role":"user","content":"只回数字 2"}],"max_tokens":8,"temperature":0}'

# 4) 哨兵在岗 + 参数一致
bash /home/<USER>/memguard.sh status <容器名>
for i in 1 2 3 4; do ssh spark-0$i 'sysctl -n vm.min_free_kbytes vm.watermark_scale_factor | tr "\n" " "; echo'; done

# 5) 记录新 boot 身份
docker inspect <容器名> --format '{{.State.StartedAt}} restarts={{.RestartCount}}'
```

---

## 5. ⚠️ 收尾：释放独占声明（硬要求）

```bash
rm -f /tmp/CLAIM-<标签>.txt
rm -f /tmp/<GUARD>.hold
```

**不释放会卡住后续流程。** 实测过一次：某个流程留下的 hold 文件没被释放，
导致守护脚本每一轮都 `SKIP hold 文件存在`，后续所有编排都被卡住。

收尾自检：

```bash
ls /tmp/CLAIM-*.txt 2>/dev/null && echo "还有未释放的声明" || echo "干净"
ls /tmp/*.hold 2>/dev/null
```

---

## 6. 回滚检查清单

- [ ] 改动前已写独占声明 + hold 文件
- [ ] 每个改动文件都有带日期与原因的备份，且备份 md5 已记录
- [ ] 回滚用**备份恢复**，不是反向编辑
- [ ] 脚本改动后过了 `bash -n` **且**看了 `--dry-run` 生成结果
- [ ] 生成器模板（`.new`）与现役 launcher 同步
- [ ] `mounts.txt` 与预检清单**一起**回滚
- [ ] 四台一起清场 / 重建，无半死态
- [ ] 两个相位的哨兵都停过 / 都重新在岗
- [ ] 服务恢复后做了**最小请求**（不只 `/health`）
- [ ] 新的 `StartedAt` 已记录
- [ ] **独占声明与 hold 文件已删除**
