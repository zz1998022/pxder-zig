use anyhow::{Context, Result, bail};
use clap::{ArgGroup, Parser};
use futures_util::StreamExt;
use pxder::{
    api::{self, Api, Endpoints},
    auth::{Pkce, parse_code},
    config::{Config, ConfigStore},
    download::{self, Progress, Request, Source},
    tui,
};
use std::{
    io::{IsTerminal, Write},
    path::PathBuf,
    process::ExitCode,
    time::Duration,
};
use tokio_util::sync::CancellationToken;

#[derive(Parser)]
#[command(version, disable_version_flag = true, about = "Pixiv 插画下载器 · 无参数启动 TUI", group(ArgGroup::new("action").args(["login", "logout", "setting", "uid", "pid", "follow", "follow_private", "bookmark", "bookmark_private", "update", "output_config_dir", "export_token", "tui", "protocol_callback"])))]
struct Cli {
    /// 显示版本
    #[arg(short = 'v', long, action = clap::ArgAction::Version)]
    version: Option<bool>,
    #[arg(long, hide = true, requires_all = ["callback_port", "callback_nonce"])]
    protocol_callback: Option<String>,
    #[arg(long, hide = true, requires = "protocol_callback")]
    callback_port: Option<u16>,
    #[arg(long, hide = true, requires = "protocol_callback")]
    callback_nonce: Option<String>,
    /// OAuth 登录，或使用已有 refresh token
    #[arg(long, num_args = 0..=1, default_missing_value = "", value_name = "TOKEN")]
    login: Option<String>,
    /// 清除本机登录信息
    #[arg(long)]
    logout: bool,
    /// 交互设置，或搭配 --threads / --timeout / --proxy 等保存配置
    #[arg(long)]
    setting: bool,
    /// 下载画师全部作品（逗号分隔 UID）
    #[arg(short = 'u', long)]
    uid: Option<String>,
    /// 下载指定作品（逗号分隔 PID）
    #[arg(short = 'p', long)]
    pid: Option<String>,
    /// 下载公开关注画师的作品
    #[arg(short = 'f', long)]
    follow: bool,
    /// 下载私密关注画师的作品
    #[arg(short = 'F', long)]
    follow_private: bool,
    /// 下载公开收藏
    #[arg(short = 'b', long)]
    bookmark: bool,
    /// 下载私密收藏
    #[arg(short = 'B', long)]
    bookmark_private: bool,
    /// 更新下载目录中已有的画师
    #[arg(short = 'U', long)]
    update: bool,
    /// Compatibility flag: follows are always fetched afresh.
    #[arg(long)]
    force: bool,
    /// 跳过动图帧延迟元数据
    #[arg(short = 'M', long)]
    no_ugoira_meta: bool,
    /// 本次下载目录；搭配 --setting 时保存为默认目录
    #[arg(short = 'O', long)]
    output_dir: Option<PathBuf>,
    /// 输出进度与结束日志，不输出认证数据
    #[arg(long)]
    debug: bool,
    /// Use manual OAuth code entry instead of the Windows protocol callback.
    #[arg(long)]
    no_protocol: bool,
    /// 输出配置目录
    #[arg(long)]
    output_config_dir: bool,
    /// 将 refresh token 输出至标准输出
    #[arg(long)]
    export_token: bool,
    /// 启动交互终端界面（无参数时默认）
    #[arg(long)]
    tui: bool,
    /// Isolate configuration, including credentials; disables legacy import.
    #[arg(long)]
    config_dir: Option<PathBuf>,
    #[arg(long, requires = "setting")]
    threads: Option<usize>,
    #[arg(long, requires = "setting")]
    timeout: Option<u64>,
    #[arg(long, requires = "setting")]
    proxy: Option<String>,
    #[arg(long, requires = "setting")]
    auto_rename: Option<bool>,
}

#[tokio::main]
async fn main() -> ExitCode {
    let cli = Cli::parse();
    let cancel = CancellationToken::new();
    let signal_token = cancel.clone();
    let signal = tokio::spawn(async move {
        if tokio::signal::ctrl_c().await.is_ok() {
            signal_token.cancel();
        }
    });
    let result = execute(cli, cancel.clone()).await;
    signal.abort();
    if cancel.is_cancelled() {
        return ExitCode::from(130);
    }
    match result {
        Ok(()) => ExitCode::SUCCESS,
        Err(error) => {
            eprintln!("错误: {error:#}");
            ExitCode::FAILURE
        }
    }
}
async fn execute(cli: Cli, cancel: CancellationToken) -> Result<()> {
    if let Some(url) = &cli.protocol_callback {
        return pxder::callback::send(
            cli.callback_port.context("回调端口缺失")?,
            cli.callback_nonce.as_deref().context("回调 nonce 缺失")?,
            url,
        )
        .await;
    }
    let store = ConfigStore::discover(cli.config_dir)?;
    if cli.output_config_dir {
        println!("{}", store.dir.display());
        return Ok(());
    }
    let mut config = store.load()?;
    if cli.export_token {
        println!("{}", config.refresh_token.context("尚未登录")?);
        return Ok(());
    }
    if cli.logout {
        config.refresh_token = None;
        store.save(&config)?;
        println!("已登出");
        return Ok(());
    }
    if let Some(token) = cli.login {
        if !token.is_empty() {
            config.refresh_token = Some(token);
            Api::login(&config, Some(store), Endpoints::production()?, cancel, None).await?;
        } else {
            let pkce = Pkce::new();
            #[cfg(windows)]
            let receiver = if !cli.no_protocol {
                let mut receiver = pxder::callback::Receiver::bind().await?;
                receiver.register()?;
                Some(receiver)
            } else {
                None
            };
            println!("请在浏览器登录：\n{}", pkce.login_url);
            if !cli.no_protocol {
                let _ = webbrowser::open(&pkce.login_url);
            }
            #[cfg(windows)]
            let code = if let Some(receiver) = &receiver {
                println!("等待浏览器 pixiv:// 回调；Ctrl+C 取消");
                receiver.wait(&cancel).await?
            } else {
                parse_code(&read_input("粘贴回调 URL 或 code: ", true, &cancel).await?)?
            };
            #[cfg(not(windows))]
            let code = parse_code(&read_input("粘贴回调 URL 或 code: ", true, &cancel).await?)?;
            Api::login(
                &config,
                Some(store),
                Endpoints::production()?,
                cancel,
                Some((&code, &pkce.verifier)),
            )
            .await?;
        }
        println!("登录成功");
        return Ok(());
    }
    if cli.setting {
        let has_changes = cli.output_dir.is_some()
            || cli.threads.is_some()
            || cli.timeout.is_some()
            || cli.proxy.is_some()
            || cli.auto_rename.is_some();
        if let Some(path) = cli.output_dir {
            config.download.path = Some(path);
        }
        if let Some(value) = cli.threads {
            config.download.thread = value;
        }
        if let Some(value) = cli.timeout {
            config.download.timeout = value;
        }
        if let Some(value) = cli.proxy {
            config.proxy = Some(value);
        }
        if let Some(value) = cli.auto_rename {
            config.download.auto_rename = value;
        }
        if !has_changes {
            interactive_settings(&mut config, &cancel).await?;
        }
        store.save(&config)?;
        println!("设置已保存");
        return Ok(());
    }
    let source = if let Some(ids) = cli.uid {
        Some(Source::Uids(download::parse_ids(&ids)?))
    } else if let Some(ids) = cli.pid {
        Some(Source::Pids(download::parse_ids(&ids)?))
    } else if cli.follow || cli.follow_private {
        Some(Source::Following {
            private: cli.follow_private,
        })
    } else if cli.bookmark || cli.bookmark_private {
        Some(Source::Bookmarks {
            private: cli.bookmark_private,
        })
    } else if cli.update {
        Some(Source::Update)
    } else {
        None
    };
    let Some(source) = source else {
        return tui::run(store, cancel).await;
    };
    // CLI output override applies to this job, not to persisted settings.
    let mut job_config = config.clone();
    if let Some(path) = cli.output_dir {
        job_config.download.path = Some(path);
    }
    if job_config.download.path.is_none() {
        bail!("请用 --setting -O <目录> 设置下载目录，或用 -O 指定本次目录");
    }
    let api = Api::login(
        &config,
        Some(store),
        Endpoints::production()?,
        cancel.clone(),
        None,
    )
    .await?;
    let (progress, mut receiver) = Progress::new();
    let worker_cancel = cancel.clone();
    let task = download::run(
        api,
        job_config,
        Request {
            source,
            no_ugoira_meta: cli.no_ugoira_meta,
        },
        worker_cancel,
        progress,
    );
    tokio::pin!(task);
    let mut ticker = tokio::time::interval(Duration::from_secs(1));
    let summary = loop {
        tokio::select! {
            result = &mut task => break result?,
            _ = ticker.tick() => {
                let snapshot = receiver.borrow_and_update().clone();
                if cli.debug || std::io::stderr().is_terminal() {
                    eprintln!("完成 {}/{}{} · 成功 {} · 跳过 {} · 失败 {} · 来源错误 {}", snapshot.completed(), snapshot.queued, if snapshot.scanning { "+" } else { "" }, snapshot.succeeded, snapshot.skipped, snapshot.failed, snapshot.source_errors);
                }
            }
        }
    };
    println!(
        "成功 {}，跳过 {}，失败 {}，来源错误 {}，{} / {} 个文件",
        summary.succeeded,
        summary.skipped,
        summary.failed,
        summary.source_errors,
        summary.completed(),
        summary.queued
    );
    if summary.has_errors() || cli.debug {
        for line in &summary.logs {
            eprintln!("{line}");
        }
    }
    if summary.cancelled {
        bail!("下载已取消");
    }
    if summary.has_errors() {
        bail!("部分下载失败");
    }
    Ok(())
}
async fn read_input(prompt: &str, secret: bool, cancel: &CancellationToken) -> Result<String> {
    if !std::io::stdin().is_terminal() {
        bail!("交互输入需要终端；请传入 CLI 参数");
    }
    print!("{prompt}");
    std::io::stdout().flush()?;
    if secret {
        use crossterm::event::{Event, EventStream, KeyCode, KeyEventKind, KeyModifiers};
        struct RestoreInput;
        impl Drop for RestoreInput {
            fn drop(&mut self) {
                let _ = crossterm::terminal::disable_raw_mode();
            }
        }
        crossterm::terminal::enable_raw_mode()?;
        let restore = RestoreInput;
        let mut events = EventStream::new();
        let result = api::cancellable(cancel, async {
            let mut value = String::new();
            while let Some(event) = events.next().await {
                if let Event::Key(key) = event? {
                    if key.kind == KeyEventKind::Release {
                        continue;
                    }
                    match key.code {
                        KeyCode::Enter => return Ok(value),
                        KeyCode::Char('c') if key.modifiers.contains(KeyModifiers::CONTROL) => {
                            cancel.cancel();
                            bail!("输入已取消");
                        }
                        KeyCode::Char('u') if key.modifiers.contains(KeyModifiers::CONTROL) => {
                            value.clear()
                        }
                        KeyCode::Backspace => {
                            value.pop();
                        }
                        KeyCode::Char(c)
                            if !key
                                .modifiers
                                .intersects(KeyModifiers::CONTROL | KeyModifiers::ALT) =>
                        {
                            value.push(c)
                        }
                        _ => {}
                    }
                }
            }
            bail!("终端输入结束")
        })
        .await;
        drop(restore);
        println!();
        return result;
    }
    let (tx, rx) = tokio::sync::oneshot::channel();
    // A detached OS input thread avoids Tokio blocking-pool shutdown hanging on stdin.
    std::thread::spawn(move || {
        let mut value = String::new();
        let result = std::io::stdin()
            .read_line(&mut value)
            .map(|_| value.trim().to_owned());
        let _ = tx.send(result);
    });
    api::cancellable(cancel, async {
        Ok(rx.await.context("输入线程退出")??)
    })
    .await
}
async fn interactive_settings(config: &mut Config, cancel: &CancellationToken) -> Result<()> {
    println!("输入空行保留现有值。代理使用 disable 禁用，system 恢复环境代理。");
    let path = read_input(
        &format!(
            "下载目录 [{}]: ",
            config
                .download
                .path
                .as_ref()
                .map(|p| p.display().to_string())
                .unwrap_or_default()
        ),
        false,
        cancel,
    )
    .await?;
    if !path.is_empty() {
        config.download.path = Some(path.into());
    }
    let threads = read_input(
        &format!("并发数 [{}]: ", config.download.thread),
        false,
        cancel,
    )
    .await?;
    if !threads.is_empty() {
        config.download.thread = threads.parse().context("并发数无效")?;
    }
    let timeout = read_input(
        &format!("超时秒数 [{}]: ", config.download.timeout),
        false,
        cancel,
    )
    .await?;
    if !timeout.is_empty() {
        config.download.timeout = timeout.parse().context("超时无效")?;
    }
    let proxy = read_input("代理（输入隐藏）: ", true, cancel).await?;
    if !proxy.is_empty() {
        config.proxy = if proxy == "system" { None } else { Some(proxy) };
    }
    let rename = read_input(
        &format!("自动改名 true/false [{}]: ", config.download.auto_rename),
        false,
        cancel,
    )
    .await?;
    if !rename.is_empty() {
        config.download.auto_rename = rename.parse().context("自动改名必须为 true/false")?;
    }
    config.validate()
}

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn rejects_conflicting_commands_and_missing_arguments() {
        assert!(Cli::try_parse_from(["pxder", "-u", "1", "-p", "2"]).is_err());
        let login = Cli::try_parse_from(["pxder", "--login", ""]);
        assert!(login.is_ok(), "{:?}", login.err());
        assert!(Cli::try_parse_from(["pxder", "-p"]).is_err());
        assert!(
            Cli::try_parse_from(["pxder", "--setting", "--threads", "8", "-O", "images"]).is_ok()
        );
    }
}
