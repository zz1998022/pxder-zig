use anyhow::{Result, bail};
use base64::{Engine, engine::general_purpose::URL_SAFE_NO_PAD};
use sha2::{Digest, Sha256};

pub struct Pkce {
    pub verifier: String,
    pub login_url: String,
}
impl Pkce {
    pub fn new() -> Self {
        let bytes: [u8; 32] = rand::random();
        Self::from_bytes(bytes)
    }
    fn from_bytes(bytes: [u8; 32]) -> Self {
        let verifier = URL_SAFE_NO_PAD.encode(bytes);
        let challenge = URL_SAFE_NO_PAD.encode(Sha256::digest(verifier.as_bytes()));
        Self {
            verifier,
            login_url: format!(
                "https://app-api.pixiv.net/web/v1/login?code_challenge={challenge}&code_challenge_method=S256&client=pixiv-android"
            ),
        }
    }
}
impl Default for Pkce {
    fn default() -> Self {
        Self::new()
    }
}
pub fn parse_code(input: &str) -> Result<String> {
    let trimmed = input.trim();
    if trimmed.contains("://") {
        let url = url::Url::parse(trimmed)?;
        return url
            .query_pairs()
            .find(|(k, _)| k == "code")
            .map(|(_, v)| v.into_owned())
            .filter(|v| !v.is_empty())
            .ok_or_else(|| anyhow::anyhow!("回调 URL 缺少 code"));
    }
    if trimmed.is_empty() || trimmed.chars().any(char::is_whitespace) {
        bail!("授权码不能为空或包含空白");
    }
    Ok(trimmed.to_owned())
}

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn pkce_and_callback() -> Result<()> {
        let pkce = Pkce::from_bytes([7; 32]);
        assert_eq!(pkce.verifier.len(), 43);
        let url = url::Url::parse(&pkce.login_url)?;
        let challenge = url
            .query_pairs()
            .find(|(k, _)| k == "code_challenge")
            .map(|(_, v)| v.into_owned());
        assert_eq!(
            challenge,
            Some(URL_SAFE_NO_PAD.encode(Sha256::digest(pkce.verifier.as_bytes())))
        );
        assert_eq!(
            parse_code("pixiv://account/login?code=abc%2Bdef")?,
            "abc+def"
        );
        assert!(parse_code("pixiv://account/login").is_err());
        assert!(parse_code(" ").is_err());
        Ok(())
    }
}
