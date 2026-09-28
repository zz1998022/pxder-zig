use anyhow::Result;
use std::process::Command;

fn cli(dir: &std::path::Path) -> Command {
    let mut command = Command::new(env!("CARGO_BIN_EXE_pxder"));
    command.arg("--config-dir").arg(dir);
    command
}

#[test]
fn help_version_and_errors_have_correct_exit_codes_without_configuration_writes() -> Result<()> {
    let root = tempfile::tempdir()?;
    let config = root.path().join("config");
    for arg in ["--help", "--version", "-v"] {
        let output = cli(&config).arg(arg).output()?;
        assert!(output.status.success());
        assert!(!output.stdout.is_empty());
    }
    let invalid = cli(&config).args(["-u", "1", "-p", "2"]).output()?;
    assert_eq!(invalid.status.code(), Some(2));
    assert!(!config.exists());
    let no_terminal = cli(&config).output()?;
    assert_eq!(no_terminal.status.code(), Some(1));
    assert!(String::from_utf8_lossy(&no_terminal.stderr).contains("TUI 需要交互终端"));
    Ok(())
}

#[test]
fn settings_validate_before_save_and_logout_persists() -> Result<()> {
    let root = tempfile::tempdir()?;
    let invalid = cli(root.path())
        .args(["--setting", "--threads", "0"])
        .output()?;
    assert_eq!(invalid.status.code(), Some(1));
    assert!(!root.path().join("config.json").exists());
    let valid = cli(root.path())
        .args([
            "--setting",
            "--threads",
            "8",
            "--proxy",
            "disable",
            "-O",
            "images",
        ])
        .output()?;
    assert!(valid.status.success());
    let mut config: serde_json::Value =
        serde_json::from_slice(&std::fs::read(root.path().join("config.json"))?)?;
    assert_eq!(config["download"]["thread"], 8);
    config["refresh_token"] = serde_json::json!("fixture-token");
    std::fs::write(
        root.path().join("config.json"),
        serde_json::to_vec(&config)?,
    )?;
    let exported = cli(root.path()).arg("--export-token").output()?;
    assert_eq!(exported.stdout, b"fixture-token\n");
    assert!(cli(root.path()).arg("--logout").output()?.status.success());
    assert!(
        !cli(root.path())
            .arg("--export-token")
            .output()?
            .status
            .success()
    );
    Ok(())
}
