use engine_parity::{
    LlamaServerAdapter, MistralrsAdapter, ParityRun, ProviderAdapter, check_run,
    render_markdown_report,
};
use std::env;
use std::fs;
use std::path::Path;

fn main() -> Result<(), Box<dyn std::error::Error>> {
    let mut args = env::args().skip(1);
    let Some(command) = args.next() else {
        print_usage();
        return Ok(());
    };

    match command.as_str() {
        "check" => {
            let Some(path) = args.next() else {
                eprintln!("missing path to parity JSON result");
                std::process::exit(2);
            };
            let run = read_parity_run(Path::new(&path))?;
            match check_run(&run) {
                Ok(()) => {
                    println!("G2 parity check: PASS");
                    Ok(())
                }
                Err(error) => {
                    eprintln!("G2 parity check: FAIL: {error}");
                    std::process::exit(1);
                }
            }
        }
        "render" => {
            let Some(path) = args.next() else {
                eprintln!("missing path to parity JSON result");
                std::process::exit(2);
            };
            let run = read_parity_run(Path::new(&path))?;
            let passed = check_run(&run).is_ok();
            println!("{}", render_markdown_report(&run, passed));
            Ok(())
        }
        "run-llama" => {
            let Some(input) = args.next() else {
                eprintln!("missing input parity JSON fixture");
                std::process::exit(2);
            };
            let Some(endpoint) = args.next() else {
                eprintln!("missing llama-server endpoint");
                std::process::exit(2);
            };
            let Some(model) = args.next() else {
                eprintln!("missing model name");
                std::process::exit(2);
            };
            let Some(output) = args.next() else {
                eprintln!("missing output path");
                std::process::exit(2);
            };
            let mut run = read_parity_run(Path::new(&input))?;
            let adapter = LlamaServerAdapter::new(endpoint, model);
            run.fallback = adapter.run_case(&run.case)?;
            write_parity_run(Path::new(&output), &run)?;
            println!("wrote llama.cpp fallback result to {output}");
            Ok(())
        }
        "run-mistral" => {
            let Some(input) = args.next() else {
                eprintln!("missing input parity JSON fixture");
                std::process::exit(2);
            };
            let Some(model) = args.next() else {
                eprintln!("missing mistral.rs model id");
                std::process::exit(2);
            };
            let Some(output) = args.next() else {
                eprintln!("missing output path");
                std::process::exit(2);
            };
            let mut run = read_parity_run(Path::new(&input))?;
            let adapter = MistralrsAdapter::auto(model, 256);
            run.primary = adapter.run_case(&run.case)?;
            write_parity_run(Path::new(&output), &run)?;
            println!("wrote mistral.rs primary result to {output}");
            Ok(())
        }
        "run-both" => {
            let Some(input) = args.next() else {
                eprintln!("missing input parity JSON fixture");
                std::process::exit(2);
            };
            let Some(mistral_model) = args.next() else {
                eprintln!("missing mistral.rs model id");
                std::process::exit(2);
            };
            let Some(llama_endpoint) = args.next() else {
                eprintln!("missing llama-server endpoint");
                std::process::exit(2);
            };
            let Some(llama_model) = args.next() else {
                eprintln!("missing llama-server model name");
                std::process::exit(2);
            };
            let Some(output) = args.next() else {
                eprintln!("missing output path");
                std::process::exit(2);
            };
            let mut run = read_parity_run(Path::new(&input))?;
            let mistral = MistralrsAdapter::auto(mistral_model, 256);
            let llama = LlamaServerAdapter::new(llama_endpoint, llama_model);
            run.primary = mistral.run_case(&run.case)?;
            run.fallback = llama.run_case(&run.case)?;
            write_parity_run(Path::new(&output), &run)?;
            match check_run(&run) {
                Ok(()) => println!("G2 parity run: PASS ({output})"),
                Err(error) => {
                    eprintln!("G2 parity run: FAIL: {error} ({output})");
                    std::process::exit(1);
                }
            }
            Ok(())
        }
        _ => {
            print_usage();
            std::process::exit(2);
        }
    }
}

fn read_parity_run(path: &Path) -> Result<ParityRun, Box<dyn std::error::Error>> {
    let content = fs::read_to_string(path)?;
    let run = serde_json::from_str::<ParityRun>(&content)?;
    Ok(run)
}

fn write_parity_run(path: &Path, run: &ParityRun) -> Result<(), Box<dyn std::error::Error>> {
    if let Some(parent) = path.parent() {
        fs::create_dir_all(parent)?;
    }
    let json = serde_json::to_string_pretty(run)?;
    fs::write(path, format!("{json}\n"))?;
    Ok(())
}

fn print_usage() {
    eprintln!("engine-parity check <result.json>");
    eprintln!("engine-parity render <result.json>");
    eprintln!(
        "engine-parity run-llama <input-result.json> <endpoint> <model> <output-result.json>"
    );
    eprintln!("engine-parity run-mistral <input-result.json> <model-id> <output-result.json>");
    eprintln!(
        "engine-parity run-both <input-result.json> <mistral-model-id> <llama-endpoint> <llama-model> <output-result.json>"
    );
}
