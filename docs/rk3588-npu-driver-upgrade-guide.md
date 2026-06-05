# RK3588 NPU Driver 升级指南

> 适用于在 RK3588 板卡上运行大语言模型（LLM）所需的 NPU 驱动升级操作。
> 基于 [airockchip/rknn-llm](https://github.com/airockchip/rknn-llm) 项目。

---

## 目录

1. [背景说明](#1-背景说明)
2. [驱动版本兼容性](#2-驱动版本兼容性)
3. [检查当前驱动版本](#3-检查当前驱动版本)
4. [下载驱动](#4-下载驱动)
5. [升级步骤](#5-升级步骤)
6. [验证与测试](#6-验证与测试)
7. [常用脚本与环境配置](#7-常用脚本与环境配置)
8. [常见问题排查](#8-常见问题排查)
9. [参考资源](#9-参考资源)

---

## 1. 背景说明

RKLLM 是 Rockchip 为 RK3588/RK3576/RK3562 等平台提供的大语言模型部署方案，整体架构如下：

```
┌─────────────────────────────────┐
│        RKLLM-Toolkit (PC)       │  ← 模型转换/量化
├─────────────────────────────────┤
│     RKLLM Runtime (板端)         │  ← C/C++ 推理 API
├─────────────────────────────────┤
│     RKNPU Kernel Driver         │  ← NPU 硬件驱动（本文目标）
├─────────────────────────────────┤
│         RK3588 NPU 硬件          │
└─────────────────────────────────┘
```

**NPU 驱动版本不足是最常见的部署失败原因**。RKLLM Runtime 对驱动版本有严格要求，版本不匹配会导致：

- 模型加载失败（`failed to malloc npu memory`）
- 推理运算错误（`matmul(w8a8) run failed`）
- 多轮对话异常（`Server busy`）

---

## 2. 驱动版本兼容性

以下是实际测试得出的版本兼容矩阵（基于 GitHub Issues 数据）：

| RKLLM SDK 版本 | 最低驱动 | 推荐驱动 | 备注 |
|:---|:---|:---|:---|
| v1.0.0 ~ v1.0.1 | 0.9.6 | 0.9.6+ | 基本 LLM 支持 |
| v1.1.0 | 0.9.6 | 0.9.7+ | LoRA、GGUF 支持 |
| v1.2.0 | 0.9.7 | 0.9.7+ | w8a8 量化、多模态、16K上下文 |
| v1.2.1 | 0.9.7 | 0.9.8 | 函数调用、多批次推理 |
| v1.2.2 | 0.9.7 | 0.9.8 | Gemma3n、InternVL3、多实例 |
| **v1.2.3 (最新)** | 0.9.7 | **0.9.8** | Qwen3-VL、DeepSeekOCR |

> **经验法则**：如果不确定，直接安装 **0.9.8** 版本驱动，向下兼容所有 RKLLM v1.x 版本。

### 驱动版本过低时的典型错误日志

```
# 驱动 0.8.2 运行 rkllm 1.2.1b1
W rkllm: Warning: Your rknpu driver version is too low, please upgrade to 0.9.7
I rkllm: rkllm-runtime version: 1.2.1b1, rknpu driver version: 0.8.2, platform: RK3588

# 后果：推理全部失败
E rkllm: matmul(w8a8) run failed
```

```
# 驱动 0.9.6 运行 rkllm 1.2.1b1
W rkllm: Warning: Your rknpu driver version is too low, please upgrade to 0.9.7
I rkllm: rkllm-runtime version: 1.2.1b1, rknpu driver version: 0.9.6, platform: RK3588

# 后果：可能正常工作，但多次请求后出问题
"Server busy! Try later."
```

---

## 3. 检查当前驱动版本

SSH 登录到板卡（IP `192.168.31.241`），任选一种方式检查：

### 方法 1：通过 debugfs 查看

```bash
cat /sys/kernel/debug/gc/version
```

如果提示文件不存在，请先挂载 debugfs：

```bash
mount -t debugfs none /sys/kernel/debug
cat /sys/kernel/debug/gc/version
```

### 方法 2：通过 dmesg 查看

```bash
dmesg | grep -i "galcore\|rknn\|npu" | tail -20
```

### 方法 3：运行 RKLLM 推理程序时自动输出

启动任何基于 RKLLM Runtime 的程序，日志会打印版本信息：

```
I rkllm: rkllm-runtime version: 1.2.3, rknpu driver version: 0.9.8, platform: RK3588
```

### 方法 4：检查已加载的内核模块

```bash
lsmod | grep galcore
modinfo galcore 2>/dev/null | grep version
```

---

## 4. 下载驱动

### 方式 A：从 rknn-llm 仓库直接下载

[rknn-llm 仓库](https://github.com/airockchip/rknn-llm) 的 `rknpu-driver/` 目录提供了最新驱动：

```
文件: rknpu_driver_0.9.8_20241009.tar.bz2
路径: https://github.com/airockchip/rknn-llm/blob/main/rknpu-driver/rknpu_driver_0.9.8_20241009.tar.bz2
```

```bash
# 在本地电脑下载
wget https://github.com/airockchip/rknn-llm/raw/main/rknpu-driver/rknpu_driver_0.9.8_20241009.tar.bz2
```

### 方式 B：从 RKLLM SDK 完整包下载

完整的 RKLLM SDK 可从官方网盘下载：

```
下载地址: https://console.zbox.filez.com/l/RJJDmB (最新版)
提取码:   rkllm

旧版本入口: https://console.box.lenovo.com/l/l0tXb8
```

SDK 包中包含：
- `rknpu-driver/` — NPU 驱动
- `rkllm-runtime/` — 板端运行时库
- `rkllm-toolkit/` — PC 端模型转换工具
- `doc/` — 中英文 PDF 文档
- `examples/` — 示例代码

### 方式 C：从 rknn-toolkit2 完整 SDK 下载（通用 NPU 驱动）

```
下载地址: https://console.zbox.filez.com/l/I00fc3
提取码:   rknn
```

该 SDK 包含通用 NPU2 驱动（非 LLM 专用），版本号体系可能不同。

---

## 5. 升级步骤

### 5.1 传输驱动包到板卡

```bash
# 使用 scp (替换为你的 SSH 用户名/密码)
scp rknpu_driver_0.9.8_20241009.tar.bz2 root@192.168.31.241:/tmp/

# 或使用 adb (Android 系统)
adb push rknpu_driver_0.9.8_20241009.tar.bz2 /tmp/
```

### 5.2 SSH 登录板卡

```bash
ssh root@192.168.31.241
# 或
ssh orangepi@192.168.31.241
```

### 5.3 解压驱动包

```bash
cd /tmp
tar -xjf rknpu_driver_0.9.8_20241009.tar.bz2
cd rknpu_driver_*
ls -la
```

典型的驱动包内容：
```
├── galcore.ko          # NPU 内核模块（主驱动文件）
├── install.sh          # 安装脚本（如有）
├── uninstall.sh        # 卸载脚本（如有）
└── README.md           # 说明文档（如有）
```

### 5.4 卸载旧驱动

```bash
# 卸载当前 galcore 内核模块
sudo rmmod galcore

# 如果 rmmod 报错 "module is in use"，先检查谁在使用
lsmod | grep galcore
# 停止相关进程后再试
```

### 5.5 安装新驱动

**方法 A：使用安装脚本（推荐）**

```bash
sudo chmod +x install.sh
sudo ./install.sh
```

**方法 B：手动安装**

```bash
# 删除旧驱动文件
sudo rm -f /lib/modules/$(uname -r)/extra/galcore.ko
sudo rm -f /lib/modules/$(uname -r)/kernel/drivers/npu/galcore.ko

# 复制新驱动到内核模块目录
sudo cp galcore.ko /lib/modules/$(uname -r)/extra/

# 更新模块依赖
sudo depmod -a

# 加载新驱动
sudo modprobe galcore
# 或
sudo insmod /lib/modules/$(uname -r)/extra/galcore.ko
```

### 5.6 设置开机自动加载

编辑 `/etc/modules-load.d/galcore.conf`（如果不存在则创建）：

```bash
echo "galcore" | sudo tee /etc/modules-load.d/galcore.conf
```

或在 `/etc/modules` 中添加一行 `galcore`（取决于系统）。

### 5.7 重启验证

```bash
sudo reboot
```

---

## 6. 验证与测试

重启后逐项检查：

### 6.1 检查驱动版本

```bash
cat /sys/kernel/debug/gc/version
# 期望输出: 0.9.8 或类似版本号
```

### 6.2 检查内核模块状态

```bash
lsmod | grep galcore
# 期望有输出，表示模块已加载

dmesg | grep -i "galcore\|npu" | tail -5
# 无 "error"、"failed" 等字样
```

### 6.3 运行 RKLLM 推理测试

```bash
# 设置库路径
export LD_LIBRARY_PATH=./lib:$LD_LIBRARY_PATH

# 执行定频脚本（RK3588）
sh fix_freq_rk3588.sh

# 开启性能日志
export RKLLM_LOG_LEVEL=1

# 运行推理 Demo
./llm_demo /path/to/model.rkllm 2048 4096
```

正常输出应包含：
```
I rkllm: rkllm-runtime version: 1.2.x, rknpu driver version: 0.9.8, platform: RK3588
rkllm init success
```

### 6.4 监控 NPU 使用率（可选）

```bash
# 使用 rknn-llm 仓库中的脚本
sh eval_perf_watch_npu.sh
```

---

## 7. 常用脚本与环境配置

### 7.1 定频脚本（rknn-llm 仓库提供）

RKLLM 推理前需运行，用于锁定 CPU/NPU 频率以获得稳定性能：

| 平台 | 脚本 |
|:---|:---|
| RK3588 | `scripts/fix_freq_rk3588.sh` |
| RK3576 | `scripts/fix_freq_rk3576.sh` |
| RK3562 | `scripts/fix_freq_rk3562.sh` |
| RV1126B | `scripts/fix_freq_rv1126b.sh` |

### 7.2 文件描述符限制

RKLLM 推理会打开大量文件描述符，运行前务必设置：

```bash
ulimit -n 102400
```

或在 Python 中：

```python
import resource
resource.setrlimit(resource.RLIMIT_NOFILE, (102400, 102400))
```

否则会触发 `Too many open files` 错误。

### 7.3 环境变量

```bash
# 设置 RKLLM 日志级别（1=显示性能统计）
export RKLLM_LOG_LEVEL=1

# 库路径
export LD_LIBRARY_PATH=./lib:/usr/lib:$LD_LIBRARY_PATH
```

---

## 8. 常见问题排查

### Q1: `cat /sys/kernel/debug/gc/version` 提示文件不存在

```bash
# 挂载 debugfs
mount -t debugfs none /sys/kernel/debug
```

如果仍然不存在，说明 galcore 驱动未加载或内核未编译 NPU 支持。

### Q2: `rmmod galcore` 报 "module is in use"

```bash
# 查看谁在使用
lsmod | grep galcore
# 停止所有使用 NPU 的进程（AI 推理、摄像头等）
# 必要时重启
sudo reboot
```

### Q3: `matmul(w8a8) run failed` 错误

**原因**：驱动版本过低（< 0.9.7），不支持 w8a8 量化推理。

**解决**：升级驱动到 0.9.7 或更高版本。

从 [Issue #290](https://github.com/airockchip/rknn-llm/issues/290) 确认的案例：
> 驱动 0.8.2 + rkllm 1.2.1b1 → 所有 w8a8 推理失败

### Q4: `failed to malloc npu memory` 错误

可能原因（按概率排序）：
1. **驱动版本过低** — 升级到 0.9.8
2. **文件描述符不足** — 执行 `ulimit -n 102400`
3. **NPU 内存分配策略问题** — 参考 [Issue #335](https://github.com/airockchip/rknn-llm/issues/335)
4. **系统内存不足** — 检查 `free -h`，RK3588 至少需要 8GB+ RAM

### Q5: `Server busy! Try later.` 多轮对话错误

从 [Issue #274](https://github.com/airockchip/rknn-llm/issues/274) 确认：
> 驱动 0.9.6 + rkllm 1.2.1b1 → 第一轮正常，第二轮开始报 Server busy

**解决**：升级驱动到 0.9.7+。

### Q6: `modprobe galcore` 找不到模块

```bash
# 手动加载
sudo insmod /lib/modules/$(uname -r)/extra/galcore.ko

# 检查内核版本匹配
uname -r
# 确保 galcore.ko 是针对当前内核版本编译的
modinfo galcore.ko | grep vermagic
```

### Q7: 驱动安装后设备不识别或启动失败

```bash
# 查看内核日志
dmesg | tail -50

# 常见问题：内核版本不匹配
# galcore.ko 必须与板卡内核版本完全一致
# 如果版本不匹配，需要重新编译驱动或升级整个固件
```

---

## 9. 参考资源

| 资源 | 链接 |
|:---|:---|
| rknn-llm 仓库 | https://github.com/airockchip/rknn-llm |
| rknn-toolkit2 仓库 | https://github.com/airockchip/rknn-toolkit2 |
| RKLLM SDK 下载 (最新) | https://console.zbox.filez.com/l/RJJDmB (提取码: rkllm) |
| 模型 Zoo | https://console.box.lenovo.com/l/l0tXb8 (提取码: rkllm) |
| RKPU2 SDK 下载 | https://console.zbox.filez.com/l/I00fc3 (提取码: rknn) |
| 官方 PDF 文档 (中) | rknn-llm/doc/Rockchip_RKLLM_SDK_CN_1.2.3.pdf |
| 官方 PDF 文档 (英) | rknn-llm/doc/Rockchip_RKLLM_SDK_EN_1.2.3.pdf |
| 驱动发布页 | https://github.com/airockchip/rknn-llm/releases |
| QQ 交流群 4 | 958083853 |

---

## 附录 A: 一键升级脚本

本项目提供了自动化脚本来简化升级流程，位于 `scripts/` 目录：

### 脚本列表

| 脚本 | 用途 | 运行位置 |
|:---|:---|:---|
| `scripts/check_npu.sh` | NPU 驱动诊断 | 板卡上 |
| `scripts/upgrade.sh` | 一键升级入口 | Mac/PC |
| `scripts/setup_npu_driver.sh` | 完整升级流程 | Mac/PC |
| `scripts/install_npu_driver.sh` | 板卡端安装 | 板卡上 |

### 快速使用

```bash
# 1. 诊断板卡 NPU 状态
ssh root@192.168.31.241 "sh -s" < scripts/check_npu.sh

# 2. 一键升级（需要 Mac 能访问 GitHub 和板卡）
cd scripts
./upgrade.sh

# 3. 如果网络受限，手动下载驱动后使用本地文件
./upgrade.sh --local-driver /path/to/galcore.ko

# 4. 板卡端手动安装（驱动文件已在板卡上）
ssh root@192.168.31.241
cd /tmp/rkllm_driver && sh install_npu_driver.sh
```

### 当前板卡 (192.168.31.241) 状态

```
内核版本:   5.10.66 (Alpine Linux)
NPU 驱动:   内置 RKNPU v0.7.2
galcore:    未加载
状态:       ❌ 版本过低，需要升级到 v0.9.7+
升级方案:   需要从 RKLLM SDK 获取 galcore.ko
```

---

> **文档版本**: v1.1 | **最后更新**: 2025-06-02 | **适用平台**: RK3588 系列
