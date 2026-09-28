//! Short-lived loopback callback. Only the active login nonce is accepted.
use crate::{api, auth::parse_code};
use anyhow::{Context, Result, bail};
use serde::{Deserialize, Serialize};
use std::time::Duration;
use tokio::{
    io::{AsyncBufReadExt, AsyncWriteExt, BufReader},
    net::{TcpListener, TcpStream},
};
use tokio_util::sync::CancellationToken;

#[derive(Serialize, Deserialize)]
struct Message {
    nonce: String,
    url: String,
}
pub struct Receiver {
    listener: TcpListener,
    nonce: String,
    #[cfg(windows)]
    registration: Option<std::sync::Mutex<windows::Registration>>,
}
impl Receiver {
    pub async fn bind() -> Result<Self> {
        Ok(Self {
            listener: TcpListener::bind("127.0.0.1:0").await?,
            nonce: format!("{:032x}", rand::random::<u128>()),
            #[cfg(windows)]
            registration: None,
        })
    }
    pub fn port(&self) -> Result<u16> {
        Ok(self.listener.local_addr()?.port())
    }
    pub fn nonce(&self) -> &str {
        &self.nonce
    }
    #[cfg(windows)]
    pub fn register(&mut self) -> Result<()> {
        self.registration = Some(std::sync::Mutex::new(windows::Registration::new(
            self.port()?,
            &self.nonce,
        )?));
        Ok(())
    }
    pub async fn wait(&self, cancel: &CancellationToken) -> Result<String> {
        api::cancellable(cancel, async {
            tokio::time::timeout(Duration::from_secs(300), async {
                loop {
                    let (socket, _) = self.listener.accept().await?;
                    let mut reader = BufReader::new(socket);
                    let mut bytes = Vec::new();
                    // Cap input before allocating an arbitrary callback line.
                    let receive = async {
                        loop {
                            let buf = reader.fill_buf().await?;
                            if buf.is_empty() {
                                break;
                            }
                            let n = buf
                                .iter()
                                .position(|b| *b == b'\n')
                                .map(|n| n + 1)
                                .unwrap_or(buf.len());
                            if bytes.len() + n > 8192 {
                                bail!("回调过长");
                            }
                            let done = buf[n - 1] == b'\n';
                            bytes.extend_from_slice(&buf[..n]);
                            reader.consume(n);
                            if done {
                                break;
                            }
                        }
                        Ok::<_, anyhow::Error>(())
                    };
                    if !matches!(
                        tokio::time::timeout(Duration::from_secs(2), receive).await,
                        Ok(Ok(()))
                    ) {
                        continue;
                    }
                    if let Ok(message) = serde_json::from_slice::<Message>(&bytes)
                        && message.nonce == self.nonce
                        && message.url.starts_with("pixiv://")
                        && let Ok(code) = parse_code(&message.url)
                    {
                        return Ok(code);
                    }
                }
            })
            .await
            .context("等待登录回调超时，请使用 --no-protocol 手动登录")?
        })
        .await
    }
}
pub async fn send(port: u16, nonce: &str, url: &str) -> Result<()> {
    if !url.starts_with("pixiv://") {
        bail!("无效的 Pixiv 回调");
    }
    parse_code(url)?;
    let mut payload = serde_json::to_vec(&Message {
        nonce: nonce.to_owned(),
        url: url.to_owned(),
    })?;
    if payload.len() > 8191 {
        bail!("回调过长");
    }
    payload.push(b'\n');
    tokio::time::timeout(Duration::from_secs(5), async {
        let mut socket = TcpStream::connect((std::net::Ipv4Addr::LOCALHOST, port)).await?;
        socket.write_all(&payload).await?;
        socket.shutdown().await?;
        Ok::<_, anyhow::Error>(())
    })
    .await
    .context("回调接收器不可用")?
}

#[cfg(windows)]
mod windows {
    use super::*;
    use fs2::FileExt;
    use winreg::{
        RegKey, RegValue,
        enums::{HKEY_CURRENT_USER, KEY_ALL_ACCESS},
    };
    const ROOT: &str = "Software\\Classes\\pixiv";
    const COMMAND: &str = "Software\\Classes\\pixiv\\shell\\open\\command";
    pub struct Registration {
        root: RegKey,
        existed: bool,
        before: Vec<(&'static str, &'static str, Option<RegValue>)>,
        _lock: std::fs::File,
    }
    impl Registration {
        pub fn new(port: u16, nonce: &str) -> Result<Self> {
            let dirs = directories::BaseDirs::new().context("用户目录不可用")?;
            let dir = dirs.cache_dir().join("pxder");
            std::fs::create_dir_all(&dir)?;
            let lock = std::fs::OpenOptions::new()
                .create(true)
                .truncate(false)
                .read(true)
                .write(true)
                .open(dir.join("oauth.lock"))?;
            lock.try_lock_exclusive()
                .context("已有 Pixiv OAuth 登录正在进行")?;
            let root = RegKey::predef(HKEY_CURRENT_USER);
            let existed = root.open_subkey(ROOT).is_ok();
            let mut before = Vec::new();
            for (path, name) in [(ROOT, ""), (ROOT, "URL Protocol"), (COMMAND, "")] {
                before.push((
                    path,
                    name,
                    root.open_subkey(path)
                        .ok()
                        .and_then(|key| key.get_raw_value(name).ok()),
                ));
            }
            let guard = Self {
                root,
                existed,
                before,
                _lock: lock,
            };
            let (key, _) = guard.root.create_subkey(ROOT)?;
            key.set_value("", &"URL:Pixiv Protocol")?;
            key.set_value("URL Protocol", &"")?;
            let (command, _) = guard.root.create_subkey(COMMAND)?;
            let exe = std::env::current_exe()?;
            command.set_value("", &format!("\"{}\" --protocol-callback \"%1\" --callback-port {port} --callback-nonce {nonce}", exe.display()))?;
            Ok(guard)
        }
    }
    impl Drop for Registration {
        fn drop(&mut self) {
            if !self.existed {
                let _ = self.root.delete_subkey_all(ROOT);
                return;
            }
            for (path, name, value) in &self.before {
                if let Ok(key) = self.root.open_subkey_with_flags(path, KEY_ALL_ACCESS) {
                    if let Some(value) = value {
                        let _ = key.set_raw_value(name, value);
                    } else {
                        let _ = key.delete_value(name);
                    }
                }
            }
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    #[tokio::test]
    async fn rejects_wrong_nonce_and_accepts_active_callback() -> Result<()> {
        let receiver = Receiver::bind().await?;
        send(
            receiver.port()?,
            "wrong",
            "pixiv://account/login?code=wrong",
        )
        .await?;
        send(
            receiver.port()?,
            receiver.nonce(),
            "pixiv://account/login?code=correct",
        )
        .await?;
        assert_eq!(receiver.wait(&CancellationToken::new()).await?, "correct");
        Ok(())
    }
    #[tokio::test]
    async fn callback_wait_is_cancellable() -> Result<()> {
        let receiver = Receiver::bind().await?;
        let cancel = CancellationToken::new();
        cancel.cancel();
        assert!(receiver.wait(&cancel).await.is_err());
        Ok(())
    }
}
