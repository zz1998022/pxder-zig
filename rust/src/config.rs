use anyhow::{Context, Result, bail};
use directories::BaseDirs;
use serde::{Deserialize, Serialize};
use std::{
    fs,
    io::Write,
    path::{Path, PathBuf},
};

#[derive(Clone, Default, Serialize, Deserialize)]
#[serde(default)]
pub struct Config {
    pub refresh_token: Option<String>,
    pub download: DownloadConfig,
    pub proxy: Option<String>,
}

#[derive(Clone, Debug, Serialize, Deserialize)]
#[serde(default)]
pub struct DownloadConfig {
    pub path: Option<PathBuf>,
    pub thread: usize,
    pub timeout: u64,
    #[serde(rename = "autoRename", alias = "auto_rename")]
    pub auto_rename: bool,
}

impl Default for DownloadConfig {
    fn default() -> Self {
        Self {
            path: None,
            thread: 5,
            timeout: 30,
            auto_rename: false,
        }
    }
}

impl Config {
    pub fn validate(&self) -> Result<()> {
        if !(1..=32).contains(&self.download.thread) {
            bail!("下载并发数必须为 1–32");
        }
        if !(1..=86400).contains(&self.download.timeout) {
            bail!("超时必须为 1–86400 秒");
        }
        if let Some(proxy) = self
            .proxy
            .as_deref()
            .filter(|p| !p.is_empty() && *p != "disable")
        {
            let parsed = url::Url::parse(proxy).context("代理 URL 无效")?;
            if !matches!(parsed.scheme(), "http" | "https" | "socks5" | "socks5h")
                || parsed.host_str().is_none()
            {
                bail!("支持 http/https/socks5/socks5h 代理");
            }
        }
        if self
            .download
            .path
            .as_ref()
            .is_some_and(|p| p.as_os_str().is_empty())
        {
            bail!("下载目录不能为空");
        }
        Ok(())
    }
}

#[derive(Clone, Debug)]
pub struct ConfigStore {
    pub dir: PathBuf,
    legacy_dir: Option<PathBuf>,
}

impl ConfigStore {
    pub fn discover(override_dir: Option<PathBuf>) -> Result<Self> {
        if let Some(dir) = override_dir {
            return Ok(Self::at(dir));
        }
        let base = BaseDirs::new().context("无法定位用户配置目录")?;
        Ok(Self {
            dir: base.config_dir().join("pxder"),
            legacy_dir: Some(base.config_dir().join("pxder-zig")),
        })
    }
    pub fn at(dir: PathBuf) -> Self {
        Self {
            dir,
            legacy_dir: None,
        }
    }
    pub fn path(&self) -> PathBuf {
        self.dir.join("config.json")
    }
    pub fn load(&self) -> Result<Config> {
        let path = self.path();
        let source = if path.exists() {
            path
        } else if let Some(legacy) = &self.legacy_dir {
            legacy.join("config.json")
        } else {
            path
        };
        match fs::read(&source) {
            Ok(data) => {
                let config: Config =
                    serde_json::from_slice(&data).context("配置 JSON 无效，请检查 config.json")?;
                config.validate()?;
                Ok(config)
            }
            Err(e) if e.kind() == std::io::ErrorKind::NotFound => Ok(Config::default()),
            Err(e) => Err(e).context("读取配置失败"),
        }
    }
    pub fn save(&self, config: &Config) -> Result<()> {
        config.validate()?;
        atomic_write(&self.path(), &serde_json::to_vec_pretty(config)?)
    }
}

pub fn atomic_write(path: &Path, bytes: &[u8]) -> Result<()> {
    let parent = path.parent().context("文件路径缺少父目录")?;
    fs::create_dir_all(parent)?;
    let mut temp = tempfile::NamedTempFile::new_in(parent)?;
    // tempfile creates private files on Unix; persistence preserves permissions.
    temp.write_all(bytes)?;
    temp.as_file().sync_all()?;
    temp.persist(path)
        .map_err(|e| e.error)
        .context("原子保存失败")?;
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn legacy_config_is_read_without_rewriting_it() -> Result<()> {
        let root = tempfile::tempdir()?;
        let legacy = root.path().join("legacy");
        fs::create_dir(&legacy)?;
        let original = br#"{"refresh_token":"test","download":{"path":"images","thread":8,"timeout":20,"autoRename":true}}"#;
        fs::write(legacy.join("config.json"), original)?;
        let store = ConfigStore {
            dir: root.path().join("new"),
            legacy_dir: Some(legacy.clone()),
        };
        let mut cfg = store.load()?;
        assert_eq!(cfg.download.thread, 8);
        assert!(cfg.download.auto_rename);
        cfg.refresh_token = None;
        store.save(&cfg)?;
        assert!(store.load()?.refresh_token.is_none());
        assert_eq!(fs::read(legacy.join("config.json"))?, original);
        Ok(())
    }
    #[test]
    fn corrupted_or_invalid_settings_are_not_silently_reset() -> Result<()> {
        let root = tempfile::tempdir()?;
        let store = ConfigStore::at(root.path().to_owned());
        fs::write(store.path(), b"invalid")?;
        assert!(store.load().is_err());
        fs::write(store.path(), br#"{"download":{"thread":-1}}"#)?;
        assert!(store.load().is_err());
        let mut cfg = Config::default();
        cfg.download.timeout = 0;
        assert!(store.save(&cfg).is_err());
        Ok(())
    }
}
