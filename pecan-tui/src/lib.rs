mod theme;

use ratatui::{
    backend::CrosstermBackend,
    layout::{Constraint, Direction, Layout},
    style::{Color, Modifier, Style},
    text::{Line, Span},
    widgets::{Block, Borders, List, ListItem, ListState, Paragraph, Clear},
    Terminal,
};
use ratatui::crossterm::{
    event::{self, DisableMouseCapture, EnableMouseCapture, Event, KeyCode, KeyEventKind},
    execute,
    terminal::{disable_raw_mode, enable_raw_mode, EnterAlternateScreen, LeaveAlternateScreen},
};
use std::io;
use pecan_core::{Agent, AgentStatus};
use pecan_providers::Role;
use theme::{DRACULA, NORD, DEFAULT};
use ratatui_textarea::TextArea;

fn wrap_text(text: &str, width: u16) -> Vec<String> {
    if width == 0 { return vec![text.to_string()]; }
    let mut result = Vec::new();
    let mut current_text = text;
    while !current_text.is_empty() {
        let mut char_count = 0;
        let mut split_idx = 0;
        for (idx, _) in current_text.char_indices() {
            if char_count >= width as usize {
                break;
            }
            char_count += 1;
            split_idx = idx + current_text[idx..].chars().next().unwrap().len_utf8();
        }
        if split_idx == 0 && !current_text.is_empty() {
             split_idx = current_text.len();
        }
        result.push(current_text[..split_idx].to_string());
        current_text = &current_text[split_idx..];
    }
    if result.is_empty() {
        result.push(String::new());
    }
    result
}

pub async fn run_tui(agent: Agent) -> anyhow::Result<()> {
    let is_iterm = std::env::var("TERM_PROGRAM").map(|v| v == "iTerm.app").unwrap_or(false);
    
    enable_raw_mode()?;
    let mut stdout = io::stdout();
    execute!(stdout, EnterAlternateScreen, EnableMouseCapture)?;
    
    let backend = CrosstermBackend::new(stdout);
    let mut terminal = Terminal::new(backend)?;

    let res = run_loop(&mut terminal, agent, is_iterm).await;

    disable_raw_mode()?;
    execute!(
        terminal.backend_mut(),
        LeaveAlternateScreen,
        DisableMouseCapture
    )?;
    terminal.show_cursor()?;

    res
}

async fn run_loop<B: ratatui::prelude::Backend>(
    terminal: &mut Terminal<B>,
    agent: Agent,
    is_iterm: bool,
) -> anyhow::Result<()> 
where
    <B as ratatui::prelude::Backend>::Error: std::error::Error + Send + Sync + 'static,
{
    let mut textarea = TextArea::default();
    textarea.set_cursor_line_style(Style::default().remove_modifier(Modifier::UNDERLINED));
    textarea.set_style(Style::default());
    
    let mut theme = DRACULA;
    let mut spinner_index = 0;
    let spinner = ["⠋", "⠙", "⠹", "⠸", "⠼", "⠴", "⠦", "⠧", "⠇", "⠏"];
    let mut list_state = ListState::default();

    let (sep_left, sep_right) = if is_iterm {
        ("\u{e0b0}", "\u{e0b2}") 
    } else {
        ("|", "|")
    };

    let clean_style = Style::default().remove_modifier(Modifier::all());

    loop {
        let history = agent.history.lock().await.clone();
        let status = agent.status.lock().await.clone();
        let current_model = {
            let config = agent.config.lock().await;
            config.default_model.clone()
        };

        terminal.draw(|f| {
            f.render_widget(Clear, f.area());

            let area_width = f.area().width.saturating_sub(2);
            let input_lines = textarea.lines().len() as u16;
            let input_height = input_lines.min(10).max(1);

            let chunks = Layout::default()
                .direction(Direction::Vertical)
                .constraints([
                    Constraint::Min(1),               
                    Constraint::Length(1),            
                    Constraint::Length(input_height), 
                    Constraint::Length(1),            
                    Constraint::Length(1),            
                ].as_ref())
                .split(f.area());

            let mut history_items: Vec<ListItem> = history
                .iter()
                .filter(|m| m.role != Role::System)
                .map(|m| {
                    if m.role == Role::User {
                        let style = clean_style.bg(theme.user_bg).fg(theme.user_fg);
                        let content = m.content.as_deref().unwrap_or("");
                        let mut lines: Vec<Line> = Vec::new();
                        for l in content.lines() {
                            let wrapped_lines = wrap_text(l, area_width);
                            for wl in wrapped_lines {
                                lines.push(Line::from(format!(" {}", wl)).style(style));
                            }
                        }
                        lines.push(Line::from("")); 
                        ListItem::new(lines)
                    } else if m.role == Role::Assistant {
                        let style = clean_style.fg(theme.agent_text);
                        let content = m.content.as_deref().unwrap_or("");
                        let mut lines: Vec<Line> = Vec::new();
                        
                        if !content.is_empty() {
                            for l in content.lines() {
                                let wrapped_lines = wrap_text(l, area_width);
                                for wl in wrapped_lines {
                                    lines.push(Line::from(format!(" {}", wl)).style(style));
                                }
                            }
                        }

                        if let Some(tool_calls) = &m.tool_calls {
                            for call in tool_calls {
                                let call_text = format!(" [Call: {}] ", call.function.name);
                                let wrapped_calls = wrap_text(&call_text, area_width);
                                for wc in wrapped_calls {
                                    lines.push(Line::from(vec![
                                        Span::styled(wc, clean_style.bg(theme.highlight).fg(Color::Black)),
                                    ]));
                                }
                            }
                        }

                        lines.push(Line::from("")); 
                        ListItem::new(lines)
                    } else {
                        let content = m.content.as_deref().unwrap_or("");
                        let mut lines = vec![Line::from(vec![Span::styled(" [Tool Result] ", clean_style.fg(Color::Gray))])];
                        for l in content.lines() {
                            let wrapped_lines = wrap_text(l, area_width);
                            for wl in wrapped_lines {
                                lines.push(Line::from(format!(" {}", wl)).style(clean_style.fg(Color::DarkGray)));
                            }
                        }
                        lines.push(Line::from(""));
                        ListItem::new(lines)
                    }
                })
                .collect();
            
            match &status {
                AgentStatus::Thinking => {
                    spinner_index = (spinner_index + 1) % spinner.len();
                    history_items.push(ListItem::new(Line::from(vec![
                        Span::styled(format!(" {} ", spinner[spinner_index]), clean_style.fg(theme.highlight)),
                        Span::styled("Agent is working...", clean_style.fg(Color::DarkGray)),
                    ])));
                }
                AgentStatus::WaitingForApproval(p) => {
                    let args_display = serde_json::to_string_pretty(&p.args).unwrap_or_else(|_| p.args.to_string());
                    let mut approval_lines = vec![
                        Line::from(vec![
                            Span::styled(" TOOL APPROVAL REQUIRED ", clean_style.bg(Color::Yellow).fg(Color::Black).add_modifier(Modifier::BOLD)),
                            Span::styled(sep_left, clean_style.fg(Color::Yellow)),
                        ]),
                        Line::from(format!(" Tool: {}", p.name)).style(clean_style),
                    ];
                    for line in args_display.lines() {
                        approval_lines.push(Line::from(format!("   {}", line)).style(clean_style.fg(Color::Yellow)));
                    }
                    approval_lines.push(Line::from(vec![
                        Span::styled(" [1] Approve ", clean_style.bg(theme.user_bg).fg(theme.user_fg)),
                        Span::raw("  "),
                        Span::styled(" [2] Always ", clean_style.bg(theme.user_bg).fg(theme.user_fg)),
                        Span::raw("  "),
                        Span::styled(" [3] Reject ", clean_style.bg(Color::Red).fg(Color::White)),
                    ]));
                    history_items.push(ListItem::new(approval_lines));
                }
                AgentStatus::Error(e) => {
                    history_items.push(ListItem::new(Line::from(vec![
                        Span::styled(" ERROR ", clean_style.bg(Color::Red).fg(Color::White).add_modifier(Modifier::BOLD)),
                        Span::raw(format!(" {}", e)).style(clean_style),
                    ])));
                }
                _ => {}
            }
            
            if !history_items.is_empty() {
                list_state.select(Some(history_items.len() - 1));
            }

            f.render_stateful_widget(List::new(history_items), chunks[0], &mut list_state);

            f.render_widget(Block::default().borders(Borders::BOTTOM).border_style(clean_style.fg(theme.border)), chunks[1]);

            textarea.set_block(Block::default());
            textarea.set_style(clean_style.fg(theme.input_text));
            // Ensure cursor line style is always clean
            textarea.set_cursor_line_style(Style::default().remove_modifier(Modifier::UNDERLINED));
            f.render_widget(&textarea, chunks[2]);

            f.render_widget(Block::default().borders(Borders::TOP).border_style(clean_style.fg(theme.border)), chunks[3]);

            let status_style = clean_style.bg(theme.status_bg).fg(theme.status_fg);
            let status_text = vec![
                Span::styled(" NORMAL ", status_style.add_modifier(Modifier::BOLD)),
                Span::styled(sep_left, clean_style.fg(theme.status_bg).bg(Color::Black)),
                Span::raw(format!(" Model: {} ", current_model)),
                Span::raw(" | "),
                Span::raw(match status {
                    AgentStatus::Idle => "Ready",
                    AgentStatus::Thinking => "Thinking...",
                    AgentStatus::WaitingForApproval(_) => "Waiting for Approval",
                    AgentStatus::Error(_) => "Error",
                }),
                Span::raw(format!(" | Build: {} ", agent.build_info)),
                Span::styled(sep_right, clean_style.fg(theme.status_bg).bg(Color::Black)),
            ];
            f.render_widget(Paragraph::new(Line::from(status_text)), chunks[4]);
        })?;

        if event::poll(std::time::Duration::from_millis(50))? {
            if let Event::Key(key) = event::read()? {
                if key.kind != KeyEventKind::Press { continue; }

                if key.modifiers.contains(event::KeyModifiers::CONTROL) && key.code == KeyCode::Char('c') {
                    return Ok(());
                }

                let status = agent.status.lock().await.clone();
                if let AgentStatus::WaitingForApproval(p) = status {
                    match key.code {
                        KeyCode::Char('1') => {
                            let agent_clone = agent.clone();
                            tokio::spawn(async move { let _ = agent_clone.execute_tool(p).await; });
                            continue;
                        }
                        KeyCode::Char('2') => {
                            let agent_clone = agent.clone();
                            let p_name = p.name.clone();
                            tokio::spawn(async move {
                                agent_clone.session_approved_tools.lock().await.insert(p_name);
                                let _ = agent_clone.execute_tool(p).await;
                            });
                            continue;
                        }
                        KeyCode::Char('3') => {
                            *agent.status.lock().await = AgentStatus::Idle;
                            continue;
                        }
                        _ => {}
                    }
                }

                match key.code {
                    KeyCode::Enter if !key.modifiers.contains(event::KeyModifiers::SHIFT) => {
                        let user_input = textarea.lines().join("\n");
                        textarea = TextArea::default();
                        textarea.set_cursor_line_style(Style::default().remove_modifier(Modifier::UNDERLINED));
                        textarea.set_style(clean_style.fg(theme.input_text));
                        
                        if user_input.trim().is_empty() { continue; }

                        if user_input.starts_with("/model ") {
                            let model_name = user_input["/model ".len()..].trim().to_string();
                            let agent_clone = agent.clone();
                            tokio::spawn(async move {
                                let _ = agent_clone.switch_model(&model_name).await;
                            });
                            continue;
                        }

                        if user_input.starts_with("/theme ") {
                            let theme_name = user_input["/theme ".len()..].trim().to_lowercase();
                            match theme_name.as_str() {
                                "dracula" => theme = DRACULA,
                                "nord" => theme = NORD,
                                "default" => theme = DEFAULT,
                                _ => {}
                            }
                            continue;
                        }

                        if user_input.trim() == "/clear" {
                            agent.history.lock().await.truncate(1); 
                            continue;
                        }

                        if user_input.trim() == "/quit" || user_input.trim() == "/exit" {
                            return Ok(());
                        }

                        let agent_clone = agent.clone();
                        tokio::spawn(async move {
                            let _ = agent_clone.add_user_message(user_input).await;
                        });
                    }
                    _ => { 
                        // Implement manual soft wrap simulation
                        let area_width = terminal.size()?.width.saturating_sub(2) as usize;
                        if area_width > 0 {
                            let (row, col) = textarea.cursor();
                            let line_len = textarea.lines()[row].len();
                            if line_len >= area_width && key.code != KeyCode::Backspace && key.code != KeyCode::Delete {
                                // If we are at the edge, insert a newline
                                // This is a "hard" wrap for display purposes in this edit mode
                                // For a true soft wrap editor we'd need a different widget
                                // But for now this allows the box to expand
                                if col >= area_width {
                                     textarea.insert_newline();
                                }
                            }
                        }
                        textarea.input(key); 
                    }
                }
            }
        }
    }
}
