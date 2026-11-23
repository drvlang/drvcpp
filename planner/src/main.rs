use ini::Ini;
use serde::Serialize;
use std::{
    collections::{BTreeMap, BTreeSet},
    env,
    path::Path,
    process::ExitCode,
};
#[derive(Serialize, PartialEq)]
struct Archive {
    sha256: String,
    urls: Vec<String>,
}
#[derive(Default, Serialize)]
struct Plan {
    directories: BTreeSet<String>,
    archives: BTreeMap<String, Archive>,
}
fn basename(value: &str) -> bool {
    !value.is_empty()
        && !value.starts_with('.')
        && value
            .bytes()
            .all(|b| b.is_ascii_alphanumeric() || b"._+-".contains(&b))
}
fn add(plan: &mut Plan, file: &Path) -> Result<(), Box<dyn std::error::Error>> {
    let ini = Ini::load_from_file_noescape(file)?;
    let wrap = ini
        .section(Some("wrap-file"))
        .ok_or("expected a [wrap-file] archive lock")?;
    let dir = wrap
        .get("directory")
        .or_else(|| file.file_stem()?.to_str())
        .ok_or("missing wrap directory")?;
    if !basename(dir)
        || matches!(dir, "packagefiles" | "packagecache")
        || !plan.directories.insert(dir.to_owned())
    {
        return Err(format!("invalid or repeated subproject directory: {dir}").into());
    }
    for kind in ["source", "patch"] {
        let get = |field: &str| wrap.get(format!("{kind}_{field}"));
        if kind == "patch"
            && ["filename", "url", "hash", "fallback_url"]
                .iter()
                .all(|k| get(k).is_none())
        {
            continue;
        }
        let filename = get("filename")
            .filter(|n| basename(n))
            .ok_or("missing or unsafe archive filename")?;
        let hash = get("hash")
            .filter(|v| v.len() == 64 && v.bytes().all(|b| b.is_ascii_hexdigit()))
            .ok_or("expected archive SHA-256")?;
        let mut urls = vec![get("url").ok_or("missing archive URL")?.to_string()];
        if let Some(other) = get("fallback_url") {
            urls.push(other.into());
        }
        if !urls
            .iter()
            .all(|u| u.starts_with("https://") && !u.contains('@'))
        {
            return Err("expected public HTTPS archive URLs".into());
        }
        let archive = Archive {
            sha256: hash.to_ascii_lowercase(),
            urls,
        };
        if let Some(old) = plan.archives.insert(filename.to_owned(), archive) {
            if old.sha256 != hash.to_ascii_lowercase() {
                return Err(format!("conflicting hashes for {filename}").into());
            }
        }
    }
    Ok(())
}
fn main() -> ExitCode {
    let mut plan = Plan::default();
    for path in env::args_os().skip(1) {
        if let Err(e) = add(&mut plan, Path::new(&path)) {
            eprintln!("{}: {e}", Path::new(&path).display());
            return ExitCode::FAILURE;
        }
    }
    match serde_json::to_writer(std::io::stdout().lock(), &plan) {
        Ok(()) => ExitCode::SUCCESS,
        Err(e) => {
            eprintln!("{e}");
            ExitCode::FAILURE
        }
    }
}
