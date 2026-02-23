use ratatui::{
    backend::CrosstermBackend,
    layout::{Constraint, Direction, Layout},
    style::{Color, Modifier, Style},
    text::{Line, Span, Text},
    widgets::{Block, Borders, List, ListItem, Paragraph},
    Terminal,
};
use crossterm::{
    event::{self, DisableMouseCapture, EnableMouseCapture, Event, KeyCode},
    execute,
    terminal::{disable_raw_mode, enable_raw_mode, EnterAlternateScreen, LeaveAlternateScreen},
};
use std::io;
use std::sync::Arc;
use pecan_core::Agent;

pub async fn run_tui(agent: Agent) -> anyhow::Result<()> {
    enable_raw_mode()?;
    let mut stdout = io::stdout();
    execute!(stdout, EnterAlternateScreen, EnableMouseCapture)?;
    let backend = CrosstermBackend::new(stdout);
    let mut terminal = Terminal::new(backend)?;

    let res = run_loop(&mut terminal, agent).await;

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
) -> anyhow::Result<()> {
    let mut input = String::new();
    let mut messages: Vec<String> = Vec::new();
    let (tx, mut rx) = tokio::sync::mpsc::channel::<String>(10);
    let mut is_thinking = false;

    let agent = Arc::new(agent);

    loop {
        terminal.draw(|f| {
            let chunks = Layout::default()
                .direction(Direction::Vertical)
                .constraints([
                    Constraint::Min(1),
                    Constraint::Length(3),
                ].as_ref())
                .split(f.size());

            let mut history_items: Vec<ListItem> = messages
                .iter()
                .map(|m| ListItem::new(Line::from(m.clone())))
                .collect();
            
            if is_thinking {
                history_items.push(ListItem::new(Line::from("Agent: thinking...").style(Style::default().fg(Color::DarkGray))));
            }

            let history_list = List::new(history_items)
                .block(Block::default().borders(Borders::ALL).title("Chat History"));
            f.render_widget(history_list, chunks[0]);

            let input_widget = Paragraph::new(input.as_str())
                .style(Style::default().fg(Color::Yellow))
                .block(Block::default().borders(Borders::ALL).title("Input (Type and press Enter)"));
            f.render_widget(input_widget, chunks[1]);
        })?;

        // Check for responses from the agent
        if let Ok(response) = rx.try_recv() {
            messages.push(format!("Agent: {}", response));
            is_thinking = false;
        }

        if event::poll(std::time::Duration::from_millis(50))? {
            if let Event::Key(key) = event::read()? {
                if is_thinking {
                    // Maybe allow cancelling? For now just ignore input while thinking
                    if let KeyCode::Esc = key.code {
                        return Ok(());
                    }
                    continue;
                }

                match key.code {
                    KeyCode::Enter => {
                        let user_input = input.drain(..).collect::<String>();
                        if user_input.trim().is_empty() {
                            continue;
                        }
                        
                        if user_input.starts_with("/model ") {
                            let model_name = user_input["/model ".len()..].trim().to_string();
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

                        if user_input.trim() == "exit" || user_input.trim() == "quit" {
                            return Ok(());
                        }
                        messages.push(format!("You: {}", user_input));
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
                    KeyCode::Char(c) => {
                        input.push(c);
                    }
                    KeyCode::Backspace => {
                        input.pop();
                    }
                    KeyCode::Esc => {
                        return Ok(());
                    }
                    _ => {}
                }
            }
        }
    }
}
