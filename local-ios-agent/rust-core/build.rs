use std::env;
use std::fs;
use std::path::{Path, PathBuf};

fn main() {
    println!("cargo:rerun-if-env-changed=LOCAL_AGENT_INFERENCE_XCFRAMEWORK");
    let links_local_inference = env::var_os("CARGO_FEATURE_LINK_MOCK_LOCAL_INFERENCE").is_some()
        || env::var_os("CARGO_FEATURE_LINK_LLAMA_CPP_LOCAL_INFERENCE").is_some()
        || env::var_os("CARGO_FEATURE_LINK_LLAMA_CPP_MTMD_LOCAL_INFERENCE").is_some()
        || env::var_os("CARGO_FEATURE_LINK_LITERT_LOCAL_INFERENCE").is_some();
    if !links_local_inference {
        return;
    }

    let xcframework = env::var_os("LOCAL_AGENT_INFERENCE_XCFRAMEWORK")
        .map(PathBuf::from)
        .unwrap_or_else(|| {
            PathBuf::from(env::var("CARGO_MANIFEST_DIR").expect("CARGO_MANIFEST_DIR"))
                .join("../toolkit/Artifacts/LocalAgentInferenceNative.xcframework")
        });
    let archive = find_archive_for_target(&xcframework).unwrap_or_else(|| {
        panic!(
            "missing local inference slice for {} in {}",
            env::var("TARGET").unwrap_or_default(),
            xcframework.display()
        )
    });
    println!("cargo:rerun-if-changed={}", archive.display());
    println!(
        "cargo:rustc-link-search=native={}",
        archive.parent().expect("native archive parent").display()
    );
    println!("cargo:rustc-link-lib=static:-bundle=local_agent_inference_native");
    match env::var("CARGO_CFG_TARGET_OS").unwrap_or_default().as_str() {
        "ios" | "macos" => println!("cargo:rustc-link-lib=dylib=c++"),
        _ => println!("cargo:rustc-link-lib=dylib=stdc++"),
    }
}

fn find_archive_for_target(root: &Path) -> Option<PathBuf> {
    let target = env::var("TARGET").unwrap_or_default();
    let slice = if target.contains("apple-ios-sim") {
        "ios-arm64-simulator"
    } else if target.contains("apple-ios") {
        "ios-arm64"
    } else if target.contains("apple-darwin") {
        "macos-arm64"
    } else {
        return None;
    };
    let mut candidates = Vec::new();
    collect_archives(root, &mut candidates);
    candidates
        .into_iter()
        .find(|path| path.to_string_lossy().contains(slice))
}

fn collect_archives(path: &Path, candidates: &mut Vec<PathBuf>) {
    let Ok(entries) = fs::read_dir(path) else {
        return;
    };
    for entry in entries.flatten() {
        let path = entry.path();
        if path.is_dir() {
            collect_archives(&path, candidates);
        } else if path.file_name().and_then(|name| name.to_str())
            == Some("liblocal_agent_inference_native.a")
        {
            candidates.push(path);
        }
    }
}
