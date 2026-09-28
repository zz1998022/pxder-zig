use anyhow::{Context, Result, bail};
use serde::{Deserialize, Serialize};
use std::path::PathBuf;

#[derive(Clone, Debug, Deserialize)]
pub struct User {
    pub id: u64,
    pub name: String,
}
#[derive(Clone, Debug, Default, Deserialize)]
pub struct SinglePage {
    pub original_image_url: Option<String>,
}
#[derive(Clone, Debug, Deserialize)]
pub struct ImageUrls {
    pub original: String,
}
#[derive(Clone, Debug, Deserialize)]
pub struct MetaPage {
    pub image_urls: ImageUrls,
}
#[derive(Clone, Debug, Deserialize)]
pub struct Illust {
    pub id: u64,
    #[serde(default)]
    pub title: String,
    #[serde(default, rename = "type")]
    pub kind: String,
    #[serde(default)]
    pub meta_single_page: SinglePage,
    #[serde(default)]
    pub meta_pages: Vec<MetaPage>,
}
#[derive(Clone, Debug, Serialize, Deserialize)]
pub struct Frame {
    pub file: String,
    pub delay: u32,
}
#[derive(Clone, Debug, Deserialize)]
pub struct ZipUrls {
    pub medium: String,
}
#[derive(Clone, Debug, Deserialize)]
pub struct UgoiraMetadata {
    pub zip_urls: ZipUrls,
    pub frames: Vec<Frame>,
}
#[derive(Clone, Debug)]
pub struct DownloadTask {
    pub pid: u64,
    pub url: String,
    pub path: PathBuf,
    pub frames: Option<Vec<Frame>>,
}

pub fn sanitize_title(title: &str) -> String {
    // Keep the Zig naming contract, while respecting filesystem component limits.
    let clean: String = title
        .chars()
        .filter(|c| !c.is_control() && !"/\\:*?\"<>|.&$".contains(*c))
        .collect();
    let mut end = clean.len().min(180);
    while !clean.is_char_boundary(end) {
        end -= 1;
    }
    clean[..end].trim_end_matches(' ').to_owned()
}
pub fn sanitize_artist(name: &str) -> String {
    let cut = name
        .char_indices()
        .find(|(i, c)| *i > 0 && *c == '@')
        .map(|(i, _)| i)
        .unwrap_or(name.len());
    sanitize_title(&name[..cut])
}
pub fn artist_uid(name: &str) -> Option<u64> {
    let end = name.find(')')?;
    name.strip_prefix('(')?[..end - 1]
        .parse()
        .ok()
        .filter(|v| *v > 0)
}
impl Illust {
    pub fn is_ugoira(&self) -> bool {
        self.kind == "ugoira"
            || self
                .meta_single_page
                .original_image_url
                .as_ref()
                .is_some_and(|u| u.contains("_ugoira"))
    }
    pub fn tasks(
        &self,
        dir: &std::path::Path,
        metadata: Option<UgoiraMetadata>,
    ) -> Result<Vec<DownloadTask>> {
        let title = sanitize_title(&self.title);
        if self.is_ugoira() {
            let (url, frames) = if let Some(meta) = metadata {
                (meta.zip_urls.medium, Some(meta.frames))
            } else {
                let original = self
                    .meta_single_page
                    .original_image_url
                    .as_ref()
                    .context("动图没有原图 URL")?;
                let replaced = original.replace("img-original", "img-zip-ugoira");
                let (base, _) = replaced.rsplit_once('_').context("无效的动图 URL")?;
                (format!("{base}_ugoira1920x1080.zip"), None)
            };
            let delay = frames
                .as_ref()
                .and_then(|f| f.first())
                .map(|f| format!("@{}ms", f.delay))
                .unwrap_or_default();
            return Ok(vec![DownloadTask {
                pid: self.id,
                url,
                path: dir.join(format!("({}){title}{delay}.zip", self.id)),
                frames,
            }]);
        }
        let urls: Vec<&str> = if !self.meta_pages.is_empty() {
            self.meta_pages
                .iter()
                .map(|p| p.image_urls.original.as_str())
                .collect()
        } else {
            vec![
                self.meta_single_page
                    .original_image_url
                    .as_deref()
                    .context("作品没有原图 URL")?,
            ]
        };
        if urls.iter().any(|u| u.is_empty()) {
            bail!("作品原图 URL 为空");
        }
        urls.iter()
            .enumerate()
            .map(|(i, url)| {
                let parsed = url::Url::parse(url)?;
                let ext = parsed
                    .path()
                    .rsplit_once('.')
                    .map(|(_, e)| e)
                    .filter(|e| {
                        matches!(*e, "jpg" | "jpeg" | "png" | "gif" | "webp" | "avif" | "zip")
                    })
                    .unwrap_or("jpg");
                let suffix = if urls.len() > 1 {
                    format!("_p{i}")
                } else {
                    String::new()
                };
                Ok(DownloadTask {
                    pid: self.id,
                    url: (*url).to_owned(),
                    path: dir.join(format!("({}){title}{suffix}.{ext}", self.id)),
                    frames: None,
                })
            })
            .collect()
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn names_match_legacy_and_cannot_escape_directory() {
        assert_eq!(sanitize_title("猫 /a.b&$?  "), "猫 ab");
        assert_eq!(sanitize_artist("画师@展位"), "画师");
        assert_eq!(artist_uid("(123)画师"), Some(123));
        assert_eq!(artist_uid("[bookmark] Public"), None);
        assert_eq!(artist_uid("()"), None);
        assert!(sanitize_title(&"猫".repeat(100)).len() <= 180);
    }
    #[test]
    fn single_multi_and_ugoira_files() -> Result<()> {
        let mut illust: Illust = serde_json::from_str(
            r#"{"id":42,"title":"猫","meta_single_page":{"original_image_url":"https://i.pximg.net/img-original/a/42_p0.png"}}"#,
        )?;
        let dir = std::path::Path::new("output");
        assert_eq!(illust.tasks(dir, None)?[0].path, dir.join("(42)猫.png"));
        illust.meta_pages = vec![
            MetaPage {
                image_urls: ImageUrls {
                    original: "https://i.pximg.net/a.jpg".into(),
                },
            },
            MetaPage {
                image_urls: ImageUrls {
                    original: "https://i.pximg.net/b.png".into(),
                },
            },
        ];
        assert_eq!(illust.tasks(dir, None)?[1].path, dir.join("(42)猫_p1.png"));
        illust.kind = "ugoira".into();
        let task = illust.tasks(
            dir,
            Some(UgoiraMetadata {
                zip_urls: ZipUrls {
                    medium: "https://i.pximg.net/a.zip".into(),
                },
                frames: vec![Frame {
                    file: "000000.jpg".into(),
                    delay: 50,
                }],
            }),
        )?;
        assert_eq!(task[0].path, dir.join("(42)猫@50ms.zip"));
        assert_eq!(task[0].frames.as_ref().map(Vec::len), Some(1));
        Ok(())
    }
}
