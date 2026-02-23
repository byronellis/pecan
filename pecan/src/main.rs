use clap::Parser;
use pecan_core::Agent;
use pecan_providers::{LlamaCppProvider, MockProvider, Provider};
use std::io::{self, Write, IsTerminal};
use std::sync::Arc;

#[derive(Parser, Debug)]
#[command(author, version, about, long_about = None)]
struct Args {
    /// URL of the llama.cpp server
    #[arg(short, long)]
    url: Option<String>,

    /// Use mock provider
    #[arg(short, long)]
    mock: bool,

    /// Start in TUI mode
    #[arg(short, long)]
    tui: bool,

    /// Run a single prompt and exit
    #[arg(short, long)]
    prompt: Option<String>,
}

#[tokio::main]
async fn main() -> anyhow::Result<()> {
    tracing_subscriber::fmt::init();

    let args = Args::parse();

    let mut config = pecan_core::config::Config::load()?;

    // Override with CLI args if provided
    if let Some(url) = args.url {
        config.models.insert("cli-override".to_string(), pecan_core::config::ModelDef {
            name: "cli-override".to_string(),
            provider: "llama.cpp".to_string(),
            url,
            api_key: None,
            model_id: None,
            description: None,
        });
        config.default_model = "cli-override".to_string();
    } else if args.mock {
        config.default_model = "mock".to_string();
    }

    let agent = Agent::new(config, "pecan_memory").await?;

    // If a prompt is provided, run it and exit
    if let Some(prompt) = args.prompt {
        match agent.chat(prompt).await {
            Ok(response) => {
                if response == "WAITING_FOR_APPROVAL" {
                    let pending = agent.pending_tool_call.lock().await;
                    if let Some(p) = &*pending {
                        println!("Tool Approval Required: {} with args {}", p.tool_name, p.arguments);
                    }
                } else {
                    println!("{}", response);
                }
                return Ok(());
            }
            Err(e) => {
                eprintln!("Error: {}", e);
                std::process::exit(1);
            }
        }
    }

    // Default to TUI unless explicitly asked for non-tui
    if !args.tui && std::io::stdin().is_terminal() {
        return pecan_tui::run_tui(agent).await;
    }

    if args.tui {
        return pecan_tui::run_tui(agent).await;
    }

    println!("Pecan Agent ready. Type 'exit' to quit.");

    loop {
        print!("> ");
        io::stdout().flush()?;

        let mut input = String::new();
        io::stdin().read_line(&mut input)?;
        let input = input.trim();

        if input == "exit" || input == "quit" {
            break;
        }

        if input.is_empty() {
            continue;
        }

        match agent.chat(input.to_string()).await {
            Ok(response) => {
                println!("\nAssistant: {}\n", response);
            }
            Err(e) => {
                eprintln!("Error: {}", e);
            }
        }
    }

    Ok(())
}
