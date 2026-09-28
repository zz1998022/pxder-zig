# pxder · Rust + TUI

Pixiv 插画下载器的 Rust 重构。使用 Ratatui/Crossterm、Tokio、Reqwest/Rustls。
基于 Lemon 的 Zig 实现以及 Tsuk1ko/pxder，保留 GPL-3.0-only 授权。

## 运行

在仓库根目录执行（Rust 1.88+，建议当前 stable）：

```sh
cargo run --manifest-path rust/Cargo.toml --release
```

无参数启动 TUI；也可用 `--tui`。本地安装：

```sh
cargo install --path rust --locked
```

TUI 快捷键：

| 按键 | 功能 |
|---|---|
| `l` | 登录菜单：`o` OAuth、`t` refresh token、`x` 登出 |
| `s` | 编辑下载目录、并发、超时、代理、自动改名 |
| `n` | 新建任务；来源栏用左右键选择 UID/PID/关注/收藏/增量更新 |
| `Tab` / `Shift+Tab` | 切换表单字段 |
| `Ctrl+U` | 清空当前字段 |
| `←` / `→`、`Home` / `End` | 输入框内移动光标；支持中文、粘贴和 Delete 删除 |
| `Space` | 切换当前开关，无需输入 true/false |
| `Enter` / `Esc` | 提交 / 返回 |
| `c` | 确认后取消当前任务，保留已完成文件 |
| `q` / `Ctrl+C` | 退出；有任务运行时先确认，再取消并恢复终端 |
| `g` | 展开任务日志；↑↓ 翻阅，End 跟随最新记录 |
| `↑` / `↓` | 总览中滚动活动文件 |
| `?` | 帮助 |

同时运行一个批次，每批使用固定并发上限和有界队列。任务中可查看活动文件、
平均速度、成功/跳过/失败计数和近期日志。界面最低尺寸 60×20；推荐 120×36，
宽度达到 110 列时显示侧栏。表单根据来源显示「画师 UID」或「作品 PID」，
其他来源无需输入 ID。Token、授权码和代理字段隐藏输入。

## CLI

```sh
pxder --setting -O ./images --threads 5 --timeout 30 --proxy http://127.0.0.1:7890
pxder --login                      # OAuth PKCE
pxder --login --no-protocol        # 手动输入 code 或完整回调 URL
pxder --login REFRESH_TOKEN        # 可从 TUI 隐藏输入 token，避免 shell 历史
pxder -u 5899479,724607
pxder -p 70593670,70594912 -O ./selected
pxder -f                          # 公开关注；-F 私密关注
pxder -b                          # 公开收藏；-B 私密收藏
pxder -U                          # 扫描 (UID)画师名 目录，增量更新
pxder -p 70593670 -M               # 跳过动图元数据
pxder --logout
pxder --export-token
pxder --output-config-dir
pxder -v
```

`--setting` 不带设置项进入交互设置。`--auto-rename true` 控制画师目录改名。
`--debug` 输出任务进度和结束日志，不输出令牌或 OAuth 请求内容。
`--force` 为兼容参数：每次都重新获取关注列表，不覆盖已有文件。
缺失参数、冲突命令和任务失败返回非零状态；取消返回 130。

Windows 登录期间临时注册 `pixiv://`，通过带随机 nonce 的本地接收器接收授权码，
正常完成、失败或取消后恢复旧注册值。macOS/Linux 手动粘贴 code 或回调 URL。
Windows 回调失败时使用 `--no-protocol`。强制结束进程无法执行注册表恢复。

## 配置兼容

新配置位于系统配置目录的 `pxder/config.json`。没有新配置时只读加载旧版
`pxder-zig/config.json`，保存时写入新目录，不修改旧版配置。配置错误会明确报错。
`--config-dir <目录>` 可隔离配置且禁用旧配置导入，适合测试。
配置包含 refresh token，Unix 下通过私有临时文件原子保存；不要公开此文件。

支持环境/系统代理、`http://`、`https://`、`socks5://`、`socks5h://`。
`--proxy disable` 明确直连。连接超时最长 15 秒；`timeout` 为完整单次请求的上限，
包含响应体读取。文件最多重试 10 次，API 最多重试 3 次；限流遵循 Retry-After，
等待可以取消。永久性 HTTP 错误不盲目重试，404 计为跳过。

## 文件语义

- 沿用 `(UID)画师名`、`(PID)标题[_pN].ext` 和 PID 单独子目录。
- 收藏写入 `[bookmark] Public` / `[bookmark] Private`。
- 动图保存 ZIP，兼容文件名使用第一帧延迟；额外 `.frames.json` 保存全部帧延迟。
- 流式下载至目标目录内的唯一临时文件，非空且传输完整后无覆盖发布。
- 已有非空文件跳过；已有空文件明确报错。不会自动覆盖用户文件。
- 中断下载重新开始，不提供 HTTP Range 续传；正常取消会清理临时文件。
- 同一下载根目录使用排他锁，避免多个 Rust 进程同时操作；Zig 版不识别此锁。
- 文件名最多保留 180 字节标题，避免多字节标题超过文件系统限制。

## 验证与发布

```sh
cargo fmt --manifest-path rust/Cargo.toml --check
cargo clippy --manifest-path rust/Cargo.toml --locked --all-targets -- -D warnings
cargo test --manifest-path rust/Cargo.toml --locked --all-targets
cargo build --manifest-path rust/Cargo.toml --locked --release
# macOS/Linux：实际 PTY 交互及退出恢复
python3 rust/tests/terminal_smoke.py rust/target/release/pxder
```

测试使用本地模拟 HTTP/TCP 服务，不需要 Pixiv 凭据。覆盖认证/分页、私密参数、
重试、取消、文件发布、配置迁移及 TUI 渲染。真实 Pixiv 兼容性和平台运行须单独验证。

`rust-ci.yml` 在 Windows/Linux/macOS 执行检查。`rust-release.yml` 支持手动构建，
`rust-v<版本>` 标签构建三个平台资产及 SHA-256，全部测试通过后创建草稿 Release。
Zig 原有 `v*` 发版与 WinGet 流程保留；Rust 使用独立标签，尚不替换原 WinGet 包。
