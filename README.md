# 一键换站 · mirror-switch

> 给任何设备换 Linux 镜像源的**一条命令**方案 —— 本地 / 远程 SSH / 容器通用，
> 自带备份、回滚、dry-run 和**自动测速选站**。专为 AI 助手（Claude Code 等）调用设计，
> 也可以纯手工跑。

```bash
# 最常用的一条：自动探测哪个镜像站对这台机器最快，然后换过去
curl -fsSL https://raw.githubusercontent.com/HWMAT4/mirror-switch/main/scripts/mirror-switch.sh | sudo bash -s -- --mirror auto --yes
```

（上面是示意 URL，发布后替换为你仓库的真实地址。）

## 它解决什么问题

- 国内装环境三大痛：`apt update` 龟速、`pip install` 超时、`docker pull` 拉不动
- 每台新机器都要手抄一遍换源配置，格式还随发行版/版本变化（sources.list / deb822 / pip.conf / daemon.json）
- 号称"离你最近"的镜像站**不一定最快**（实测某校园网里，本校镜像 0.4MB/s，清华源 47MB/s——差 100 倍）

## 支持矩阵

| 工具 | 支持 | 说明 |
|---|---|---|
| **apt** | ✅ Ubuntu / Debian / Kali | 路径级换站：只重写 `/ubuntu` `/debian` `/kali` 路径的镜像主机名，**PPA / docker-ce 等第三方源不动** |
| **pip** | ✅ | 合并写 `/etc/pip.conf`（python3 合并，保留既有键） |
| **docker** | ✅ | 合并 `daemon.json` 的 `registry-mirrors` + 重启 docker（可选 hello-world 实测） |
| **npm** | ✅ | npmmirror |
| **cargo** | ✅（tuna/ustc/bfsu/nju） | sparse 源 |
| **go** | ✅ | goproxy.cn |

内置预设站：`cernet`（教育网联合镜像站，自动跳转最优节点）、`tuna`、`ustc`、`aliyun`、`hust`、`bfsu`、`nju`、`sjtu`，外加自定义 URL。

## 用法

```bash
# 看所有预设
bash scripts/mirror-switch.sh --list

# 自动测速选站（推荐）
sudo bash scripts/mirror-switch.sh --mirror auto --yes

# 指定站 / 指定工具
sudo bash scripts/mirror-switch.sh --mirror tuna --tool apt,pip --yes

# 只预览不改（先看它要动什么）
bash scripts/mirror-switch.sh --mirror cernet --dry-run

# 后悔了：一键还原
sudo bash scripts/mirror-switch.sh --revert
```

### 远程机器（无需先上传脚本）

```bash
ssh user@host 'sudo bash -s' -- --mirror auto --yes < scripts/mirror-switch.sh
```

### 容器内

```bash
docker exec -i mycontainer bash -s -- --mirror tuna --yes < scripts/mirror-switch.sh
```

### 作为 Claude Code / AI 技能使用

本仓库本身就是一份 [Agent Skill](https://docs.claude.com/en/docs/claude-code/skills)：把整个文件夹放进技能目录即可：

```bash
cp -r mirror-switch ~/.claude/skills/mirror-switch
# 之后直接对 Claude 说："把这台 / 那台服务器的源换成最快的" 
```

其他 AI 工具：把 `SKILL.md` 丢给它的 context，或直接让它读 `scripts/mirror-switch.sh --help`。

## 安全设计

- **先备份后动手**：每个被改文件存为 `<file>.bak-<时间戳>`，`--revert` 一键还原
- **dry-run**：不带任何侥幸——计划改什么先给你看
- **幂等**：已经是目标站则跳过
- **验证闭环**：apt 改完自动 `apt-get update` 检查，失败提示回滚命令
- **只换"站"不换"结构"**：URL 的路径、suite、组件、signed-by 全部原样保留

## Roadmap

- [ ] Fedora/CentOS（dnf）、Arch 支持
- [ ] conda / anaconda 支持
- [ ] `--mirror auto` 支持离线候选表与 IPv6 优先
- [ ] Windows（winget/scoop WSL 场景）说明

## License

MIT
