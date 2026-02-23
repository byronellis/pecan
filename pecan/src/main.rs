use clap::Parser;
use pecan_core::Agent;

#[derive(Parser, Debug)]
struct Args {
    #[arg(short, long)]
    tui: bool,
}

#[tokio::main]
async fn main() -> anyhow::Result<()> {
    let _args = Args::parse();
    let config = pecan_core::config::Config::load()?;
    let agent = Agent::new(config, "pecan_memory").await?;

    pecan_tui::run_tui(agent).await?;
    Ok(())
}
