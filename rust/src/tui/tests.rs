use super::*;
use ratatui::{Terminal, backend::TestBackend, text::Line};

fn press(state: &mut State, code: KeyCode) -> Action {
    state.key(KeyEvent::new(code, KeyModifiers::NONE))
}
fn render(state: &State, width: u16, height: u16) -> Result<String> {
    let mut terminal = Terminal::new(TestBackend::new(width, height))?;
    terminal.draw(|f| draw(f, state))?;
    let buffer = terminal.backend().buffer();
    let mut result = String::new();
    for y in 0..height {
        let mut x = 0;
        while x < width {
            let symbol = buffer[(x, y)].symbol();
            result.push_str(symbol);
            x += Line::from(symbol).width().max(1) as u16;
        }
        result.push('\n');
    }
    Ok(result)
}
#[test]
fn source_focus_and_dynamic_id_fields() -> Result<()> {
    let mut s = State::new(Config::default());
    s.open(Screen::NewJob);
    press(&mut s, KeyCode::Right);
    assert_eq!(s.source, 1);
    assert!(render(&s, 80, 26)?.contains("作品 PID"));
    press(&mut s, KeyCode::Tab);
    s.insert("123,456");
    press(&mut s, KeyCode::Left);
    assert_eq!(s.source, 1, "editing must not change source");
    assert!(matches!(s.request()?.source, Source::Pids(ids) if ids == vec![123,456]));
    press(&mut s, KeyCode::Tab);
    press(&mut s, KeyCode::Char(' '));
    assert!(s.request()?.no_ugoira_meta);
    press(&mut s, KeyCode::Tab);
    for _ in 0..4 {
        press(&mut s, KeyCode::Right);
    }
    let text = render(&s, 60, 20)?;
    assert!(text.contains("私密收藏") && text.contains("无需输入 ID"));
    assert!(!text.contains("123,456"));
    press(&mut s, KeyCode::Tab);
    assert_eq!(s.selected, 2);
    s.insert("pasted text");
    assert_eq!(s.fields[1], "true");
    assert!(matches!(
        s.request()?.source,
        Source::Bookmarks { private: true }
    ));
    Ok(())
}
#[test]
fn unicode_editing_and_paste() {
    let mut s = State::new(Config::default());
    s.open(Screen::Settings);
    s.insert("猫ab");
    press(&mut s, KeyCode::Left);
    s.insert("画");
    assert_eq!(s.fields[0], "猫a画b");
    press(&mut s, KeyCode::Backspace);
    press(&mut s, KeyCode::Home);
    press(&mut s, KeyCode::Delete);
    s.insert("新\n\t路径");
    assert_eq!(s.fields[0], "新路径ab");
    press(&mut s, KeyCode::End);
    assert_eq!(s.cursor, 5);
}
#[test]
fn confirmation_requires_explicit_acceptance() {
    let mut s = State::new(Config::default());
    s.busy = true;
    assert!(matches!(press(&mut s, KeyCode::Char('q')), Action::None));
    assert!(s.confirm.is_some());
    press(&mut s, KeyCode::Esc);
    assert!(s.confirm.is_none());
    press(&mut s, KeyCode::Char('c'));
    assert!(matches!(press(&mut s, KeyCode::Enter), Action::Cancel));
    press(&mut s, KeyCode::Char('s'));
    assert!(s.screen == Screen::Dashboard && s.message.contains("运行"));
}
#[test]
fn logs_scroll_and_follow_latest() {
    let mut s = State::new(Config::default());
    s.snapshot.logs.extend((0..50).map(|i| format!("line {i}")));
    press(&mut s, KeyCode::Char('g'));
    for _ in 0..60 {
        press(&mut s, KeyCode::Up);
    }
    assert_eq!(s.log_offset, 49);
    press(&mut s, KeyCode::End);
    assert_eq!(s.log_offset, 0);
}
#[test]
fn responsive_controls_and_secret_masking() -> Result<()> {
    let mut s = State::new(Config::default());
    s.config.proxy = Some("http://SENSITIVE_PASSWORD@proxy:80".into());
    for (width, height) in [(120, 36), (80, 26), (60, 20)] {
        for screen in [
            Screen::Dashboard,
            Screen::NewJob,
            Screen::Settings,
            Screen::Login,
            Screen::Token,
            Screen::Code,
            Screen::Help,
            Screen::Logs,
        ] {
            s.open(screen);
            if matches!(screen, Screen::Token | Screen::Code) {
                s.insert("SENSITIVE_TOKEN");
            }
            let text = render(&s, width, height)?;
            assert!(!text.contains("SENSITIVE_TOKEN") && !text.contains("SENSITIVE_PASSWORD"));
            if screen == Screen::Settings {
                for label in ["下载目录", "并发数", "超时", "代理", "自动改名", "保存设置"]
                {
                    assert!(
                        text.contains(label),
                        "{width}x{height}: missing {label}\n{text}"
                    );
                }
            }
        }
    }
    assert!(render(&s, 35, 10)?.contains("60 × 20"));
    s.confirm = Some(Confirmation::Quit);
    assert!(render(&s, 35, 10)?.contains("Enter 确认"));
    Ok(())
}
#[test]
fn running_batch_displays_counts_files_and_forms() -> Result<()> {
    let dir = std::env::var("PXDER_UI_SNAPSHOT_DIR").ok();
    if let Some(dir) = &dir {
        std::fs::create_dir_all(dir)?;
    }
    let mut s = State::new(Config::default());
    s.config.refresh_token = Some("fixture".into());
    s.config.download.path = Some("~/Pictures/Pixiv".into());
    s.busy = true;
    s.snapshot.queued = 128;
    s.snapshot.succeeded = 76;
    s.snapshot.skipped = 12;
    s.snapshot.bytes = 480 * 1024 * 1024;
    s.snapshot
        .active
        .insert("(12345)雨后的城市_p0.png".into(), 3145728);
    s.snapshot
        .active
        .insert("(67890)夏日海岸.jpg".into(), 1572864);
    s.snapshot.logs.extend([
        "画师 12345 · illustration".into(),
        "开始获取作品列表".into(),
    ]);
    for (name, screen, w, h) in [
        ("dashboard", Screen::Dashboard, 120, 36),
        ("new-job", Screen::NewJob, 80, 26),
        ("settings-compact", Screen::Settings, 60, 20),
    ] {
        s.open(screen);
        let preview = render(&s, w, h)?;
        match screen {
            Screen::Dashboard => {
                assert!(preview.contains("88 / 128 文件"));
                assert!(preview.contains("3.0 MiB") && preview.contains("雨后的城市_p0.png"));
            }
            Screen::NewJob => assert!(preview.contains("画师 UID") && preview.contains("开始下载")),
            Screen::Settings => {
                assert!(preview.contains("~/Pictures/Pixiv") && preview.contains("保存设置"))
            }
            _ => {}
        }
        if let Some(dir) = &dir {
            std::fs::write(
                std::path::Path::new(dir).join(format!("{name}.txt")),
                preview,
            )?;
        }
    }
    Ok(())
}
