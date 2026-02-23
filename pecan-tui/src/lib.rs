mod theme;

use ratatui::{
    backend::CrosstermBackend,
    layout::{Constraint, Direction, Layout},
    style::{Color, Modifier, Style},
    text::{Line, Span},
    widgets::{Block, Borders, List, ListItem, Paragraph},
    Terminal,
};
use ratatui::crossterm::{
    event::{self, DisableMouseCapture, EnableMouseCapture, Event, KeyCode, KeyEventKind},
    execute,
    terminal::{disable_raw_mode, enable_raw_mode, EnterAlternateScreen, LeaveAlternateScreen},
};
use std::io;
use std::sync::Arc;
use pecan_core::Agent;
use theme::{DRACULA, NORD, DEFAULT};
use ratatui_textarea::TextArea;

pub async fn run_tui(agent: Agent) -> anyhow::Result<()> {
    let is_iterm = std::env::var("TERM_PROGRAM").map(|v| v == "iTerm.app").unwrap_or(false);
    
    enable_raw_mode()?;
    let mut stdout = io::stdout();
    execute!(stdout, EnterAlternateScreen, EnableMouseCapture)?;
    
    if is_iterm {
        let _ = execute!(stdout, event::PushKeyboardEnhancementFlags(
            event::KeyboardEnhancementFlags::REPORT_EVENT_TYPES
        ));
    }

    let backend = CrosstermBackend::new(stdout);
    let mut terminal = Terminal::new(backend)?;

    let res = run_loop(&mut terminal, agent, is_iterm).await;

    if is_iterm {
        let _ = execute!(io::stdout(), event::PopKeyboardEnhancementFlags);
    }
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
    
    let mut messages: Vec<(String, String)> = Vec::new(); 
    let (tx, mut rx) = tokio::sync::mpsc::channel::<String>(10);
    let mut is_thinking = false;
    let mut current_model = "default".to_string(); 
    let mut theme = DRACULA;

    let agent = Arc::new(agent);
    let commands = vec!["/model ", "/theme ", "/quit", "/help", "/clear", "/task ", "/pause", "/resume"];
    let themes = vec!["dracula", "nord", "default"];

    let (sep_left, sep_right) = if is_iterm {
        ("\u{e0b0}", "\u{e0b2}") 
    } else {
        ("|", "|")
    };

    loop {
        let (task_list, is_paused) = {
            let stack = agent.task_stack.lock().await;
            let paused = agent.paused.lock().await;
            (stack.tasks.clone(), *paused)
        };

        terminal.draw(|f| {
            let input_lines = textarea.lines().len() as u16;
            let input_height = input_lines.min(10); 

            // LAYOUT: 
            // Main horizontal split for Sidebar
            let main_chunks = Layout::default()
                .direction(Direction::Horizontal)
                .constraints([
                    Constraint::Min(1), // Chat & Input
                    Constraint::Length(if !task_list.is_empty() { 30 } else { 0 }), // Sidebar
                ].as_ref())
                .split(f.area());

            // Left side: Vertical layout for Chat, Dividers, Input, Status
            let left_chunks = Layout::default()
                .direction(Direction::Vertical)
                .constraints([
                    Constraint::Min(1),               // Chat
                    Constraint::Length(1),            // Divider
                    Constraint::Length(input_height), // Input
                    Constraint::Length(1),            // Divider
                    Constraint::Length(1),            // Status
                ].as_ref())
                .split(main_chunks[0]);

            // 1. Chat Area
            let mut history_items: Vec<ListItem> = messages
                .iter()
                .map(|(role, content)| {
                    if role == "You" {
                        let style = Style::default().bg(theme.user_bg).fg(theme.user_fg);
                        // Split content by newlines and style each line
                        let mut lines: Vec<Line> = content.lines()
                            .map(|l| Line::from(format!(" {}", l)).style(style))
                            .collect();
                        lines.push(Line::from("")); // Spacer
                        ListItem::new(lines)
                    } else if role == "Agent" {
                        let style = Style::default().fg(theme.agent_text);
                        let mut lines: Vec<Line> = content.lines()
                            .map(|l| Line::from(format!(" {}", l)).style(style))
                            .collect();
                        lines.push(Line::from("")); // Spacer
                        ListItem::new(lines)
                    } else {
                        // System messages
                        let mut lines = vec![Line::from(vec![Span::styled(format!(" {} ", role), Style::default().fg(Color::Gray))])];
                        for l in content.lines() {
                            lines.push(Line::from(format!(" {}", l)));
                        }
                        lines.push(Line::from(""));
                        ListItem::new(lines)
                    }
                })
                .collect();
            
            if is_thinking {
                history_items.push(ListItem::new(Line::from(" Agent is thinking...").style(Style::default().fg(Color::DarkGray))));
            }
            
            let history_list = List::new(history_items);
            f.render_widget(history_list, left_chunks[0]);

            // Sidebar: Task Stack
            if !task_list.is_empty() {
                let mut task_items: Vec<ListItem> = vec![
                    ListItem::new(Line::from(vec![
                        Span::styled(" TASK STACK ", Style::default().bg(theme.status_bg).fg(theme.status_fg).add_modifier(Modifier::BOLD)),
                        Span::styled(sep_left, Style::default().fg(theme.status_bg)),
                    ])),
                    ListItem::new(Line::from("")),
                ];

                for (i, task) in task_list.iter().enumerate() {
                    let status_symbol = match task.status {
                        pecan_core::TaskStatus::Pending => " [ ] ",
                        pecan_core::TaskStatus::InProgress => " [*] ",
                        pecan_core::TaskStatus::Completed => " [x] ",
                        pecan_core::TaskStatus::Failed(_) => " [!] ",
                    };
                    task_items.push(ListItem::new(Line::from(vec![
                        Span::raw(format!("{}.{}", i + 1, status_symbol)),
                        Span::raw(&task.description),
                    ])));
                }

                let sidebar = List::new(task_items)
                    .block(Block::default().borders(Borders::LEFT).border_style(Style::default().fg(theme.border)));
                f.render_widget(sidebar, main_chunks[1]);
            }

            // 2. Divider Above Input
            f.render_widget(Block::default().borders(Borders::BOTTOM).border_style(Style::default().fg(theme.border)), left_chunks[1]);

            // 3. Input Area
            textarea.set_style(Style::default().fg(theme.input_text));
            textarea.set_block(Block::default()); 
            f.render_widget(&textarea, left_chunks[2]);

            // 4. Divider Below Input
            f.render_widget(Block::default().borders(Borders::TOP).border_style(Style::default().fg(theme.border)), left_chunks[3]);

            // 5. Status Bar
            let status_style = Style::default().bg(theme.status_bg).fg(theme.status_fg);
            let status_text = vec![
                Span::styled(" NORMAL ", status_style.add_modifier(Modifier::BOLD)),
                Span::styled(sep_left, Style::default().fg(theme.status_bg).bg(Color::Black)),
                Span::raw(format!(" Model: {} ", current_model)),
                Span::raw(" | "),
                Span::raw(if is_paused { "Paused" } else if is_thinking { "Thinking..." } else { "Ready" }),
                Span::styled(sep_right, Style::default().fg(theme.status_bg).bg(Color::Black)),
            ];
            let status_bar = Paragraph::new(Line::from(status_text));
            f.render_widget(status_bar, left_chunks[4]);
        })?;

        if let Ok(response) = rx.try_recv() {
            messages.push(("Agent".to_string(), response));
            is_thinking = false;
        }

        if event::poll(std::time::Duration::from_millis(50))? {
            let ev = event::read()?;
            if let Event::Key(key) = ev {
                if key.kind != KeyEventKind::Press {
                    continue;
                }

                if key.modifiers.contains(event::KeyModifiers::CONTROL) && key.code == KeyCode::Char('c') {
                    return Ok(());
                }

                if is_thinking {
                    // Even if thinking, allow pause/resume?
                }

                match key.code {
                    KeyCode::Tab => {
                        let line = &textarea.lines()[0]; 
                        if line.starts_with("/model ") {
                            let partial = &line["/model ".len()..];
                            let config = agent.config.lock().await;
                            let matches: Vec<_> = config.models.keys()
                                .filter(|m| m.starts_with(partial))
                                .collect();
                            if matches.len() == 1 {
                                textarea.delete_line_by_head();
                                textarea.insert_str(format!("/model {}", matches[0]));
                            }
                        } else if line.starts_with("/theme ") {
                            let partial = &line["/theme ".len()..];
                            let matches: Vec<_> = themes.iter()
                                .filter(|t| t.starts_with(partial))
                                .collect();
                            if matches.len() == 1 {
                                textarea.delete_line_by_head();
                                textarea.insert_str(format!("/theme {}", matches[0]));
                            }
                        } else if line.starts_with("/") {
                            let matches: Vec<_> = commands.iter()
                                .filter(|c| c.starts_with(line))
                                .collect();
                            if matches.len() == 1 {
                                textarea.delete_line_by_head();
                                textarea.insert_str(matches[0]);
                            }
                        }
                    }
                    KeyCode::Enter if !key.modifiers.contains(event::KeyModifiers::SHIFT) => {
                        let user_input = textarea.lines().join("\n");
                        textarea.move_cursor(ratatui_textarea::CursorMove::End);
                        while !textarea.is_empty() {
                            textarea.delete_line_by_head();
                        }
                        
                        if user_input.trim().is_empty() {
                            continue;
                        }
                        
                        if user_input.starts_with("/pause") {
                            let mut paused = agent.paused.lock().await;
                            *paused = true;
                            messages.push(("System".to_string(), "Autonomous loop paused.".to_string()));
                            continue;
                        }

                        if user_input.starts_with("/resume") {
                            let mut paused = agent.paused.lock().await;
                            *paused = false;
                            messages.push(("System".to_string(), "Autonomous loop resumed.".to_string()));
                            continue;
                        }

                        if user_input.starts_with("/model ") {
                            let model_name = user_input["/model ".len()..].trim().to_string();
                            current_model = model_name.clone();
                            let agent_clone = agent.clone();
                            let tx_clone = tx.clone();
                            tokio::spawn(async move {
                                match agent_clone.switch_model(&model_name).await {
                                    Ok(_) => {
                                        let _ = tx_clone.send(format!("Switched to model: {}", model_name)).await;
                                    }
                                    Err(e) => {
                                        let _ = tx_clone.send(format!("Failed to switch model: {}", e)).await;
                                    }
                                }
                            });
                            continue;
                        }

                        if user_input.starts_with("/theme ") {
                            let theme_name = user_input["/theme ".len()..].trim().to_lowercase();
                            match theme_name.as_str() {
                                "dracula" => theme = DRACULA,
                                "nord" => theme = NORD,
                                "default" => theme = DEFAULT,
                                _ => messages.push(("System".to_string(), format!("Unknown theme: {}. Available: dracula, nord, default", theme_name))),
                            }
                            continue;
                        }

                        if user_input.trim() == "/clear" {
                            messages.clear();
                            continue;
                        }

                        if user_input.starts_with("/task ") {
                            let task_desc = user_input["/task ".len()..].trim().to_string();
                            let agent_clone = agent.clone();
                            let tx_clone = tx.clone();
                            tokio::spawn(async move {
                                {
                                    let mut stack = agent_clone.task_stack.lock().await;
                                    stack.push(task_desc.clone());
                                }
                                let _ = tx_clone.send(format!("Started autonomous task: {}", task_desc)).await;
                                match agent_clone.run_autonomous_loop().await {
                                    Ok(_) => {
                                        let _ = tx_clone.send("Autonomous loop finished.".to_string()).await;
                                    }
                                    Err(e) => {
                                        let _ = tx_clone.send(format!("Autonomous loop failed: {}", e)).await;
                                    }
                                }
                            });
                            continue;
                        }

                        if user_input.trim() == "exit" || user_input.trim() == "quit" || user_input.trim() == "/quit" || user_input.trim() == "/exit" {
                            return Ok(());
                        }

                        if user_input.trim() == "/help" {
                            messages.push(("System".to_string(), "Commands: /model <name>, /theme <name>, /task <desc>, /pause, /resume, /clear, /quit, /help".to_string()));
                            continue;
                        }

                        messages.push(("You".to_string(), user_input.clone()));
                        is_thinking = true;
                        
                        let agent_clone = agent.clone();
                        let tx_clone = tx.clone();
                        tokio::spawn(async move {
                            match agent_clone.chat(user_input).await {
                                Ok(response) => {
                                    let _ = tx_clone.send(response).await;
                                }
                                Err(e) => {
                                    let _ = tx_clone.send(format!("Error: {}", e)).await;
                                }
                            }
                        });
                    }
                    _ => {
                        textarea.input(key);
                    }
                }
            }
        }
    }
}
