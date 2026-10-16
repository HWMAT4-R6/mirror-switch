---
name: mirror-switch
description: 一键换站/换源 — switch apt/pip/docker/npm/cargo/go mirrors on any Linux device (Ubuntu/Debian/Kali) to a chosen site (cernet 教育网联合站 / tuna 清华 / ustc 中科大 / aliyun 阿里云 / hust / bfsu / nju / sjtu), or auto-probe and pick the fastest. Use when the user wants to 换源、换镜像站、镜像加速、"apt 太慢"、"pip 拉不动"、"docker 拉不动"、switch mirrors on a local/remote/container device.
---

# 一键换站 · mirror-switch

给**任何设备**（本机 / 远程 ssh / 容器内）换 Linux 镜像源的一条命令方案。
引擎 = `scripts/mirror-switch.sh`（纯 bash，无依赖，自带备份/回滚/dry-run/测速选站）。

## 什么时候用

- 用户说：换源 / 换镜像站 / 换站 / 镜像加速 / "apt 太慢了" / "pip 拉不动" / "docker 拉不动"
- 要把某台服务器/虚拟机的 apt、pip、docker 源切到国内镜像
- 要判断"哪个镜像站对这台设备最快"（用 `--mirror auto`）

## 标准操作流程（AI 必须按这个来）

1. **先探明目标与现状**（本地 or 哪台远程机器）：拿到 `ssh user@host` 或确认本地。
2. **先跑 dry-run**，把计划给用户看：
   ```bash
   bash scripts/mirror-switch.sh --mirror auto --dry-run
   ```
3. 用户确认后**正式执行**（加 `--yes` 免交互；注意 docker 重启会中断容器，先行提醒）：
   ```bash
   bash scripts/mirror-switch.sh --mirror auto --yes
   ```
4. **读输出的 verify 段**：apt 验证失败会给 rc≠0 → 直接引导回滚：
   ```bash
   bash scripts/mirror-switch.sh --revert
   ```
5. 汇报：换了什么、验证结果、回滚命令。

## 三种目标形态的调用姿势

```bash
# ① 本机
bash scripts/mirror-switch.sh --mirror cernet --yes

# ② 远程机器（把脚本从 stdin 灌过去，无需先上传）
ssh user@host 'sudo bash -s' -- --mirror auto --yes < scripts/mirror-switch.sh

# ③ 容器内
docker exec -i <container> bash -s -- --mirror tuna --yes < scripts/mirror-switch.sh
```

> 远程/容器场景注意：目标上需要 root 或免密 sudo；没有 sudo 时先解决提权。

## 参数速查

| 参数 | 作用 |
|---|---|
| `--mirror NAME` | 选站：`cernet` `tuna` `ustc` `aliyun` `hust` `bfsu` `nju` `sjtu` |
| `--mirror auto` | **测速探测**以上站点，自动选最快的（推荐默认） |
| `--mirror https://...` | 自定义镜像站 base URL |
| `--tool apt,pip,docker,npm,cargo,go` | 只换指定工具（默认 `all` = 探测存在的全换） |
| `--dry-run` | 只展示改动计划，不落盘 |
| `--yes` | 免交互确认 |
| `--revert` | 用最近一次备份还原 |
| `--verify-pull` | docker 额外拉 hello-world 实测 |
| `--list` | 列出所有预设站 |

## 安全设计（可以放心宣传的点）

- **只改"站"，不改结构**：apt 源按**路径**识别（只重写 path 以 `/ubuntu`、`/debian`、`/kali` 开头的 URL 的主机名）——PPA、docker-ce 等第三方源原样保留
- **每个被改文件自动备份**为 `<file>.bak-<时间戳>`；`--revert` 一键还原
- **幂等**：已是目标站则报 "no change"
- **验证闭环**：改完先跑 `apt-get update`（60s 超时），失败明确提示回滚
- pip/docker 的配置文件用 **python3 合并**（保留 proxy 等既有键），不会整文件覆盖

## 已知边界（诚实清单）

- OS：Ubuntu / Debian / Kali（apt 系）；其他发行版会明确跳过
- npm/cargo/go 只在已安装对应工具时生效；cargo 仅 tuna/ustc/bfsu/nju 有镜像
- Docker Hub 加速源（`REGISTRY_MIRRORS`）国内的寿命飘忽（2024 后大面积关停），清单在脚本顶部可改
- deb822 (`*.sources`) 格式已支持路径级改写，但在 Ubuntu 22.04 以外的发行版上未经充分实测（欢迎反馈）

## 故障应急

- apt verify 失败 → `--revert --tool apt` 立刻还原，再查 `/tmp/mswitch-apt.log`
- docker 重启怕断容器 → 先 `--tool apt,pip` 排除 docker，或手动编辑 `REGISTRY_MIRRORS` 后单独跑
- 换完发现目标站对这台设备反而慢 → `--mirror auto` 重选，或 `--revert`
