# flutter_reactive_ble_ohos 鸿蒙社区提交指南

本文说明如何将插件提交/更新到 [openharmony-tpc/flutter_packages](https://gitcode.com/openharmony-tpc/flutter_packages)。

---

## 一、仓库关系

| 用途 | 仓库 | 说明 |
|------|------|------|
| **日常开发 / 开源展示** | https://github.com/mxq1688/flutter_reactive_ble_ohos | 插件源码主阵地 |
| **合入鸿蒙社区** | https://gitcode.com/openharmony-tpc/flutter_packages | 官方大仓，通过 MR 合入 |
| **你的 GitCode Fork** | `git@gitcode.com:qq_22464981/flutter_packages.git` | 从这里向官方提 MR |

当前 MR：**[#796](https://gitcode.com/openharmony-tpc/flutter_packages/merge_requests/796)**（分支 `feat/flutter_reactive_ble_ohos`）

---

## 二、首次 / 重新拉取 Fork

本机没有 `flutter_packages` 时，按下面步骤准备：

```bash
# 1. 克隆你的 Fork
git clone git@gitcode.com:qq_22464981/flutter_packages.git
cd flutter_packages

# 2. 添加上游（官方仓库，用于同步 master）
git remote add upstream https://gitcode.com/openharmony-tpc/flutter_packages.git

# 3. 检出 PR 分支（继续改 #796 时）
git fetch origin
git checkout feat/flutter_reactive_ble_ohos

# 4. 插件目录
# packages/flutter_reactive_ble_ohos/
```

---

## 三、日常流程：改代码 → 提交社区

### 1. 在 GitHub 插件仓开发

```bash
git clone git@github.com:mxq1688/flutter_reactive_ble_ohos.git
cd flutter_reactive_ble_ohos

# 修改 lib/、ohos/、test/、README.md 等
git add .
git commit -m "fix(ohos): 你的修改说明"
git push origin main
```

### 2. 同步到 GitCode Fork

```bash
cd /path/to/flutter_packages
git checkout feat/flutter_reactive_ble_ohos

rsync -av --delete \
  --exclude '.git' \
  --exclude '.dart_tool' \
  --exclude 'SUBMISSION_GITCODE.md' \
  --exclude 'ohos/oh_modules' \
  --exclude 'ohos/build' \
  --exclude 'ohos/libs' \
  --exclude 'ohos/oh-package-lock.json5' \
  /path/to/flutter_reactive_ble_ohos/ \
  packages/flutter_reactive_ble_ohos/
```

> **注意：** `rsync` 目标必须是 `packages/flutter_reactive_ble_ohos/`，不要拷到仓库根目录。  
> **`SUBMISSION_GITCODE.md` 仅保留在 GitHub 插件仓**，不要同步到 `packages/flutter_reactive_ble_ohos/`（社区包不需要该文档）。

### 3. 按 DCO 规范提交并推送

```bash
git add packages/flutter_reactive_ble_ohos/
git status

git commit --author="xianqiang.meng <mxq218@gmail.com>" -m "$(cat <<'EOF'
fix(ohos): 简要说明本次修改

详细说明（可选）。

Signed-off-by: xianqiang.meng <mxq218@gmail.com>
EOF
)"

git push origin feat/flutter_reactive_ble_ohos
```

### 4. 触发 DCO 复检

打开 [MR #796](https://gitcode.com/openharmony-tpc/flutter_packages/merge_requests/796) → 评论框输入 **`check dco`** → 发送。

### 5. 与官方 master 同步（维护者可能要求）

```bash
git fetch upstream
git rebase upstream/master
# 有冲突则在 packages/flutter_reactive_ble_ohos/ 内解决
git push --force origin feat/flutter_reactive_ble_ohos
```

---

## 四、DCO 要求（必看）

| 项 | 要求 |
|----|------|
| 在线签署 | https://gitcode.com/dco ，使用 **mxq218@gmail.com** |
| 每个 commit | 末尾必须有 `Signed-off-by: xianqiang.meng <mxq218@gmail.com>` |
| Author 邮箱 | 建议 `mxq218@gmail.com`，不要用 `mobvoi.com` |
| 复检 | PR 评论输入 `check dco` |

### commit 模板

```
<type>(ohos): 一句话摘要

- 改动点 1
- 改动点 2

Signed-off-by: xianqiang.meng <mxq218@gmail.com>
```

**type：** `feat` / `fix` / `docs` / `chore` / `test`

### 修复 DCO 失败

```bash
# 最新一条 commit 补 signoff
git commit --amend --author="xianqiang.meng <mxq218@gmail.com>" -m "$(cat <<'EOF'
fix(ohos): 说明

Signed-off-by: xianqiang.meng <mxq218@gmail.com>
EOF
)"
git push --force origin feat/flutter_reactive_ble_ohos
```

---

## 五、推送前检查清单

- [ ] 只提交 `packages/flutter_reactive_ble_ohos/` 下文件（不含 `SUBMISSION_GITCODE.md`）
- [ ] 未包含 `ohos/build/`、`.dart_tool/`、`oh_modules/` 等构建产物
- [ ] commit 含 `Signed-off-by: xianqiang.meng <mxq218@gmail.com>`
- [ ] Author 为 `xianqiang.meng <mxq218@gmail.com>`
- [ ] 推送到分支 `feat/flutter_reactive_ble_ohos`
- [ ] PR 评论 `check dco`
- [ ] 可选：`cd packages/flutter_reactive_ble_ohos && flutter test`

---

## 六、MR #796 已包含的变更摘要

| 类型 | 说明 |
|------|------|
| feat | 新增 `flutter_reactive_ble_ohos` 插件（扫描、连接、GATT、读写、通知、MTU、RSSI） |
| fix | 扫描遍历完整 `data` 数组 |
| fix | GATT 就绪轮询后再上报 CONNECTED |
| fix | 连接超时与会话 ID 防竞态 |
| fix | MTU 通过 `BLEMtuChange` 返回实际值 |
| fix | 默认关闭扫描时临时 GattClient 拉名称（可配置） |
| fix | 无效 UUID 跳过并日志 |
| fix | 写特征时新建 `BLECharacteristic` |
| fix | 连接/通知/资源处理加固 |

---

## 七、合入之后

1. 官方路径：`openharmony-tpc/flutter_packages` → `packages/flutter_reactive_ble_ohos`
2. 业务项目可改为依赖官方仓，或继续使用 GitHub 独立仓
3. 后续新改动：GitHub 开发 → rsync 到 Fork → 新 MR 或追加到现有分支

---

## 八、链接

| 项目 | 地址 |
|------|------|
| GitHub 插件 | https://github.com/mxq1688/flutter_reactive_ble_ohos |
| GitCode Fork | https://gitcode.com/qq_22464981/flutter_packages |
| 官方仓库 | https://gitcode.com/openharmony-tpc/flutter_packages |
| 当前 MR | https://gitcode.com/openharmony-tpc/flutter_packages/merge_requests/796 |
| DCO 签署 | https://gitcode.com/dco |

---

## 九、PR 描述模板（新建 MR 时可粘贴）

```markdown
## Summary

Add `flutter_reactive_ble_ohos`, HarmonyOS NEXT implementation of `reactive_ble_platform_interface`.

## Features

- Scan, connect/disconnect, GATT discovery, read/write, notifications, MTU, connection priority, RSSI
- Register `ReactiveBleOhosPlatformFactory` at app startup for drop-in use with `flutter_reactive_ble`

## Test plan

- [ ] Scan multiple BLE devices on HarmonyOS
- [ ] Connect, read/write, subscribe on target device
- [ ] MTU negotiation returns negotiated value
- [ ] `flutter test` in package directory
```
