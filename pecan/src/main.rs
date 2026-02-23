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

    {
        let mut tools = agent.tools.lock().await;
        tools.register(Arc::new(pecan_core::tools::ReadFile));
        tools.register(Arc::new(pecan_core::tools::WriteFile));
        tools.register(Arc::new(pecan_core::tools::ListDir));
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
