use crate::{
    config::{Config, ConfigStore},
    model::{Illust, UgoiraMetadata, User},
};
use anyhow::{Context, Result, bail};
use futures_util::StreamExt;
use md5::{Digest, Md5};
use reqwest::{Client, Response, StatusCode};
use serde::{Deserialize, de::DeserializeOwned};
use std::{
    future::Future,
    sync::Arc,
    time::{Duration, Instant},
};
use tokio::sync::Mutex;
use tokio_util::sync::CancellationToken;
use url::Url;

const CLIENT_ID: &str = "MOBrBDS8blbauoSck0ZfDbtuzpyT";
const CLIENT_SECRET: &str = "lsACyCD94FhDUtGTXi3QzcFE2uU1hqtDaKeqrdwj";
const HASH_SECRET: &str = "28c1fdd170a5204386cb1313c7077b34f83e4aaf4aa829ce78c231e05b0bae2c";
pub const USER_AGENT: &str = "PixivAndroidApp/5.0.234 (Android 9.0; Pixel 3)";
pub const RETRIES: usize = 3;

pub async fn cancellable<T>(
    cancel: &CancellationToken,
    future: impl Future<Output = Result<T>>,
) -> Result<T> {
    tokio::select! { biased; _ = cancel.cancelled() => bail!("操作已取消"), result = future => result }
}
pub async fn delay(cancel: &CancellationToken, duration: Duration) -> Result<()> {
    cancellable(cancel, async {
        tokio::time::sleep(duration).await;
        Ok(())
    })
    .await
}
pub fn retryable(status: StatusCode) -> bool {
    status == StatusCode::TOO_MANY_REQUESTS
        || status == StatusCode::REQUEST_TIMEOUT
        || status.is_server_error()
}
pub fn retry_delay(response: &Response, attempt: usize) -> Duration {
    if let Some(text) = response
        .headers()
        .get("retry-after")
        .and_then(|v| v.to_str().ok())
    {
        if let Ok(seconds) = text.parse::<u64>() {
            return Duration::from_secs(seconds.min(3600));
        }
        if let Ok(time) = chrono::DateTime::parse_from_rfc2822(text) {
            return Duration::from_secs(
                (time.timestamp() - chrono::Utc::now().timestamp()).clamp(0, 3600) as u64,
            );
        }
    }
    if response.status() == StatusCode::TOO_MANY_REQUESTS {
        Duration::from_secs(60)
    } else {
        backoff(attempt)
    }
}
pub fn backoff(attempt: usize) -> Duration {
    Duration::from_millis(250 * (1 << attempt.min(6)) + rand::random::<u8>() as u64)
}

pub fn http_client(config: &Config) -> Result<Client> {
    config.validate()?;
    let mut builder = Client::builder()
        .user_agent(USER_AGENT)
        .connect_timeout(Duration::from_secs(config.download.timeout.min(15)))
        .timeout(Duration::from_secs(config.download.timeout))
        .pool_idle_timeout(Duration::from_secs(90))
        .redirect(reqwest::redirect::Policy::none());
    if let Some(proxy) = config.proxy.as_deref().filter(|s| !s.is_empty()) {
        if proxy == "disable" {
            builder = builder.no_proxy();
        } else {
            builder = builder
                .proxy(reqwest::Proxy::all(proxy).map_err(|_| anyhow::anyhow!("代理配置无效"))?);
        }
    }
    builder.build().context("创建 HTTP 客户端失败")
}

#[derive(Clone)]
pub struct Endpoints {
    pub api: Url,
    pub oauth: Url,
}
impl Endpoints {
    pub fn production() -> Result<Self> {
        Ok(Self {
            api: Url::parse("https://app-api.pixiv.net/")?,
            oauth: Url::parse("https://oauth.secure.pixiv.net/auth/token")?,
        })
    }
}
#[derive(Deserialize)]
struct TokenUser {
    id: serde_json::Value,
}
#[derive(Deserialize)]
struct TokenResponse {
    access_token: String,
    refresh_token: String,
    #[serde(default = "default_expiry")]
    expires_in: u64,
    user: Option<TokenUser>,
}
fn default_expiry() -> u64 {
    3600
}
struct TokenState {
    access: String,
    refresh: String,
    expires: Instant,
    user_id: Option<u64>,
}

#[derive(Clone)]
pub struct Api {
    pub http: Client,
    endpoints: Endpoints,
    tokens: Arc<Mutex<TokenState>>,
    store: Option<ConfigStore>,
    cancel: CancellationToken,
}
#[derive(Deserialize)]
pub struct IllustPage {
    pub illusts: Vec<Illust>,
    pub next_url: Option<String>,
}
#[derive(Deserialize)]
pub struct FollowingEntry {
    pub user: User,
}
#[derive(Deserialize)]
pub struct FollowingPage {
    pub user_previews: Vec<FollowingEntry>,
    pub next_url: Option<String>,
}
#[derive(Deserialize)]
struct Detail {
    illust: Illust,
}
#[derive(Deserialize)]
struct UserDetail {
    user: User,
}
#[derive(Deserialize)]
struct Metadata {
    ugoira_metadata: UgoiraMetadata,
}

impl Api {
    pub async fn login(
        config: &Config,
        store: Option<ConfigStore>,
        endpoints: Endpoints,
        cancel: CancellationToken,
        code: Option<(&str, &str)>,
    ) -> Result<Self> {
        let http = http_client(config)?;
        let fields = if let Some((code, verifier)) = code {
            vec![
                ("grant_type", "authorization_code"),
                ("code", code),
                ("code_verifier", verifier),
                (
                    "redirect_uri",
                    "https://app-api.pixiv.net/web/v1/users/auth/pixiv/callback",
                ),
            ]
        } else {
            vec![
                ("grant_type", "refresh_token"),
                (
                    "refresh_token",
                    config
                        .refresh_token
                        .as_deref()
                        .filter(|s| !s.is_empty())
                        .context("请先登录")?,
                ),
            ]
        };
        let token = exchange(&http, &endpoints.oauth, fields, &cancel).await?;
        let state = token_state(token)?;
        persist_token(store.as_ref(), config, &state.refresh)?;
        Ok(Self {
            http,
            endpoints,
            tokens: Arc::new(Mutex::new(state)),
            store,
            cancel,
        })
    }
    async fn access_token(&self, force: bool) -> Result<String> {
        let mut state = cancellable(&self.cancel, async { Ok(self.tokens.lock().await) }).await?;
        if force || Instant::now() >= state.expires {
            let token = exchange(
                &self.http,
                &self.endpoints.oauth,
                vec![
                    ("grant_type", "refresh_token"),
                    ("refresh_token", &state.refresh),
                ],
                &self.cancel,
            )
            .await?;
            let new_state = token_state(token)?;
            if let Some(store) = &self.store {
                persist_token(Some(store), &store.load()?, &new_state.refresh)?;
            }
            *state = new_state;
        }
        Ok(state.access.clone())
    }
    pub async fn user_id(&self) -> Result<u64> {
        self.tokens
            .lock()
            .await
            .user_id
            .context("登录响应缺少用户 ID，请重新登录")
    }
    pub fn endpoint(&self, path: &str) -> Result<Url> {
        let url = self.endpoints.api.join(path)?;
        if url.origin() != self.endpoints.api.origin() {
            bail!("拒绝向非 Pixiv API 地址发送认证信息");
        }
        Ok(url)
    }
    pub async fn get<T: DeserializeOwned>(&self, url: Url) -> Result<T> {
        if url.origin() != self.endpoints.api.origin() {
            bail!("分页地址不属于 Pixiv API");
        }
        let mut refreshed = false;
        for attempt in 0..=RETRIES {
            let token = self.access_token(false).await?;
            let request = signed(self.http.get(url.clone())).bearer_auth(token);
            let response = cancellable(&self.cancel, async {
                request.send().await.map_err(|e| e.without_url().into())
            })
            .await;
            let response = match response {
                Ok(response) => response,
                Err(_) if !self.cancel.is_cancelled() && attempt < RETRIES => {
                    delay(&self.cancel, backoff(attempt)).await?;
                    continue;
                }
                Err(error) => return Err(error).context("API 请求失败"),
            };
            if response.status() == StatusCode::UNAUTHORIZED && !refreshed && attempt < RETRIES {
                self.access_token(true).await?;
                refreshed = true;
                continue;
            }
            if retryable(response.status()) && attempt < RETRIES {
                delay(&self.cancel, retry_delay(&response, attempt)).await?;
                continue;
            }
            let status = response.status();
            let body = read_body(response, &self.cancel).await?;
            // Pixiv sometimes returns rate limiting as a JSON error with HTTP 400.
            if body.windows(10).any(|w| w == b"rate limit") && attempt < RETRIES {
                delay(&self.cancel, Duration::from_secs(60)).await?;
                continue;
            }
            if !status.is_success() {
                bail!("Pixiv API 返回 HTTP {status}");
            }
            return serde_json::from_slice(&body).context("Pixiv API 响应格式不匹配");
        }
        bail!("API 重试次数已耗尽")
    }
    pub async fn detail(&self, pid: u64) -> Result<Illust> {
        Ok(self
            .get::<Detail>(self.endpoint(&format!("/v1/illust/detail?illust_id={pid}"))?)
            .await?
            .illust)
    }
    pub async fn user(&self, uid: u64) -> Result<User> {
        Ok(self
            .get::<UserDetail>(self.endpoint(&format!("/v1/user/detail?user_id={uid}"))?)
            .await?
            .user)
    }
    pub async fn metadata(&self, pid: u64) -> Result<UgoiraMetadata> {
        Ok(self
            .get::<Metadata>(self.endpoint(&format!("/v1/ugoira/metadata?illust_id={pid}"))?)
            .await?
            .ugoira_metadata)
    }
}

fn signed(builder: reqwest::RequestBuilder) -> reqwest::RequestBuilder {
    let time = chrono::Utc::now()
        .format("%Y-%m-%dT%H:%M:%S+00:00")
        .to_string();
    let hash = format!("{:x}", Md5::digest(format!("{time}{HASH_SECRET}")));
    builder
        .header("App-OS", "android")
        .header("App-OS-Version", "9.0")
        .header("App-Version", "5.0.234")
        .header("Accept-Language", "en-us")
        .header("X-Client-Time", time)
        .header("X-Client-Hash", hash)
}
async fn exchange(
    http: &Client,
    endpoint: &Url,
    mut fields: Vec<(&str, &str)>,
    cancel: &CancellationToken,
) -> Result<TokenResponse> {
    fields.extend([("client_id", CLIENT_ID), ("client_secret", CLIENT_SECRET)]);
    let response = cancellable(cancel, async {
        signed(http.post(endpoint.clone()))
            .form(&fields)
            .send()
            .await
            .map_err(|e| e.without_url().into())
    })
    .await?;
    if !response.status().is_success() {
        bail!("登录/刷新令牌失败，HTTP {}", response.status());
    }
    let body = read_body(response, cancel).await?;
    serde_json::from_slice(&body).context("令牌响应格式不匹配")
}
fn token_state(token: TokenResponse) -> Result<TokenState> {
    if token.access_token.is_empty() || token.refresh_token.is_empty() {
        bail!("服务返回了空令牌");
    }
    let user_id = token
        .user
        .and_then(|u| {
            u.id.as_u64()
                .or_else(|| u.id.as_str().and_then(|s| s.parse().ok()))
        })
        .or_else(|| {
            use base64::Engine;
            let part = token.access_token.split('.').nth(1)?;
            let raw = base64::engine::general_purpose::URL_SAFE_NO_PAD
                .decode(part)
                .ok()?;
            let value: serde_json::Value = serde_json::from_slice(&raw).ok()?;
            value.get("user")?.get("id")?.as_u64()
        });
    Ok(TokenState {
        access: token.access_token,
        refresh: token.refresh_token,
        expires: Instant::now()
            + Duration::from_secs(token.expires_in.saturating_sub(60).clamp(1, 86400)),
        user_id,
    })
}
fn persist_token(store: Option<&ConfigStore>, config: &Config, refresh: &str) -> Result<()> {
    if let Some(store) = store {
        let mut updated = config.clone();
        updated.refresh_token = Some(refresh.to_owned());
        store.save(&updated)?;
    }
    Ok(())
}
async fn read_body(response: Response, cancel: &CancellationToken) -> Result<Vec<u8>> {
    cancellable(cancel, async {
        let mut stream = response.bytes_stream();
        let mut body = Vec::new();
        while let Some(chunk) = stream.next().await {
            let chunk = chunk.map_err(|e| e.without_url())?;
            if body.len() + chunk.len() > 16 * 1024 * 1024 {
                bail!("API 响应超过 16 MiB 限制");
            }
            body.extend_from_slice(&chunk);
        }
        Ok(body)
    })
    .await
}
