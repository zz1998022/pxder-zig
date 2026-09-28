use crate::{
    api::{self, Api, FollowingPage, IllustPage},
    config::Config,
    model::{self, DownloadTask, Illust, User},
};
use anyhow::{Context, Result, bail};
use fs2::FileExt;
use futures_util::StreamExt;
use std::{
    collections::{BTreeMap, HashSet, VecDeque},
    fs::OpenOptions,
    path::{Path, PathBuf},
    time::Instant,
};
use tokio::{
    io::AsyncWriteExt,
    sync::{mpsc, watch},
    task::JoinSet,
};
use tokio_util::sync::CancellationToken;

#[derive(Clone, Debug)]
pub enum Source {
    Uids(Vec<u64>),
    Pids(Vec<u64>),
    Following { private: bool },
    Bookmarks { private: bool },
    Update,
}
#[derive(Clone, Debug)]
pub struct Request {
    pub source: Source,
    pub no_ugoira_meta: bool,
}
#[derive(Clone, Debug, Default)]
pub struct Snapshot {
    pub queued: u64,
    pub succeeded: u64,
    pub skipped: u64,
    pub failed: u64,
    pub source_errors: u64,
    pub bytes: u64,
    pub scanning: bool,
    pub done: bool,
    pub cancelled: bool,
    pub active: BTreeMap<String, u64>,
    pub logs: VecDeque<String>,
}
impl Snapshot {
    pub fn completed(&self) -> u64 {
        self.succeeded + self.skipped + self.failed
    }
    pub fn has_errors(&self) -> bool {
        self.failed > 0 || self.source_errors > 0
    }
}
#[derive(Clone)]
pub struct Progress(watch::Sender<Snapshot>);
impl Progress {
    pub fn new() -> (Self, watch::Receiver<Snapshot>) {
        let (tx, rx) = watch::channel(Snapshot {
            scanning: true,
            ..Snapshot::default()
        });
        (Self(tx), rx)
    }
    pub fn snapshot(&self) -> Snapshot {
        self.0.borrow().clone()
    }
    pub fn log(&self, message: impl Into<String>) {
        self.0.send_modify(|s| {
            s.logs.push_back(message.into());
            while s.logs.len() > 100 {
                s.logs.pop_front();
            }
        });
    }
    fn source_error(&self, error: &anyhow::Error) {
        self.0.send_modify(|s| s.source_errors += 1);
        self.log(format!("来源失败: {error:#}"));
    }
}

pub async fn run(
    api: Api,
    config: Config,
    request: Request,
    cancel: CancellationToken,
    progress: Progress,
) -> Result<Snapshot> {
    config.validate()?;
    let base = config.download.path.as_ref().context("请先设置下载目录")?;
    tokio::fs::create_dir_all(base)
        .await
        .context("创建下载目录失败")?;
    let lock = OpenOptions::new()
        .create(true)
        .truncate(false)
        .read(true)
        .write(true)
        .open(base.join(".pxder.lock"))?;
    lock.try_lock_exclusive()
        .context("此目录已有 pxder 下载任务运行")?;
    let (tx, rx) = mpsc::channel(config.download.thread * 4);
    progress.log("开始获取作品列表");
    let produce = async {
        let result = produce(&api, &config, &request, &tx, &cancel, &progress).await;
        if let Err(error) = result
            && !cancel.is_cancelled()
        {
            progress.source_error(&error);
        }
        drop(tx);
        progress.0.send_modify(|s| s.scanning = false);
    };
    let consume = consume(
        api.http.clone(),
        rx,
        config.download.thread,
        &cancel,
        &progress,
    );
    tokio::join!(produce, consume);
    progress.0.send_modify(|s| {
        s.done = true;
        s.cancelled = cancel.is_cancelled();
        s.active.clear();
    });
    progress.log(if cancel.is_cancelled() {
        "任务已取消，已完成文件保留"
    } else {
        "任务结束"
    });
    drop(lock);
    Ok(progress.snapshot())
}

async fn produce(
    api: &Api,
    config: &Config,
    request: &Request,
    tx: &mpsc::Sender<DownloadTask>,
    cancel: &CancellationToken,
    progress: &Progress,
) -> Result<()> {
    let base = config.download.path.as_ref().context("下载目录未设置")?;
    match &request.source {
        Source::Pids(ids) => {
            for pid in ids {
                if cancel.is_cancelled() {
                    break;
                }
                let result = async {
                    let illust = api.detail(*pid).await?;
                    queue_illust(
                        api,
                        request,
                        illust,
                        &base.join(pid.to_string()),
                        tx,
                        cancel,
                        progress,
                    )
                    .await
                }
                .await;
                if let Err(error) = result
                    && !cancel.is_cancelled()
                {
                    progress.source_error(&error);
                }
            }
        }
        Source::Uids(ids) => {
            for uid in ids {
                if cancel.is_cancelled() {
                    break;
                }
                let result = async {
                    let user = api.user(*uid).await?;
                    queue_artist(api, config, request, user, tx, cancel, progress).await
                }
                .await;
                if let Err(error) = result
                    && !cancel.is_cancelled()
                {
                    progress.source_error(&error);
                }
            }
        }
        Source::Update => {
            let mut dir = tokio::fs::read_dir(base).await?;
            let mut ids = HashSet::new();
            while let Some(entry) = dir.next_entry().await? {
                if cancel.is_cancelled() {
                    break;
                }
                if !entry.file_type().await?.is_dir() {
                    continue;
                }
                if let Some(uid) = model::artist_uid(&entry.file_name().to_string_lossy()) {
                    if !ids.insert(uid) {
                        continue;
                    }
                    let result = async {
                        queue_artist(
                            api,
                            config,
                            request,
                            api.user(uid).await?,
                            tx,
                            cancel,
                            progress,
                        )
                        .await
                    }
                    .await;
                    if let Err(error) = result
                        && !cancel.is_cancelled()
                    {
                        progress.source_error(&error);
                    }
                }
            }
            if ids.is_empty() {
                progress.log("没有找到 (UID)画师名 格式的目录");
            }
        }
        Source::Bookmarks { private } => {
            let user_id = api.user_id().await?;
            let restrict = if *private { "private" } else { "public" };
            let dir = base.join(if *private {
                "[bookmark] Private"
            } else {
                "[bookmark] Public"
            });
            let url = api.endpoint(&format!(
                "/v1/user/bookmarks/illust?user_id={user_id}&restrict={restrict}"
            ))?;
            queue_pages(api, request, url, &dir, tx, cancel, progress).await?;
        }
        Source::Following { private } => {
            let user_id = api.user_id().await?;
            let restrict = if *private { "private" } else { "public" };
            let mut next = Some(api.endpoint(&format!(
                "/v1/user/following?user_id={user_id}&restrict={restrict}"
            ))?);
            let mut pages = HashSet::new();
            let mut artists = HashSet::new();
            while let Some(url) = next {
                if !pages.insert(url.to_string()) {
                    bail!("关注分页出现循环");
                }
                let page: FollowingPage = api.get(url).await?;
                for item in page.user_previews {
                    if cancel.is_cancelled() {
                        return Ok(());
                    }
                    if !artists.insert(item.user.id) {
                        continue;
                    }
                    if let Err(error) =
                        queue_artist(api, config, request, item.user, tx, cancel, progress).await
                        && !cancel.is_cancelled()
                    {
                        progress.source_error(&error);
                    }
                }
                next = page.next_url.map(|u| api.endpoint(&u)).transpose()?;
            }
        }
    }
    Ok(())
}

async fn artist_dir(base: &Path, user: &User, rename: bool) -> Result<PathBuf> {
    let expected = base.join(format!(
        "({}){}",
        user.id,
        model::sanitize_artist(&user.name)
    ));
    let mut entries = tokio::fs::read_dir(base).await?;
    while let Some(entry) = entries.next_entry().await? {
        if !entry.file_type().await?.is_dir()
            || model::artist_uid(&entry.file_name().to_string_lossy()) != Some(user.id)
        {
            continue;
        }
        let old = entry.path();
        if rename && old != expected {
            if tokio::fs::try_exists(&expected).await? {
                bail!("画师改名目标目录已存在，未覆盖");
            }
            tokio::fs::rename(&old, &expected)
                .await
                .context("画师目录改名失败")?;
            return Ok(expected);
        }
        return Ok(old);
    }
    tokio::fs::create_dir_all(&expected).await?;
    Ok(expected)
}
async fn queue_artist(
    api: &Api,
    config: &Config,
    request: &Request,
    user: User,
    tx: &mpsc::Sender<DownloadTask>,
    cancel: &CancellationToken,
    progress: &Progress,
) -> Result<()> {
    let dir = artist_dir(
        config.download.path.as_ref().context("下载目录未设置")?,
        &user,
        config.download.auto_rename,
    )
    .await?;
    progress.log(format!("画师 {} · {}", user.id, user.name));
    queue_pages(
        api,
        request,
        api.endpoint(&format!("/v1/user/illusts?user_id={}", user.id))?,
        &dir,
        tx,
        cancel,
        progress,
    )
    .await
}
async fn queue_pages(
    api: &Api,
    request: &Request,
    url: url::Url,
    dir: &Path,
    tx: &mpsc::Sender<DownloadTask>,
    cancel: &CancellationToken,
    progress: &Progress,
) -> Result<()> {
    let mut next = Some(url);
    let mut seen = HashSet::new();
    while let Some(url) = next {
        if !seen.insert(url.to_string()) {
            bail!("作品分页出现循环");
        }
        let page: IllustPage = api.get(url).await?;
        for illust in page.illusts {
            queue_illust(api, request, illust, dir, tx, cancel, progress).await?;
        }
        next = page.next_url.map(|u| api.endpoint(&u)).transpose()?;
    }
    Ok(())
}
async fn queue_illust(
    api: &Api,
    request: &Request,
    illust: Illust,
    dir: &Path,
    tx: &mpsc::Sender<DownloadTask>,
    cancel: &CancellationToken,
    progress: &Progress,
) -> Result<()> {
    let metadata = if illust.is_ugoira() && !request.no_ugoira_meta {
        Some(api.metadata(illust.id).await?)
    } else {
        None
    };
    for task in illust.tasks(dir, metadata)? {
        // Count before send: a worker can finish immediately after receiving.
        progress.0.send_modify(|s| s.queued += 1);
        let sent = api::cancellable(cancel, async {
            tx.send(task).await.context("下载队列已关闭")
        })
        .await;
        if let Err(error) = sent {
            progress.0.send_modify(|s| s.queued -= 1);
            return Err(error);
        }
    }
    Ok(())
}

async fn consume(
    http: reqwest::Client,
    mut rx: mpsc::Receiver<DownloadTask>,
    concurrency: usize,
    cancel: &CancellationToken,
    progress: &Progress,
) {
    let mut workers = JoinSet::new();
    loop {
        tokio::select! {
            biased;
            _ = cancel.cancelled() => { rx.close(); break; }
            result = workers.join_next(), if !workers.is_empty() => {
                if let Some(Err(error)) = result { progress.source_error(&anyhow::anyhow!("下载 worker 异常: {error}")); }
            }
            task = rx.recv(), if workers.len() < concurrency => {
                let Some(task) = task else { break };
                let http = http.clone(); let cancel = cancel.clone(); let progress = progress.clone();
                workers.spawn(async move { transfer(http, task, cancel, progress).await; });
            }
        }
    }
    while let Some(result) = workers.join_next().await {
        if let Err(error) = result {
            progress.source_error(&anyhow::anyhow!("下载 worker 异常: {error}"));
        }
    }
}

async fn transfer(
    http: reqwest::Client,
    task: DownloadTask,
    cancel: CancellationToken,
    progress: Progress,
) {
    let key = task.path.to_string_lossy().to_string();
    progress.0.send_modify(|s| {
        s.active.insert(key.clone(), 0);
    });
    let result = download_file(&http, &task, &cancel, &progress).await;
    progress.0.send_modify(|s| {
        s.active.remove(&key);
        match &result {
            Ok(true) => s.succeeded += 1,
            Ok(false) => s.skipped += 1,
            Err(_) if cancel.is_cancelled() => {}
            Err(_) => s.failed += 1,
        }
    });
    if let Err(error) = result
        && !cancel.is_cancelled()
    {
        progress.log(format!("PID {} 失败: {error:#}", task.pid));
    }
}

/// Returns true when published, false for existing files or HTTP 404.
pub async fn download_file(
    http: &reqwest::Client,
    task: &DownloadTask,
    cancel: &CancellationToken,
    progress: &Progress,
) -> Result<bool> {
    let parent = task.path.parent().context("下载路径缺少父目录")?;
    tokio::fs::create_dir_all(parent).await?;
    if let Ok(meta) = tokio::fs::symlink_metadata(&task.path).await {
        if meta.file_type().is_symlink() || !meta.is_file() {
            bail!("目标路径不是普通文件");
        }
        if meta.len() > 0 {
            save_frames(task)?;
            return Ok(false);
        }
        bail!("目标文件为空，请移走后重试: {}", task.path.display());
    }
    let mut last_error = anyhow::anyhow!("下载失败");
    for attempt in 0..=10 {
        let result = api::cancellable(cancel, async {
            let response = http
                .get(&task.url)
                .header("Referer", "https://www.pixiv.net/")
                .send()
                .await
                .map_err(|e| e.without_url())?;
            if response.status() == reqwest::StatusCode::NOT_FOUND {
                return Ok(Attempt::Skip);
            }
            if api::retryable(response.status()) {
                return Ok(Attempt::Retry(
                    api::retry_delay(&response, attempt),
                    anyhow::anyhow!("HTTP {}", response.status()),
                ));
            }
            if !response.status().is_success() {
                return Ok(Attempt::Fatal(anyhow::anyhow!(
                    "HTTP {}",
                    response.status()
                )));
            }
            let expected = response.content_length();
            let (file, temp_path) = tempfile::NamedTempFile::new_in(parent)?.into_parts();
            let mut file = tokio::fs::File::from_std(file);
            let mut body = response.bytes_stream();
            let mut written = 0;
            let mut reported = 0;
            let mut last_report = Instant::now();
            let key = task.path.to_string_lossy().to_string();
            while let Some(chunk) = body.next().await {
                let chunk = chunk.map_err(|e| e.without_url())?;
                file.write_all(&chunk).await?;
                written += chunk.len() as u64;
                if last_report.elapsed().as_millis() >= 100 {
                    progress.0.send_modify(|s| {
                        s.bytes += written - reported;
                        s.active.insert(key.clone(), written);
                    });
                    reported = written;
                    last_report = Instant::now();
                }
            }
            if written == 0 || expected.is_some_and(|n| n != written) {
                bail!("响应长度不完整或为空");
            }
            file.flush().await?;
            file.sync_all().await?;
            drop(file);
            progress.0.send_modify(|s| s.bytes += written - reported);
            match temp_path.persist_noclobber(&task.path) {
                Ok(()) => {
                    save_frames(task)?;
                    Ok(Attempt::Published)
                }
                Err(error) if error.error.kind() == std::io::ErrorKind::AlreadyExists => {
                    let meta = tokio::fs::symlink_metadata(&task.path).await?;
                    if !meta.is_file() || meta.len() == 0 {
                        bail!("目标文件冲突且无效");
                    }
                    save_frames(task)?;
                    Ok(Attempt::Skip)
                }
                Err(error) => Err(error.error).context("发布下载文件失败"),
            }
        })
        .await;
        let wait = match result {
            Ok(Attempt::Published) => return Ok(true),
            Ok(Attempt::Skip) => return Ok(false),
            Ok(Attempt::Fatal(error)) => return Err(error),
            Ok(Attempt::Retry(wait, error)) => {
                last_error = error;
                wait
            }
            Err(error) if cancel.is_cancelled() => return Err(error),
            Err(error) => {
                last_error = error;
                api::backoff(attempt)
            }
        };
        if attempt < 10 {
            progress.log(format!(
                "PID {} 重试 {}/10，等待 {:.1}s",
                task.pid,
                attempt + 1,
                wait.as_secs_f32()
            ));
            api::delay(cancel, wait).await?;
        }
    }
    Err(last_error).context("文件重试次数已耗尽")
}
enum Attempt {
    Published,
    Skip,
    Fatal(anyhow::Error),
    Retry(std::time::Duration, anyhow::Error),
}
fn save_frames(task: &DownloadTask) -> Result<()> {
    if let Some(frames) = &task.frames {
        crate::config::atomic_write(
            &task.path.with_extension("frames.json"),
            &serde_json::to_vec_pretty(frames)?,
        )?;
    }
    Ok(())
}

pub fn parse_ids(value: &str) -> Result<Vec<u64>> {
    let mut seen = HashSet::new();
    let mut ids = Vec::new();
    for part in value.split(',') {
        let id: u64 = part.trim().parse().context("ID 必须为逗号分隔的正整数")?;
        if id == 0 {
            bail!("ID 必须大于 0");
        }
        if seen.insert(id) {
            ids.push(id);
        }
    }
    if ids.is_empty() {
        bail!("至少需要一个 ID");
    }
    Ok(ids)
}
