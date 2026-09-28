use super::{Confirmation, SOURCES, Screen, State};
use ratatui::{
    Frame,
    layout::{Alignment, Constraint, Layout, Rect},
    style::{Color, Modifier, Style},
    text::{Line, Span},
    widgets::{Block, BorderType, Borders, Clear, Gauge, Paragraph, Wrap},
};

const BG: Color = Color::Rgb(15, 19, 29);
const SURFACE: Color = Color::Rgb(23, 29, 42);
const BORDER: Color = Color::Rgb(53, 64, 84);
const TEXT: Color = Color::Rgb(225, 232, 244);
const MUTED: Color = Color::Rgb(145, 160, 183);
const ACCENT: Color = Color::Rgb(100, 218, 202);
const GREEN: Color = Color::Rgb(144, 213, 157);
const AMBER: Color = Color::Rgb(235, 194, 121);
const RED: Color = Color::Rgb(242, 139, 151);

fn panel(title: impl Into<Line<'static>>) -> Block<'static> {
    Block::default()
        .borders(Borders::ALL)
        .border_type(BorderType::Rounded)
        .title(title)
        .border_style(Style::default().fg(BORDER))
        .style(Style::default().bg(SURFACE).fg(TEXT))
}
fn text(value: impl Into<String>, color: Color) -> Line<'static> {
    Line::styled(value.into(), Style::default().fg(color))
}
fn key(value: &str, label: &str) -> Vec<Span<'static>> {
    vec![
        Span::styled(
            format!(" {value} "),
            Style::default().fg(ACCENT).bg(SURFACE).bold(),
        ),
        Span::styled(format!(" {label}  "), Style::default().fg(MUTED)),
    ]
}
fn centered(area: Rect, width: u16, height: u16) -> Rect {
    let width = width.min(area.width.saturating_sub(4));
    let height = height.min(area.height.saturating_sub(2));
    Rect::new(
        area.x + (area.width - width) / 2,
        area.y + (area.height - height) / 2,
        width,
        height,
    )
}
fn status(state: &State) -> (&str, Color) {
    if state.busy {
        (
            if state.snapshot.scanning {
                "正在获取 / 下载"
            } else {
                "下载进行中"
            },
            ACCENT,
        )
    } else if state.snapshot.cancelled {
        ("已取消", AMBER)
    } else if state.snapshot.has_errors() {
        ("部分失败", RED)
    } else if state.snapshot.done {
        ("任务已完成", GREEN)
    } else {
        ("准备就绪", MUTED)
    }
}
fn human_bytes(bytes: u64) -> String {
    if bytes >= 1_073_741_824 {
        format!("{:.1} GiB", bytes as f64 / 1_073_741_824.0)
    } else {
        format!("{:.1} MiB", bytes as f64 / 1_048_576.0)
    }
}

pub(super) fn draw(frame: &mut Frame, state: &State) {
    let area = frame.area();
    frame.render_widget(
        Block::default().style(Style::default().bg(BG).fg(TEXT)),
        area,
    );
    if area.width < 60 || area.height < 20 {
        let message = if state.confirm.is_some() {
            "确认当前操作？\nEnter 确认 · Esc 返回\n已完成的下载会保留"
        } else {
            "请将终端调整至至少 60 × 20\n推荐 120 × 36 · Ctrl+C 退出"
        };
        frame.render_widget(
            Paragraph::new(message)
                .style(Style::default().fg(MUTED))
                .block(panel(" PXDER ")),
            area,
        );
        return;
    }
    let rows = Layout::vertical([
        Constraint::Length(3),
        Constraint::Min(1),
        Constraint::Length(3),
    ])
    .margin(1)
    .split(area);
    let (status, color) = status(state);
    let header = Layout::horizontal([Constraint::Min(20), Constraint::Length(28)]).split(rows[0]);
    frame.render_widget(
        Paragraph::new(vec![
            Line::from(vec![
                Span::styled(" PXDER ", Style::default().bg(ACCENT).fg(BG).bold()),
                Span::styled("  插画收藏工作台", Style::default().fg(TEXT).bold()),
            ]),
            text(
                format!(
                    " v{} · Pixiv illustration downloader",
                    env!("CARGO_PKG_VERSION")
                ),
                MUTED,
            ),
        ]),
        header[0],
    );
    frame.render_widget(
        Paragraph::new(vec![
            text(format!("● {status}"), color),
            text(
                if state.config.refresh_token.is_some() {
                    "账户已连接"
                } else {
                    "账户未连接 · 按 l 登录"
                },
                MUTED,
            ),
        ])
        .alignment(Alignment::Right),
        header[1],
    );
    let content = if area.width >= 110 {
        let columns = Layout::horizontal([Constraint::Length(23), Constraint::Min(1)])
            .spacing(2)
            .split(rows[1]);
        sidebar(frame, state, columns[0]);
        columns[1]
    } else {
        rows[1]
    };
    dashboard(frame, state, content);
    let hint = if state.busy {
        "下载进行中 · c 取消任务，g 查看日志"
    } else if state.config.refresh_token.is_none() {
        "欢迎使用 · 按 l 连接 Pixiv 账户"
    } else if state.config.download.path.is_none() {
        "账户已就绪 · 按 s 选择下载目录"
    } else {
        "按 n 开始收藏你喜欢的作品"
    };
    let feedback = if state.message.is_empty() {
        hint
    } else {
        &state.message
    };
    frame.render_widget(
        Paragraph::new(vec![
            text(feedback, if state.message_error { RED } else { MUTED }),
            Line::from(
                [
                    key("n", "新任务"),
                    key("s", "设置"),
                    key("l", "账户"),
                    key("g", "日志"),
                    key("?", "帮助"),
                    key("q", "退出"),
                ]
                .concat(),
            ),
        ]),
        rows[2],
    );
    if state.screen != Screen::Dashboard || state.confirm.is_some() {
        // A clean backdrop avoids clipped table borders and half-width glyphs
        // peeking around focused forms on compact terminals.
        frame.render_widget(
            Block::default().style(Style::default().bg(BG).fg(TEXT)),
            area,
        );
    }
    if state.screen != Screen::Dashboard && state.confirm.is_none() {
        modal(frame, state, area);
    }
    if let Some(confirm) = state.confirm {
        confirmation(frame, confirm, area);
    }
}

fn sidebar(frame: &mut Frame, state: &State, area: Rect) {
    let account = if state.config.refresh_token.is_some() {
        "● 已连接"
    } else {
        "○ 未连接"
    };
    let dir = state
        .config
        .download
        .path
        .as_ref()
        .map(|p| p.to_string_lossy().into_owned())
        .unwrap_or_else(|| "尚未设置".into());
    let lines = vec![
        text("  工作空间", MUTED),
        Line::from(""),
        text("  ▸ 下载总览", ACCENT),
        text("  n  新建任务", TEXT),
        text("  g  任务日志", TEXT),
        Line::from(""),
        text("  偏好设置", MUTED),
        text("  s  下载设置", TEXT),
        text("  l  账户管理", TEXT),
        Line::from(""),
        text(
            format!("  {account}"),
            if state.config.refresh_token.is_some() {
                GREEN
            } else {
                AMBER
            },
        ),
        text(
            format!(
                "  {} 个并发 · {}s 超时",
                state.config.download.thread, state.config.download.timeout
            ),
            MUTED,
        ),
        Line::from(""),
        text("  下载位置", MUTED),
        text(format!("  {dir}"), TEXT),
    ];
    frame.render_widget(
        Paragraph::new(lines)
            .wrap(Wrap { trim: false })
            .block(panel(" LIBRARY ")),
        area,
    );
}

fn dashboard(frame: &mut Frame, state: &State, area: Rect) {
    let rows = Layout::vertical([
        Constraint::Length(4),
        Constraint::Length(3),
        Constraint::Min(3),
    ])
    .spacing(1)
    .split(area);
    let cards = Layout::horizontal([Constraint::Ratio(1, 4); 4])
        .spacing(1)
        .split(rows[0]);
    let s = &state.snapshot;
    for (i, (label, value, color)) in [
        ("已保存", s.succeeded.to_string(), GREEN),
        ("已跳过", s.skipped.to_string(), MUTED),
        (
            "失败 / 来源",
            format!("{} / {}", s.failed, s.source_errors),
            if s.has_errors() { RED } else { MUTED },
        ),
        ("传输量", human_bytes(s.bytes), ACCENT),
    ]
    .into_iter()
    .enumerate()
    {
        frame.render_widget(
            Paragraph::new(vec![
                text(value, color).style(Style::default().fg(color).bold()),
            ])
            .alignment(Alignment::Center)
            .block(panel(format!(" {label} "))),
            cards[i],
        );
    }
    let total = if state.busy && s.scanning {
        format!("{}+", s.queued)
    } else {
        s.queued.to_string()
    };
    let elapsed = state.started.elapsed().as_secs_f64().max(1.0);
    let label = if !state.busy && s.queued == 0 {
        "等待新任务".to_owned()
    } else {
        format!(
            "{} / {} 文件{}",
            s.completed(),
            total,
            if state.busy {
                format!(
                    "  ·  {:.1} MiB/s 均速",
                    s.bytes as f64 / elapsed / 1048576.0
                )
            } else {
                String::new()
            }
        )
    };
    let ratio = if s.queued == 0 {
        0.0
    } else {
        (s.completed() as f64 / s.queued as f64).min(1.0)
    };
    frame.render_widget(
        Gauge::default()
            .block(panel(" 批次进度 "))
            .gauge_style(Style::default().fg(ACCENT).bg(SURFACE))
            .ratio(ratio)
            .label(label),
        rows[1],
    );
    let body = if rows[2].height >= 12 {
        let split = Layout::vertical([Constraint::Min(5), Constraint::Length(6)])
            .spacing(1)
            .split(rows[2]);
        recent_logs(frame, state, split[1]);
        split[0]
    } else {
        rows[2]
    };
    if !state.busy && s.queued == 0 && !s.has_errors() {
        let block = panel(" 开始收藏 ");
        let inner = block.inner(body);
        frame.render_widget(block, body);
        let text_rows = vec![
            text("让喜欢的作品，留在本地。", TEXT).style(Style::default().fg(TEXT).bold()),
            text("", MUTED),
            text("[l] 连接账户   →   [s] 设置目录   →   [n] 新建下载", ACCENT),
            text("画师 · 作品 · 关注 · 收藏 · 增量更新", MUTED),
        ];
        frame.render_widget(
            Paragraph::new(text_rows).alignment(Alignment::Center),
            Rect::new(
                inner.x,
                inner.y + inner.height.saturating_sub(4) / 2,
                inner.width,
                inner.height.min(4),
            ),
        );
    } else {
        let visible = body.height.saturating_sub(2) as usize;
        let offset = state
            .file_offset
            .min(s.active.len().saturating_sub(visible.max(1)));
        let mut lines = vec![];
        for (path, bytes) in s.active.iter().skip(offset).take(visible) {
            let name = std::path::Path::new(path)
                .file_name()
                .unwrap_or_default()
                .to_string_lossy();
            lines.push(Line::from(vec![
                Span::styled(" ↓ ", Style::default().fg(ACCENT)),
                Span::styled(
                    format!("{:>10}  ", human_bytes(*bytes)),
                    Style::default().fg(MUTED),
                ),
                Span::raw(name.into_owned()),
            ]));
        }
        if lines.is_empty() {
            lines.push(text(
                if state.busy {
                    "  正在准备下一批文件…"
                } else {
                    "  没有活动传输 · n 新建任务，g 查看完整日志"
                },
                MUTED,
            ));
        }
        frame.render_widget(
            Paragraph::new(lines).block(panel(format!(" 活动文件 · {}  ↑↓ 滚动 ", s.active.len()))),
            body,
        );
    }
}
fn recent_logs(frame: &mut Frame, state: &State, area: Rect) {
    let logs: Vec<_> = state
        .snapshot
        .logs
        .iter()
        .rev()
        .take(area.height.saturating_sub(2) as usize)
        .rev()
        .map(|l| log_line(l))
        .collect();
    let logs = if logs.is_empty() {
        vec![text("  任务事件将在这里显示", MUTED)]
    } else {
        logs
    };
    frame.render_widget(
        Paragraph::new(logs).block(panel(" 最近动态 · g 展开 ")),
        area,
    );
}
fn log_line(value: &str) -> Line<'static> {
    text(
        format!("  {value}"),
        if value.contains("失败") {
            RED
        } else if value.contains("重试") {
            AMBER
        } else {
            MUTED
        },
    )
}

fn modal(frame: &mut Frame, state: &State, area: Rect) {
    let (title, subtitle, height) = match state.screen {
        Screen::NewJob => ("新建下载", "选择来源，再添加需要下载的内容", 22),
        Screen::Settings => ("下载设置", "让每次下载按你的习惯运行", 24),
        Screen::Login => ("账户管理", "连接 Pixiv，访问你的关注与收藏", 17),
        Screen::Token => (
            "使用 Token 登录",
            "粘贴已有的 refresh token，输入始终隐藏",
            13,
        ),
        Screen::Code => ("浏览器授权", "完成浏览器登录后，粘贴授权码或回调 URL", 20),
        Screen::Logs => (
            "任务日志",
            "↑ 查看较早记录 · ↓ 查看较新记录 · End 跟随最新",
            area.height.saturating_sub(2),
        ),
        _ => ("快捷键", "键盘操作，无需离开终端", 21),
    };
    let popup = centered(
        area,
        if state.screen == Screen::Logs {
            100
        } else {
            80
        },
        height,
    );
    frame.render_widget(Clear, popup);
    let block = panel(format!(" {title} ")).border_style(Style::default().fg(ACCENT));
    let inner = block.inner(popup);
    frame.render_widget(block, popup);
    let parts = Layout::vertical([
        Constraint::Length(2),
        Constraint::Min(1),
        Constraint::Length(3),
    ])
    .horizontal_margin(2)
    .split(inner);
    frame.render_widget(
        Paragraph::new(subtitle).style(Style::default().fg(MUTED)),
        parts[0],
    );
    match state.screen {
        Screen::NewJob => job_form(frame, state, parts[1]),
        Screen::Settings => settings_form(frame, state, parts[1]),
        Screen::Token => input(
            frame,
            state,
            parts[1],
            "Refresh token",
            0,
            0,
            "粘贴 refresh token",
            true,
        ),
        Screen::Code => {
            let rows =
                Layout::vertical([Constraint::Min(4), Constraint::Length(3)]).split(parts[1]);
            let url = state
                .pkce
                .as_ref()
                .map(|p| p.login_url.as_str())
                .unwrap_or("");
            frame.render_widget(
                Paragraph::new(vec![
                    text("浏览器未打开时，可复制以下地址：", MUTED),
                    text(url, ACCENT),
                ])
                .wrap(Wrap { trim: false }),
                rows[0],
            );
            input(
                frame,
                state,
                rows[1],
                "授权码 / 回调 URL",
                0,
                0,
                "粘贴 code 或 pixiv://…",
                true,
            );
        }
        Screen::Login => {
            let connected = state.config.refresh_token.is_some();
            frame.render_widget(
                Paragraph::new(vec![
                    text(
                        if connected {
                            "● 账户已连接"
                        } else {
                            "○ 尚未登录"
                        },
                        if connected { GREEN } else { AMBER },
                    ),
                    Line::from(""),
                    Line::from(key("o / Enter", "浏览器登录 · 推荐")),
                    text("   使用 Pixiv 官方登录页完成授权", MUTED),
                    Line::from(""),
                    Line::from(key("t", "使用已有 Token")),
                    text("   适合已有 refresh token 的设备迁移", MUTED),
                    Line::from(""),
                    Line::from(key(
                        "x",
                        if connected {
                            "登出当前账户"
                        } else {
                            "登录后可管理账户"
                        },
                    )),
                ]),
                parts[1],
            );
        }
        Screen::Logs => {
            let count = parts[1].height as usize;
            let end = state.snapshot.logs.len().saturating_sub(state.log_offset);
            let start = end.saturating_sub(count);
            let lines: Vec<_> = state
                .snapshot
                .logs
                .iter()
                .skip(start)
                .take(end - start)
                .map(|s| log_line(s))
                .collect();
            frame.render_widget(
                Paragraph::new(if lines.is_empty() {
                    vec![text(
                        "暂无记录。开始一个任务后，这里会显示执行情况。",
                        MUTED,
                    )]
                } else {
                    lines
                }),
                parts[1],
            );
        }
        _ => {
            frame.render_widget(
                Paragraph::new(vec![
                    text("工作台", ACCENT),
                    text("n 新任务   s 设置   l 账户   g 日志", TEXT),
                    text("c 取消当前任务   q / Ctrl+C 退出", TEXT),
                    Line::from(""),
                    text("表单操作", ACCENT),
                    text("Tab / Shift+Tab 切换焦点，Enter 提交", TEXT),
                    text("来源栏 ← → 切换；开关用 Space / ← →", TEXT),
                    text("输入框 ← → 移动，Home / End，Ctrl+U 清空", TEXT),
                    text("支持粘贴、中文编辑、Backspace / Delete", TEXT),
                    Line::from(""),
                    text("查看进度", ACCENT),
                    text("总览 ↑↓ 滚动文件；日志 ↑↓ 翻阅，End 回到最新", TEXT),
                    text("Esc 返回；取消与退出均保留已完成文件", MUTED),
                ]),
                parts[1],
            );
        }
    }
    let submit = match state.screen {
        Screen::Settings => "保存设置",
        Screen::NewJob => "开始下载",
        Screen::Token | Screen::Code => "登录",
        _ => "",
    };
    let mut footer = vec![text(
        &state.message,
        if state.message_error { RED } else { GREEN },
    )];
    footer.push(Line::from(if submit.is_empty() {
        key("Esc", "返回")
    } else {
        [
            key("Enter", submit),
            key("Tab", "下一项"),
            key("Esc", "返回"),
        ]
        .concat()
    }));
    frame.render_widget(Paragraph::new(footer), parts[2]);
}

fn job_form(frame: &mut Frame, state: &State, area: Rect) {
    let rows = Layout::vertical([
        Constraint::Length(3),
        Constraint::Length(2),
        Constraint::Length(3),
        Constraint::Length(3),
        Constraint::Min(0),
    ])
    .split(area);
    let focused = state.selected == 0;
    frame.render_widget(
        Paragraph::new(format!(
            " ←  {}  →   ({}/7)",
            SOURCES[state.source],
            state.source + 1
        ))
        .style(Style::default().fg(if focused { ACCENT } else { TEXT }))
        .block(
            panel(" 下载来源 ").border_style(Style::default().fg(if focused {
                ACCENT
            } else {
                BORDER
            })),
        ),
        rows[0],
    );
    let description = match state.source {
        0 => "下载所选画师的全部作品，可填写多个 UID。",
        1 => "只下载指定作品，可填写多个 PID。",
        2 | 3 => "下载当前账户关注画师的作品，无需填写 ID。",
        4 | 5 => "下载当前账户收藏的作品，无需填写 ID。",
        _ => "扫描下载目录中的画师文件夹，补充尚未下载的作品。",
    };
    frame.render_widget(
        Paragraph::new(description)
            .style(Style::default().fg(MUTED))
            .wrap(Wrap { trim: false }),
        rows[1],
    );
    if state.source < 2 {
        input(
            frame,
            state,
            rows[2],
            if state.source == 0 {
                "画师 UID"
            } else {
                "作品 PID"
            },
            0,
            1,
            "例如 12345, 67890 · 逗号分隔",
            false,
        );
    } else {
        frame.render_widget(
            Paragraph::new("当前账户的内容 · 已自动选择数据范围")
                .style(Style::default().fg(ACCENT))
                .block(panel(" 无需输入 ID ")),
            rows[2],
        );
    }
    toggle(
        frame,
        rows[3],
        "跳过动图元数据",
        state.fields[1] == "true",
        state.selected == 2,
    );
    frame.render_widget(
        Paragraph::new("已存在的文件会自动跳过。关闭上方开关可保留动图帧延迟。")
            .style(Style::default().fg(MUTED))
            .wrap(Wrap { trim: false }),
        rows[4],
    );
}
fn settings_form(frame: &mut Frame, state: &State, area: Rect) {
    // Compact enough for 60×20; each control keeps its label and value visible.
    let rows = Layout::vertical([
        Constraint::Length(3),
        Constraint::Length(3),
        Constraint::Length(3),
        Constraint::Length(2),
    ])
    .split(area);
    input(
        frame,
        state,
        rows[0],
        "下载目录",
        0,
        0,
        "输入保存作品的目录",
        false,
    );
    let pair = Layout::horizontal([Constraint::Percentage(50), Constraint::Percentage(50)])
        .spacing(1)
        .split(rows[1]);
    input(frame, state, pair[0], "并发数 · 1–32", 1, 1, "5", false);
    input(frame, state, pair[1], "超时 · 秒", 2, 2, "30", false);
    input(
        frame,
        state,
        rows[2],
        "代理 · 隐藏输入",
        3,
        3,
        "留空使用系统；disable 禁用代理",
        true,
    );
    toggle(
        frame,
        rows[3],
        "跟随画师名称自动改名",
        state.fields[4] == "true",
        state.selected == 4,
    );
}
fn toggle(frame: &mut Frame, area: Rect, label: &str, enabled: bool, focused: bool) {
    let line = Line::from(vec![
        Span::styled(
            if enabled {
                " [● 开] "
            } else {
                " [○ 关] "
            },
            Style::default()
                .fg(if enabled { ACCENT } else { MUTED })
                .bold(),
        ),
        Span::raw(label.to_owned()),
        Span::styled(
            if focused { "  Space 切换" } else { "" },
            Style::default().fg(MUTED),
        ),
    ]);
    frame.render_widget(
        Paragraph::new(line).style(
            Style::default()
                .bg(if focused { BORDER } else { SURFACE })
                .fg(TEXT),
        ),
        area,
    );
}

// Keep the insertion point visible without slicing through UTF-8 or counting
// wide characters as a single terminal column. Secrets never enter the buffer.
fn input_window(value: &str, cursor: usize, width: usize, secret: bool) -> (String, u16) {
    let chars: Vec<char> = if secret {
        vec!['•'; value.chars().count()]
    } else {
        value.chars().collect()
    };
    let cursor = cursor.min(chars.len());
    let mut start = cursor;
    let mut before = 0;
    while start > 0 {
        let w = Line::from(chars[start - 1].to_string()).width();
        if before + w >= width {
            break;
        }
        start -= 1;
        before += w;
    }
    let mut shown = String::new();
    let mut used = 0;
    for c in chars.iter().skip(start) {
        let w = Line::from(c.to_string()).width();
        if used + w > width {
            break;
        }
        shown.push(*c);
        used += w;
    }
    (shown, before as u16)
}
#[allow(clippy::too_many_arguments)]
fn input(
    frame: &mut Frame,
    state: &State,
    area: Rect,
    label: &str,
    index: usize,
    focus: usize,
    placeholder: &str,
    secret: bool,
) {
    if area.height < 3 || area.width < 3 {
        return;
    }
    let focused = state.selected == focus;
    let block = panel(format!(" {label} ")).border_style(Style::default().fg(if focused {
        ACCENT
    } else {
        BORDER
    }));
    let inner = block.inner(area);
    frame.render_widget(block, area);
    let cursor = if focused { state.cursor } else { 0 };
    let (value, offset) = input_window(
        &state.fields[index],
        cursor,
        inner.width.saturating_sub(1) as usize,
        secret,
    );
    let empty = state.fields[index].is_empty();
    frame.render_widget(
        Paragraph::new(if empty { placeholder } else { &value })
            .style(Style::default().fg(if empty { MUTED } else { TEXT })),
        inner,
    );
    if focused && state.confirm.is_none() {
        frame.set_cursor_position((inner.x + offset.min(inner.width.saturating_sub(1)), inner.y));
    }
}
fn confirmation(frame: &mut Frame, confirm: Confirmation, area: Rect) {
    let popup = centered(area, 60, 10);
    frame.render_widget(Clear, popup);
    let (title, detail) = match confirm {
        Confirmation::Quit => ("退出工作台？", "当前任务将取消，已经下载的文件会保留。"),
        Confirmation::Cancel => ("取消当前任务？", "已完成文件会保留，正在传输的文件会停止。"),
        Confirmation::Logout => ("登出当前账户？", "清除本机 Rust 版本保存的登录信息。"),
    };
    frame.render_widget(
        Paragraph::new(vec![
            text("", MUTED),
            text(title, AMBER).style(Style::default().fg(AMBER).add_modifier(Modifier::BOLD)),
            text("", MUTED),
            text(detail, TEXT),
            text("", MUTED),
            Line::from([key("Enter", "确认"), key("Esc", "返回")].concat()),
        ])
        .alignment(Alignment::Center)
        .block(panel(" 请确认 ").border_style(Style::default().fg(AMBER))),
        popup,
    );
}
