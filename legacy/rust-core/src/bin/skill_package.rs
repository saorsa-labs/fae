//! Manage packaged skills (`SKILL.toml` + `SKILL.md`) from the command line.

use std::path::Path;

fn main() {
    if let Err(e) = run() {
        eprintln!("fae-skill-package failed: {e}");
        std::process::exit(1);
    }
}

fn run() -> fae::Result<()> {
    let args: Vec<String> = std::env::args().collect();
    if args.len() < 2 {
        print_usage();
        return Ok(());
    }

    match args[1].as_str() {
        "install" => {
            if args.len() != 3 {
                return Err(fae::SpeechError::Config(
                    "install requires a package directory path".to_owned(),
                ));
            }
            install_package(Path::new(&args[2]))
        }
        "list" => list_managed(),
        "help" | "--help" | "-h" => {
            print_usage();
            Ok(())
        }
        other => Err(fae::SpeechError::Config(format!(
            "unknown subcommand `{other}` (use install|list)"
        ))),
    }
}

fn install_package(path: &Path) -> fae::Result<()> {
    let info = fae::skills::install_skill_package(path)?;
    println!(
        "installed skill package: id={} name={} version={} state={:?}",
        info.id, info.name, info.version, info.state
    );
    Ok(())
}

fn list_managed() -> fae::Result<()> {
    let skills = fae::skills::list_managed_skills_strict()?;
    if skills.is_empty() {
        println!("no managed skills installed");
        return Ok(());
    }

    for skill in skills {
        println!(
            "{}\t{}\t{}\t{:?}",
            skill.id, skill.name, skill.version, skill.state
        );
    }

    Ok(())
}

fn print_usage() {
    println!("usage: fae-skill-package <install <path>|list>");
}
