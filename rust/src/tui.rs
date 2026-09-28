use crate::{
    api::{Api, Endpoints},
    auth::{Pkce, parse_code},
    config::{Config, ConfigStore},
    download::{self, Progress, Request, Snapshot, Source},
};
use anyhow::{Context, Result, bail};
use crossterm::event::{Event, EventStream, KeyCode, KeyEvent, KeyEventKind, KeyModifiers};
use futures_util::StreamExt;
#[cfg(test)]
mod tests;
mod view;
use std::{
    io::IsTerminal,
    time::{Duration, Instant},
};
use tokio::{sync::watch, task::JoinHandle};
use tokio_util::sync::CancellationToken;
use view::draw;

#[derive(Clone, Copy, PartialEq)]
enum Screen {
    Dashboard,
    NewJob,
    Settings,
    Login,
    Token,
    Code,
    Help,
    Logs,
}
struct State {
    screen: Screen,
    fields: Vec<String>,
    selected: usize,
    source: usize,
    config: Config,
    message: String,
    pkce: Option<Pkce>,
    snapshot: Snapshot,
    busy: bool,
    started: Instant,
    cursor: usize,
    log_offset: usize,
    file_offset: usize,
    confirm: Option<Confirmation>,
    message_error: bool,
}
impl State {
    fn new(config: Config) -> Self {
        Self {
            screen: Screen::Dashboard,
            fields: vec![],
            selected: 0,
            source: 0,
            config,
            message: String::new(),
            pkce: None,
            snapshot: Snapshot::default(),
            busy: false,
            started: Instant::now(),
            cursor: 0,
            log_offset: 0,
            file_offset: 0,
            confirm: None,
            message_error: false,
        }
    }
    fn open(&mut self, screen: Screen) {
        self.screen = screen;
        self.message.clear();
        self.message_error = false;
        self.selected = 0;
        self.fields = match screen {
            Screen::NewJob => vec![String::new(), "false".into()],
            Screen::Settings => vec![
                self.config
                    .download
                    .path
                    .as_ref()
                    .map(|p| p.to_string_lossy().to_string())
                    .unwrap_or_default(),
                self.config.download.thread.to_string(),
                self.config.download.timeout.to_string(),
                self.config.proxy.clone().unwrap_or_default(),
                self.config.download.auto_rename.to_string(),
            ],
            Screen::Token | Screen::Code => vec![String::new()],
            _ => Vec::new(),
        };
        self.cursor = self
            .input_index()
            .map(|i| self.fields[i].chars().count())
            .unwrap_or(0);
    }
    fn input_index(&self) -> Option<usize> {
        match self.screen {
            Screen::NewJob if self.selected == 1 && self.source < 2 => Some(0),
            Screen::Settings if self.selected < 4 => Some(self.selected),
            Screen::Token | Screen::Code => Some(0),
            _ => None,
        }
    }
    fn focus_slots(&self) -> Vec<usize> {
        match self.screen {
            Screen::NewJob if self.source < 2 => vec![0, 1, 2],
            Screen::NewJob => vec![0, 2],
            Screen::Settings => vec![0, 1, 2, 3, 4],
            _ => vec![0],
        }
    }
    fn focus(&mut self, backwards: bool) {
        let slots = self.focus_slots();
        let current = slots.iter().position(|v| *v == self.selected).unwrap_or(0);
        self.selected =
            slots[(current + if backwards { slots.len() - 1 } else { 1 }) % slots.len()];
        self.cursor = self
            .input_index()
            .map(|i| self.fields[i].chars().count())
            .unwrap_or(0);
    }
    fn insert(&mut self, text: &str) {
        if let Some(index) = self.input_index() {
            let value = &mut self.fields[index];
            let clean: String = text
                .chars()
                .filter(|c| !c.is_control())
                .take(8192usize.saturating_sub(value.chars().count()))
                .collect();
            let at = value
                .char_indices()
                .nth(self.cursor)
                .map(|(i, _)| i)
                .unwrap_or(value.len());
            value.insert_str(at, &clean);
            self.cursor += clean.chars().count();
            self.message.clear();
            self.message_error = false;
        }
    }
    fn key(&mut self, key: KeyEvent) -> Action {
        if key.kind == KeyEventKind::Release {
            return Action::None;
        }
        if let Some(confirm) = self.confirm {
            return match key.code {
                KeyCode::Enter => {
                    self.confirm = None;
                    confirm.action()
                }
                KeyCode::Esc | KeyCode::Char('n') => {
                    self.confirm = None;
                    Action::None
                }
                _ => Action::None,
            };
        }
        if key.code == KeyCode::Char('c') && key.modifiers.contains(KeyModifiers::CONTROL) {
            if self.busy {
                self.confirm = Some(Confirmation::Quit);
                return Action::None;
            }
            return Action::Quit;
        }
        if key.code == KeyCode::Esc {
            self.pkce = None;
            self.open(Screen::Dashboard);
            return Action::None;
        }
        if matches!(self.screen, Screen::Dashboard | Screen::Help | Screen::Logs) {
            return match key.code {
                KeyCode::Char('q') if self.busy => {
                    self.confirm = Some(Confirmation::Quit);
                    Action::None
                }
                KeyCode::Char('q') => Action::Quit,
                KeyCode::Char('c') if self.busy => {
                    self.confirm = Some(Confirmation::Cancel);
                    Action::None
                }
                KeyCode::Char('n' | 's' | 'l') if self.busy => {
                    self.message = "任务正在运行；完成或取消后可新建任务、修改设置或账户".into();
                    self.message_error = false;
                    Action::None
                }
                KeyCode::Char('n') => {
                    self.open(Screen::NewJob);
                    Action::None
                }
                KeyCode::Char('s') => {
                    self.open(Screen::Settings);
                    Action::None
                }
                KeyCode::Char('l') => {
                    self.open(Screen::Login);
                    Action::None
                }
                KeyCode::Char('g') => {
                    self.open(Screen::Logs);
                    self.log_offset = 0;
                    Action::None
                }
                KeyCode::Char('?') => {
                    self.open(Screen::Help);
                    Action::None
                }
                KeyCode::Up | KeyCode::PageUp => {
                    if self.screen == Screen::Logs {
                        self.log_offset =
                            (self.log_offset + 1).min(self.snapshot.logs.len().saturating_sub(1));
                    } else {
                        self.file_offset = self.file_offset.saturating_sub(1);
                    }
                    Action::None
                }
                KeyCode::Down | KeyCode::PageDown => {
                    if self.screen == Screen::Logs {
                        self.log_offset = self.log_offset.saturating_sub(1);
                    } else {
                        self.file_offset = (self.file_offset + 1)
                            .min(self.snapshot.active.len().saturating_sub(1));
                    }
                    Action::None
                }
                KeyCode::End if self.screen == Screen::Logs => {
                    self.log_offset = 0;
                    Action::None
                }
                _ => Action::None,
            };
        }
        if self.screen == Screen::Login {
            return match key.code {
                KeyCode::Char('t') => {
                    self.open(Screen::Token);
                    Action::None
                }
                KeyCode::Char('o') | KeyCode::Enter => Action::OAuth,
                KeyCode::Char('x') if self.config.refresh_token.is_some() => {
                    self.confirm = Some(Confirmation::Logout);
                    Action::None
                }
                _ => Action::None,
            };
        }
        let toggle = match self.screen {
            Screen::NewJob if self.selected == 2 => Some(1),
            Screen::Settings if self.selected == 4 => Some(4),
            _ => None,
        };
        match key.code {
            KeyCode::Enter => return Action::Submit,
            KeyCode::Tab | KeyCode::Down => {
                self.focus(false);
                return Action::None;
            }
            KeyCode::BackTab | KeyCode::Up => {
                self.focus(true);
                return Action::None;
            }
            KeyCode::Left | KeyCode::Right
                if self.screen == Screen::NewJob && self.selected == 0 =>
            {
                self.source = (self.source + if key.code == KeyCode::Left { 6 } else { 1 }) % 7;
                self.message.clear();
                return Action::None;
            }
            KeyCode::Char(' ') | KeyCode::Left | KeyCode::Right if toggle.is_some() => {
                if let Some(index) = toggle {
                    self.fields[index] = (self.fields[index] != "true").to_string();
                }
                return Action::None;
            }
            _ => {}
        }
        if let Some(index) = self.input_index() {
            let len = self.fields[index].chars().count();
            self.cursor = self.cursor.min(len);
            match key.code {
                KeyCode::Left => self.cursor = self.cursor.saturating_sub(1),
                KeyCode::Right => self.cursor = (self.cursor + 1).min(len),
                KeyCode::Home => self.cursor = 0,
                KeyCode::End => self.cursor = len,
                KeyCode::Char('u') if key.modifiers.contains(KeyModifiers::CONTROL) => {
                    self.fields[index].clear();
                    self.cursor = 0;
                }
                KeyCode::Backspace if self.cursor > 0 => {
                    self.cursor -= 1;
                    let byte = self.fields[index]
                        .char_indices()
                        .nth(self.cursor)
                        .map(|(i, _)| i)
                        .unwrap_or(0);
                    self.fields[index].remove(byte);
                }
                KeyCode::Delete if self.cursor < len => {
                    let byte = self.fields[index]
                        .char_indices()
                        .nth(self.cursor)
                        .map(|(i, _)| i)
                        .unwrap_or(0);
                    self.fields[index].remove(byte);
                }
                KeyCode::Char(c)
                    if !key
                        .modifiers
                        .intersects(KeyModifiers::CONTROL | KeyModifiers::ALT) =>
                {
                    self.insert(&c.to_string())
                }
                _ => {}
            }
        }
        Action::None
    }
    fn request(&self) -> Result<Request> {
        let source = match self.source {
            0 => Source::Uids(download::parse_ids(&self.fields[0])?),
            1 => Source::Pids(download::parse_ids(&self.fields[0])?),
            2 => Source::Following { private: false },
            3 => Source::Following { private: true },
            4 => Source::Bookmarks { private: false },
            5 => Source::Bookmarks { private: true },
            _ => Source::Update,
        };
        Ok(Request {
            source,
            no_ugoira_meta: self.fields[1]
                .parse()
                .context("跳过动图元数据请填 true 或 false")?,
        })
    }
    fn settings(&self) -> Result<Config> {
        let mut config = self.config.clone();
        config.download.path = if self.fields[0].is_empty() {
            None
        } else {
            Some(self.fields[0].clone().into())
        };
        config.download.thread = self.fields[1].parse().context("并发数必须为整数")?;
        config.download.timeout = self.fields[2].parse().context("超时必须为整数")?;
        config.proxy = Some(self.fields[3].clone());
        config.download.auto_rename = self.fields[4]
            .parse()
            .context("自动改名请填 true 或 false")?;
        config.validate()?;
        Ok(config)
    }
}
#[derive(Clone, Copy)]
enum Confirmation {
    Quit,
    Cancel,
    Logout,
}
impl Confirmation {
    fn action(self) -> Action {
        match self {
            Self::Quit => Action::Quit,
            Self::Cancel => Action::Cancel,
            Self::Logout => Action::Logout,
        }
    }
}
enum Action {
    None,
    Quit,
    Cancel,
    Submit,
    OAuth,
    Logout,
}
enum JobResult {
    Download(Snapshot),
    Login,
}
struct Job {
    handle: JoinHandle<Result<JobResult>>,
    cancel: CancellationToken,
    progress: watch::Receiver<Snapshot>,
}
struct Restore;
impl Drop for Restore {
    fn drop(&mut self) {
        ratatui::restore();
    }
}

pub async fn run(store: ConfigStore, shutdown: CancellationToken) -> Result<()> {
    if !std::io::stdin().is_terminal() || !std::io::stdout().is_terminal() {
        bail!("TUI 需要交互终端；脚本请使用 --help 查看 CLI");
    }
    let mut state = State::new(store.load()?);
    let mut terminal = ratatui::try_init()?;
    let _restore = Restore;
    crossterm::execute!(std::io::stdout(), crossterm::event::EnableBracketedPaste)?;
    let mut events = EventStream::new();
    let mut ticker = tokio::time::interval(Duration::from_millis(100));
    let mut job: Option<Job> = None;
    let result: Result<()> = async {
        loop {
            if let Some(running) = &job {
                state.snapshot = running.progress.borrow().clone();
            }
            if job.as_ref().is_some_and(|j| j.handle.is_finished()) {
                let finished = job.take().context("后台任务缺失")?;
                state.busy = false;
                state.message = match finished.handle.await.context("后台任务异常")? {
                    Ok(JobResult::Login) => "登录成功".into(),
                    Ok(JobResult::Download(summary)) => {
                        state.snapshot = summary;
                        if state.snapshot.cancelled {
                            "任务已取消".into()
                        } else if state.snapshot.has_errors() {
                            "任务结束，部分操作失败；查看日志".into()
                        } else {
                            "下载完成".into()
                        }
                    }
                    Err(error) => {
                        state.snapshot.done = true;
                        state.snapshot.source_errors += 1;
                        format!("失败: {error:#}")
                    }
                };
                state.message_error = state.snapshot.has_errors();
                state.config = store.load()?;
            }
            terminal.draw(|f| draw(f, &state))?;
            let action = tokio::select! {
                _ = shutdown.cancelled() => Action::Quit,
                _ = ticker.tick() => Action::None,
                event = events.next() => match event {
                    Some(Ok(Event::Key(key))) => state.key(key),
                    Some(Ok(Event::Paste(text))) => {
                        if state.confirm.is_none() { state.insert(&text); }
                        Action::None
                    }
                    Some(Ok(_)) => Action::None,
                    Some(Err(error)) => return Err(error.into()),
                    None => Action::Quit,
                }
            };
            match action {
                Action::Quit => break,
                Action::Cancel => {
                    if let Some(job) = &job {
                        job.cancel.cancel();
                        state.message = "正在取消并等待任务退出…".into();
                    }
                }
                Action::OAuth => {
                    let pkce = Pkce::new();
                    #[cfg(windows)]
                    {
                        let setup: Result<crate::callback::Receiver> = async {
                            let mut receiver = crate::callback::Receiver::bind().await?;
                            receiver.register()?;
                            Ok(receiver)
                        }
                        .await;
                        if let Ok(receiver) = setup {
                            let _ = webbrowser::open(&pkce.login_url);
                            let cancel = CancellationToken::new();
                            let token = cancel.clone();
                            let (progress, rx) = Progress::new();
                            progress.log("等待浏览器 pixiv:// 登录回调");
                            let config = store.load()?;
                            let store = store.clone();
                            let handle = tokio::spawn(async move {
                                let code = receiver.wait(&token).await?;
                                Api::login(
                                    &config,
                                    Some(store),
                                    Endpoints::production()?,
                                    token,
                                    Some((&code, &pkce.verifier)),
                                )
                                .await?;
                                Ok(JobResult::Login)
                            });
                            job = Some(Job {
                                handle,
                                cancel,
                                progress: rx,
                            });
                            state.open(Screen::Dashboard);
                            state.busy = true;
                            state.started = Instant::now();
                            state.message = "等待浏览器登录 · c 取消".into();
                            continue;
                        }
                    }
                    let _ = webbrowser::open(&pkce.login_url);
                    state.open(Screen::Code);
                    state.pkce = Some(pkce);
                    state.message = "浏览器登录后粘贴 code 或完整回调 URL".into();
                }
                Action::Logout => {
                    let mut config = store.load()?;
                    config.refresh_token = None;
                    store.save(&config)?;
                    state.config = config;
                    state.open(Screen::Dashboard);
                    state.message = "已登出".into();
                }
                Action::Submit => {
                    let submission: Result<()> = (|| {
                        if state.screen == Screen::Settings {
                            let config = state.settings()?;
                            store.save(&config)?;
                            state.config = config;
                            state.open(Screen::Dashboard);
                            state.message = "设置已保存".into();
                            return Ok(());
                        }
                        let cancel = CancellationToken::new();
                        let (progress, rx) = Progress::new();
                        let mut config = store.load()?;
                        let store = store.clone();
                        let token = cancel.clone();
                        let endpoints = Endpoints::production()?;
                        let handle = match state.screen {
                            Screen::NewJob => {
                                let request = state.request().inspect_err(|_| {
                                    if state.source < 2 {
                                        state.selected = 1;
                                        state.cursor = state.fields[0].chars().count();
                                    }
                                })?;
                                if config.download.path.is_none() {
                                    bail!("请先设置下载目录");
                                }
                                if config.refresh_token.is_none() {
                                    bail!("请先登录");
                                }
                                tokio::spawn(async move {
                                    let api = Api::login(
                                        &config,
                                        Some(store),
                                        endpoints,
                                        token.clone(),
                                        None,
                                    )
                                    .await?;
                                    Ok(JobResult::Download(
                                        download::run(api, config, request, token, progress)
                                            .await?,
                                    ))
                                })
                            }
                            Screen::Token => {
                                let value = state.fields[0].trim();
                                if value.is_empty() {
                                    bail!("Token 不能为空");
                                }
                                config.refresh_token = Some(value.to_owned());
                                tokio::spawn(async move {
                                    Api::login(&config, Some(store), endpoints, token, None)
                                        .await?;
                                    Ok(JobResult::Login)
                                })
                            }
                            Screen::Code => {
                                let code = parse_code(&state.fields[0])?;
                                let pkce = state.pkce.take().context("请重新开始 OAuth 登录")?;
                                tokio::spawn(async move {
                                    Api::login(
                                        &config,
                                        Some(store),
                                        endpoints,
                                        token,
                                        Some((&code, &pkce.verifier)),
                                    )
                                    .await?;
                                    Ok(JobResult::Login)
                                })
                            }
                            _ => return Ok(()),
                        };
                        job = Some(Job {
                            handle,
                            cancel,
                            progress: rx,
                        });
                        state.open(Screen::Dashboard);
                        state.busy = true;
                        state.started = Instant::now();
                        state.message = "任务运行中 · c 取消".into();
                        Ok(())
                    })();
                    if let Err(error) = submission {
                        state.message = format!("{error:#}");
                        state.message_error = true;
                    }
                }
                Action::None => {}
            }
        }
        Ok(())
    }
    .await;
    if let Some(job) = job {
        job.cancel.cancel();
        let _ = job.handle.await;
    }
    let _ = crossterm::execute!(std::io::stdout(), crossterm::event::DisableBracketedPaste);
    result
}

const SOURCES: [&str; 7] = [
    "画师 UID",
    "作品 PID",
    "公开关注",
    "私密关注",
    "公开收藏",
    "私密收藏",
    "增量更新",
];
