# 此方案已实测失败 — 不要部署

**日期**: 2026-09-15
**结论**: 放宽 `HostCodeAddr` 范围会让 relocation 失败，zygote 崩溃。

## 方案内容

两处补丁（共 3 字节），试图让代码池使用完整 64 位地址空间：

1. `0x3a9129`  `75 48` → `90 90`  去掉 CodePool::Add 的 32 位范围检查
2. `0x7aaddb`  `01` → `00`       可执行区不再强制低地址

## 为什么失败

补丁本身**能加载**（Android 到达 boot_completed=1，init 未崩），
但**启动任何 ARM 应用时** zygote 立刻崩溃：

```
Abort: machine_code.cc:78: CHECK failed: IsInRange<int32_t>(disp)

  #04 berberis::MachineCode::PerformRelocations(...)
  #05 berberis::CodePool<...>::Add(MachineCode*)+197
  #06 berberis::MakeTrampolineCallable(...)
  #07 berberis::GuestLoader::CreateInstance(...)
  #08 berberis::GuestLoader::StartAppProcessInNewThread(...)
  #09 native_bridge_initialize
```

**根因**：relocation（重定位）需要 **32 位位移量**。
当代码被放到高地址、而 trampoline 仍在低地址时，
两者距离**超出 int32 范围** → `IsInRange<int32_t>(disp)` 失败 → abort。

这是**架构性约束**，不是可调参数：
- trampoline 必须在低地址（`HostCodeAddr` 要求）
- 翻译代码必须能在 32 位位移内跳到 trampoline
- 两者共同把代码池锁在低 2GB 窗口内

## 三次尝试全部失败（记录以免重蹈）

| # | 补丁 | 结果 |
|---|---|---|
| 1 | NOP 掉 `or $0x40,%ecx` (0x7a3db7) | `host_code.h:35` CHECK → zygote 崩 |
| 2 | 清零 low_addr 字段 (0x7aaddb) | 同上 |
| 3 | 同时放宽范围检查 + low_addr | `machine_code.cc:78` CHECK → zygote 崩 |

**结论：低 2GB 窗口是 berberis 的硬性架构要求，在二进制层面无法绕过。**

## 唯一有效的缓解

`ro.berberis.mode=interpret-only`（见 `../overlay/etc/cont-init.d/20-waydroid-setup.sh` 第 4i 节），
把单次可用时间从 18 秒延长到最长 7.5 小时，但代码池最终仍会触顶。

真正的修复需要 berberis 上游改动（例如改用 64 位 relocation，
或让代码池能够回收/复用空洞）。

## 文件

- `libndk_translation.so.64-berberis-17.orig` — 原版
- `libndk_translation.so.64-berberis-17` — 失败的补丁版（仅供研究）
- `patch-libndk-highaddr.py.FAILED` — 补丁脚本
