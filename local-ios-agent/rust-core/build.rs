use std::env;
use std::path::PathBuf;
use std::process::Command;

fn main() {
    let manifest_dir = PathBuf::from(env::var("CARGO_MANIFEST_DIR").unwrap());
    let inference_dir = manifest_dir.parent().unwrap().join("inference");
    let out_dir = PathBuf::from(env::var("OUT_DIR").unwrap());
    let object_path = out_dir.join("local_agent_inference_mock.o");
    let library_path = out_dir.join("liblocal_agent_inference_mock.a");

    println!(
        "cargo:rerun-if-changed={}",
        inference_dir
            .join("include/local_agent_inference.h")
            .display()
    );
    println!(
        "cargo:rerun-if-changed={}",
        inference_dir
            .join("mock/local_agent_inference_mock.cpp")
            .display()
    );

    run(
        Command::new("clang++")
            .arg("-std=c++17")
            .arg("-I")
            .arg(inference_dir.join("include"))
            .arg("-c")
            .arg(inference_dir.join("mock/local_agent_inference_mock.cpp"))
            .arg("-o")
            .arg(&object_path),
    );
    run(
        Command::new("ar")
            .arg("crs")
            .arg(&library_path)
            .arg(&object_path),
    );

    println!("cargo:rustc-link-search=native={}", out_dir.display());
    println!("cargo:rustc-link-lib=static=local_agent_inference_mock");
    match env::var("CARGO_CFG_TARGET_OS").unwrap_or_default().as_str() {
        "ios" | "macos" => println!("cargo:rustc-link-lib=dylib=c++"),
        _ => println!("cargo:rustc-link-lib=dylib=stdc++"),
    }
}

fn run(command: &mut Command) {
    let status = command.status().unwrap_or_else(|error| {
        panic!("failed to run build command {command:?}: {error}");
    });
    if !status.success() {
        panic!("build command failed with {status}: {command:?}");
    }
}
