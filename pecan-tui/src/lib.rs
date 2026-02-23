mod theme;

use ratatui::{
    backend::CrosstermBackend,
    layout::{Constraint, Direction, Layout},
    style::{Color, Modifier, Style},
    text::{Line, Span},
    widgets::{Block, Borders, List, ListItem, ListState, Paragraph},
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
    textarea.set_cursor_line_style(Style::default());
    
    let mut theme = DRACULA;
    let mut spinner_index = 0;
    let spinner = ["⠋", "⠙", "⠹", "⠸", "⠼", "⠴", "⠦", "⠧", "⠇", "⠏"];
    let mut list_state = ListState::default();

    let (sep_left, sep_right) = if is_iterm {
        ("\u{e0b0}", "\u{e0b2}") 
    } else {
        ("|", "|")
    };

    loop {
        let history = agent.history.lock().await.clone();
        let status = agent.status.lock().await.clone();
        let current_model = {
            let config = agent.config.lock().await;
            config.default_model.clone()
        };

        terminal.draw(|f| {
            let input_lines = textarea.lines().len() as u16;
            let input_height = input_lines.min(10).max(1) + 2; 

            let chunks = Layout::default()
                .direction(Direction::Vertical)
                .constraints([
                    Constraint::Min(1),               
                    Constraint::Length(input_height), 
                    Constraint::Length(1),            
                ].as_ref())
                .split(f.area());

            let mut history_items: Vec<ListItem> = history
                .iter()
                .filter(|m| m.role != Role::System)
                .map(|m| {
                    if m.role == Role::User {
                        let style = Style::default().bg(theme.user_bg).fg(theme.user_fg);
                        let content = m.content.as_deref().unwrap_or("");
                        let mut lines: Vec<Line> = content.lines()
                            .map(|l| Line::from(format!(" {}", l)).style(style))
                            .collect();
                        lines.push(Line::from("")); 
                        ListItem::new(lines)
                    } else if m.role == Role::Assistant {
                        let style = Style::default().fg(theme.agent_text);
                        let content = m.content.as_deref().unwrap_or("");
                        let mut lines: Vec<Line> = Vec::new();
                        
                        if !content.is_empty() {
                            for l in content.lines() {
                                lines.push(Line::from(format!(" {}", l)).style(style));
                            }
                        }

                        if let Some(tool_calls) = &m.tool_calls {
                            for call in tool_calls {
                                lines.push(Line::from(vec![
                                    Span::styled(format!(" [Call: {}] ", call.function.name), Style::default().bg(theme.highlight).fg(Color::Black)),
                                ]));
                            }
                        }

                        lines.push(Line::from("")); 
                        ListItem::new(lines)
                    } else {
                        let content = m.content.as_deref().unwrap_or("");
                        let mut lines = vec![Line::from(vec![Span::styled(" [Tool Result] ", Style::default().fg(Color::Gray))])];
                        for l in content.lines() {
                            lines.push(Line::from(format!(" {}", l)).style(Style::default().fg(Color::DarkGray)));
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
                        Span::styled(format!(" {} ", spinner[spinner_index]), Style::default().fg(theme.highlight)),
                        Span::styled("Agent is working...", Style::default().fg(Color::DarkGray)),
                    ])));
                }
                AgentStatus::WaitingForApproval(p) => {
                    let args_display = serde_json::to_string_pretty(&p.args).unwrap_or_else(|_| p.args.to_string());
                    let mut approval_lines = vec![
                        Line::from(vec![
                            Span::styled(" TOOL APPROVAL REQUIRED ", Style::default().bg(Color::Yellow).fg(Color::Black).add_modifier(Modifier::BOLD)),
                            Span::styled(sep_left, Style::default().fg(Color::Yellow)),
                        ]),
                        Line::from(format!(" Tool: {}", p.name)),
                    ];
                    for line in args_display.lines() {
                        approval_lines.push(Line::from(format!("   {}", line)).style(Style::default().fg(Color::Yellow)));
                    }
                    approval_lines.push(Line::from(vec![
                        Span::styled(" [1] Approve ", Style::default().bg(theme.user_bg).fg(theme.user_fg)),
                        Span::raw("  "),
                        Span::styled(" [2] Always ", Style::default().bg(theme.user_bg).fg(theme.user_fg)),
                        Span::raw("  "),
                        Span::styled(" [3] Reject ", Style::default().bg(Color::Red).fg(Color::White)),
                    ]));
                    history_items.push(ListItem::new(approval_lines));
                }
                AgentStatus::Error(e) => {
                    history_items.push(ListItem::new(Line::from(vec![
                        Span::styled(" ERROR ", Style::default().bg(Color::Red).fg(Color::White).add_modifier(Modifier::BOLD)),
                        Span::raw(format!(" {}", e)),
                    ])));
                }
                _ => {}
            }
            
            if !history_items.is_empty() {
                list_state.select(Some(history_items.len() - 1));
            }

            f.render_stateful_widget(List::new(history_items), chunks[0], &mut list_state);

            textarea.set_block(Block::default().borders(Borders::ALL).title(" Input ").border_style(Style::default().fg(theme.border)));
            textarea.set_style(Style::default().fg(theme.input_text));
            f.render_widget(&textarea, chunks[1]);

            let status_style = Style::default().bg(theme.status_bg).fg(theme.status_fg);
            let status_text = vec![
                Span::styled(" NORMAL ", status_style.add_modifier(Modifier::BOLD)),
                Span::styled(sep_left, Style::default().fg(theme.status_bg).bg(Color::Black)),
                Span::raw(format!(" Model: {} ", current_model)),
                Span::raw(" | "),
                Span::raw(match status {
                    AgentStatus::Idle => "Ready",
                    AgentStatus::Thinking => "Thinking...",
                    AgentStatus::WaitingForApproval(_) => "Waiting for Approval",
                    AgentStatus::Error(_) => "Error",
                }),
                Span::styled(sep_right, Style::default().fg(theme.status_bg).bg(Color::Black)),
            ];
            f.render_widget(Paragraph::new(Line::from(status_text)), chunks[2]);
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
                            agent.history.lock().await.truncate(1); // Keep system prompt
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
                    _ => { textarea.input(key); }
                }
            }
        }
    }
}
