# pxder-zig

Pixiv 插画批量下载器，由 [Lemon](https://github.com/zz1998022) 基于 [pxder](https://github.com/Tsuk1ko/pxder)（原作者：[Tsuk1ko](https://github.com/Tsuk1ko)）使用 [Zig](https://ziglang.org/) 重写。

单二进制分发，无运行时依赖，原生性能，支持交叉编译。

## 功能

- 按画师 UID 下载全部插画
- 按插画 PID 下载指定作品
- 下载关注画师的作品（公开/私密）
- 下载收藏插画（公开/私密）
- 增量更新已下载的画师作品
- 多线程并发下载（默认 5 线程，最大 32）
- 自动重试与限流处理
- 断点续传（跳过已下载文件）
- HTTP/HTTPS CONNECT 代理
- OAuth PKCE 登录（模拟 Pixiv Android 客户端）
- Windows `pixiv://` 协议自动回调
- 跨平台：Windows / Linux / macOS

## 与原版的区别

| 特性 | pxder (Node.js) | pxder-zig |
|------|-----------------|-----------|
| 运行时依赖 | Node.js >= 16 | 无（单二进制） |
| 安装方式 | npm install -g | 下载对应平台的二进制文件 |
| 代理支持 | HTTP / SOCKS5 | HTTP CONNECT（SOCKS5 计划中） |
| 直连模式 | 支持（已移除） | 不支持 |
| Windows 协议回调 | 支持 | 支持 |
| 配置存储 | 用户目录 | 用户目录 |
| 交叉编译 | N/A | 支持 Windows/Linux/macOS |

## 构建

需要 [Zig 0.16.0](https://ziglang.org/download/)。

```bash
# Debug 构建
zig build

# Release 构建（推荐）
zig build -Doptimize=ReleaseSafe

# 交叉编译
zig build -Dtarget=x86_64-windows-gnu -Doptimize=ReleaseSafe
zig build -Dtarget=x86_64-linux-musl -Doptimize=ReleaseSafe
zig build -Dtarget=aarch64-macos -Doptimize=ReleaseSafe
```

构建产物在 `zig-out/bin/` 目录下。

## 使用方法

### 登录

```bash
# 打开浏览器进行 OAuth 登录（推荐）
pxder --login

# 使用已有的 refresh token 登录
pxder --login TOKEN

# 在不支持协议回调的系统上登录
pxder --login --no-protocol
```

**登录步骤（默认模式）：**

1. 程序会自动打开浏览器，访问 Pixiv 登录授权页面
2. 登录并授权后，浏览器会弹出对话框，选择"打开"
3. 程序自动接收回调，完成登录

**登录步骤（--no-protocol 模式）：**

1. 程序输出 Login URL，手动在浏览器中打开
2. 按 `F12` 打开开发者工具，切换到 "Network" 选项卡，勾选 "Preserve log"
3. 进行登录授权，最终会进入空白页面
4. 在 Network 面板中找到最后一个请求，复制 URL 中的 `code` 参数
5. 将 code 粘贴到程序中并回车

### 登出

```bash
pxder --logout
```

仅删除当前计算机用户的 refresh token。

### 导出 Token

```bash
pxder --export-token
```

输出当前存储的 refresh token，可用于在其他设备上登录：

```bash
pxder --login <exported_token>
```

### 设置

```bash
pxder --setting
```

进入交互式设置界面，可配置以下项目：

```
[1] Download path       下载目录（必须设置）
[2] Download thread     下载线程数（默认 5，范围 1-32）
[3] Download timeout    下载超时秒数（默认 30）
[4] Auto rename         自动重命名画师文件夹（跟随画师改名）
[5] Proxy               代理设置
```

**代理格式：**

```
<协议>://[用户名:密码@]<IP>:<端口>
```

示例：

- `http://127.0.0.1:7890`
- `http://user:pass@127.0.0.1:1080`
- `socks5://127.0.0.1:1080`

输入空行则从环境变量 `all_proxy` / `https_proxy` / `http_proxy` 中读取。输入 `disable` 完全禁用代理。

### 下载插画

```bash
# (1) 按画师 UID 下载（逗号分隔多个）
pxder -u 5899479,724607,11597411

# (2) 下载公开关注的画师
pxder -f

# (3) 下载私密关注的画师
pxder -F

# (4) 增量更新已下载的画师
pxder -U

# (5) 下载公开收藏
pxder -b

# (6) 下载私密收藏
pxder -B

# (7) 按插画 PID 下载（逗号分隔多个）
pxder -p 70593670,70594912
```

### 其他参数

```
-M, --no-ugoira-meta    下载动图时不请求帧延迟元数据
-O, --output-dir <dir>  覆盖下载目录
--force                 忽略关注列表缓存，强制重新获取
--debug                 启用详细输出
--no-protocol           登录时不使用 Windows 协议处理器
--output-config-dir     输出配置文件目录路径
-v, --version           显示版本号
-h, --help              显示帮助信息
```

### 下载说明

- 每位画师的作品下载在 `(UID)画师名` 格式的子文件夹中
- 文件命名格式为 `(PID)作品名.ext`，多图作品追加 `_p0`, `_p1` 后缀
- 动图下载为包含所有帧的 ZIP 压缩包，标注帧延迟信息，如 `(PID)标题@30ms.zip`
- 画师名中的 `@` 及其后内容会被自动去除（通常是摊位信息）
- 文件名会过滤 Windows/Linux 不允许的字符
- 已下载的插画会自动跳过
- 单文件最多重试 10 次
- 404 状态码直接跳过（Pixiv 自身问题）
- 多线程同时出错时暂停 5 分钟后继续
- 下载到临时目录后校验完整性再移至最终路径

## 项目结构

```
src/
  main.zig             CLI 入口，参数解析，命令分发
  config.zig           配置文件读写，跨平台路径解析
  pixiv_api.zig        Pixiv API 客户端（认证头、重试、限流）
  auth.zig             OAuth PKCE 流程，token 管理
  http_client.zig      HTTP 客户端封装（代理 + TLS 隧道）
  proxy.zig            代理解析（HTTP CONNECT / SOCKS5）
  downloader.zig       多线程下载引擎
  illust.zig           插画数据模型（单图/多图/动图 URL 构造）
  illustrator.zig      画师数据模型，分页逻辑
  tools.zig            文件下载，临时目录管理
  terminal.zig         ANSI 颜色，终端交互
  json_utils.zig       JSON 安全解析辅助
  crypto.zig           SHA-256, MD5, base64url
  protocol.zig         Windows pixiv:// 协议处理器
  update_checker.zig   版本检查
```

## 技术细节

- **HTTP/TLS**：基于 `std.http.Client` + `std.crypto.tls`，手动实现 HTTPS CONNECT 隧道以绕过 Zig 0.16 标准库的 TLS 升级缺陷
- **并发模型**：`std.Thread.Pool` + `std.Thread.WaitGroup`，每个下载任务作为独立 job 提交
- **加密**：`std.crypto.hash.Md5`（API 签名）、`std.crypto.hash.sha2.Sha256`（PKCE）、base64url
- **JSON**：`std.json` 动态树解析（`std.json.Value`），配合辅助函数安全提取字段
- **依赖**：仅使用 Zig 标准库，无第三方依赖

## 致谢

- [Tsuk1ko/pxder](https://github.com/Tsuk1ko/pxder) — 原始项目，本项目的功能设计参考来源

## 许可证

本项目基于 [GNU General Public License v3.0](LICENSE) 开源，与原项目保持一致。
