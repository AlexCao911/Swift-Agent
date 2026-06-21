use std::env;
use std::path::PathBuf;
use std::process::Command;

fn main() {
    println!("cargo:rerun-if-env-changed=CARGO_FEATURE_LINK_MOCK_LOCAL_INFERENCE");
    println!("cargo:rerun-if-env-changed=DEVELOPER_DIR");
    if env::var_os("CARGO_FEATURE_LINK_MOCK_LOCAL_INFERENCE").is_none() {
        return;
    }

    let manifest_dir = PathBuf::from(env::var("CARGO_MANIFEST_DIR").unwrap());
    let inference_dir = manifest_dir.parent().unwrap().join("inference");
    let out_dir = PathBuf::from(env::var("OUT_DIR").unwrap());
    let library_path = out_dir.join("liblocal_agent_inference_mock.a");
    let sources = [
        "c_api/local_agent_inference.cpp",
        "core/model_config.cpp",
        "core/token_stream.cpp",
        "backends/mock/mock_inference_engine.cpp",
    ];

    println!(
        "cargo:rerun-if-changed={}",
        inference_dir
            .join("include/local_agent_inference.h")
            .display()
    );
    for source in sources {
        println!(
            "cargo:rerun-if-changed={}",
            inference_dir.join(source).display()
        );
    }

    let cxx = cxx_invocation();
    let mut object_paths = Vec::new();
    for (index, source) in sources.iter().enumerate() {
        let object_path = out_dir.join(format!("local_agent_inference_mock_{index}.o"));
        let mut compile = Command::new(&cxx.compiler);
        compile.args(&cxx.args);
        compile
            .arg("-std=c++17")
            .arg("-I")
            .arg(inference_dir.join("include"))
            .arg("-I")
            .arg(inference_dir.join("core"))
            .arg("-I")
            .arg(inference_dir.join("backends/mock"))
            .arg("-c")
            .arg(inference_dir.join(source))
            .arg("-o")
            .arg(&object_path);
        run(&mut compile);
        object_paths.push(object_path);
    }

    let mut archive = Command::new("ar");
    archive.arg("crs").arg(&library_path);
    for object_path in &object_paths {
        archive.arg(object_path);
    }
    run(&mut archive);

    println!("cargo:rustc-link-search=native={}", out_dir.display());
    println!("cargo:rustc-link-lib=static=local_agent_inference_mock");
    match env::var("CARGO_CFG_TARGET_OS").unwrap_or_default().as_str() {
        "ios" | "macos" => println!("cargo:rustc-link-lib=dylib=c++"),
        _ => println!("cargo:rustc-link-lib=dylib=stdc++"),
    }
}

struct CxxInvocation {
    compiler: PathBuf,
    args: Vec<String>,
}

fn cxx_invocation() -> CxxInvocation {
    match env::var("TARGET").unwrap_or_default().as_str() {
        "aarch64-apple-ios-sim" => apple_cxx(
            "iphonesimulator",
            "arm64-apple-ios-simulator",
            "-mios-simulator-version-min=17.0",
        ),
        "x86_64-apple-ios" => apple_cxx(
            "iphonesimulator",
            "x86_64-apple-ios-simulator",
            "-mios-simulator-version-min=17.0",
        ),
        "aarch64-apple-ios" => {
            apple_cxx("iphoneos", "arm64-apple-ios", "-miphoneos-version-min=17.0")
        }
        "aarch64-apple-darwin" => apple_cxx(
            "macosx",
            "arm64-apple-macos14.0",
            "-mmacosx-version-min=14.0",
        ),
        "x86_64-apple-darwin" => apple_cxx(
            "macosx",
            "x86_64-apple-macos14.0",
            "-mmacosx-version-min=14.0",
        ),
        _ => CxxInvocation {
            compiler: PathBuf::from("clang++"),
            args: Vec::new(),
        },
    }
}

fn apple_cxx(sdk: &str, clang_target: &str, min_version_arg: &str) -> CxxInvocation {
    let compiler = command_stdout(
        Command::new("xcrun")
            .arg("--sdk")
            .arg(sdk)
            .arg("--find")
            .arg("clang++"),
    );
    let sdk_path = command_stdout(
        Command::new("xcrun")
            .arg("--sdk")
            .arg(sdk)
            .arg("--show-sdk-path"),
    );

    CxxInvocation {
        compiler: PathBuf::from(compiler),
        args: vec![
            "-target".into(),
            clang_target.into(),
            "-isysroot".into(),
            sdk_path,
            min_version_arg.into(),
        ],
    }
}

fn command_stdout(command: &mut Command) -> String {
    let output = command.output().unwrap_or_else(|error| {
        panic!("failed to run build command {command:?}: {error}");
    });
    if !output.status.success() {
        panic!("build command failed with {}: {command:?}", output.status);
    }

    String::from_utf8(output.stdout)
        .expect("build command output should be UTF-8")
        .trim()
        .to_string()
}

fn run(command: &mut Command) {
    let status = command.status().unwrap_or_else(|error| {
        panic!("failed to run build command {command:?}: {error}");
    });
    if !status.success() {
        panic!("build command failed with {status}: {command:?}");
    }
}
