use std::env;
use std::fs;
use std::path::Path;
use std::path::PathBuf;
use std::process::Command;

fn main() {
    println!("cargo:rerun-if-env-changed=CARGO_FEATURE_LINK_MOCK_LOCAL_INFERENCE");
    println!("cargo:rerun-if-env-changed=CARGO_FEATURE_LINK_LLAMA_CPP_LOCAL_INFERENCE");
    println!("cargo:rerun-if-env-changed=CARGO_FEATURE_LINK_LLAMA_CPP_MTMD_LOCAL_INFERENCE");
    println!("cargo:rerun-if-env-changed=LLAMA_CPP_HEADERS");
    println!("cargo:rerun-if-env-changed=LLAMA_CPP_XCFRAMEWORK");
    println!("cargo:rerun-if-env-changed=LLAMA_CPP_LIBRARY");
    println!("cargo:rerun-if-env-changed=LLAMA_CPP_MTMD_HEADERS");
    println!("cargo:rerun-if-env-changed=LLAMA_CPP_MTMD_LIBRARY");
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
        "backends/llama_cpp/llama_cpp_api.cpp",
        "backends/llama_cpp/llama_cpp_engine.cpp",
        "backends/llama_cpp/llama_cpp_prompt.cpp",
    ];
    let link_llama_cpp = env::var_os("CARGO_FEATURE_LINK_LLAMA_CPP_LOCAL_INFERENCE").is_some();
    let link_llama_cpp_mtmd =
        env::var_os("CARGO_FEATURE_LINK_LLAMA_CPP_MTMD_LOCAL_INFERENCE").is_some();

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
            .arg("-I")
            .arg(inference_dir.join("backends/llama_cpp"));
        if link_llama_cpp {
            compile.arg("-DLOCAL_AGENT_ENABLE_LLAMA_CPP");
            compile.arg("-I").arg(required_path("LLAMA_CPP_HEADERS"));
        }
        if link_llama_cpp_mtmd {
            compile.arg("-DLOCAL_AGENT_ENABLE_LLAMA_CPP_MTMD");
            compile
                .arg("-I")
                .arg(required_path("LLAMA_CPP_MTMD_HEADERS"));
        }
        compile
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
    if link_llama_cpp {
        link_llama_cpp_artifact();
    }
    if link_llama_cpp_mtmd {
        link_library_path(&required_path("LLAMA_CPP_MTMD_LIBRARY"));
    }
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

fn required_path(name: &str) -> PathBuf {
    env::var_os(name)
        .map(PathBuf::from)
        .unwrap_or_else(|| panic!("{name} must be set for the selected local inference feature"))
}

fn link_llama_cpp_artifact() {
    if let Some(library) = env::var_os("LLAMA_CPP_LIBRARY").map(PathBuf::from) {
        link_library_path(&library);
        return;
    }

    let xcframework = required_path("LLAMA_CPP_XCFRAMEWORK");
    let library = find_xcframework_library(&xcframework).unwrap_or_else(|| {
        panic!(
            "could not find llama library inside {}",
            xcframework.display()
        )
    });
    link_library_path(&library);
}

fn find_xcframework_library(root: &Path) -> Option<PathBuf> {
    let target = env::var("TARGET").unwrap_or_default();
    let wanted_slice = if target.contains("apple-ios-sim") {
        "simulator"
    } else if target.contains("apple-ios") {
        "ios-arm64"
    } else if target.contains("apple-darwin") {
        "macos"
    } else {
        ""
    };

    let mut candidates = Vec::new();
    collect_libraries(root, &mut candidates);
    candidates
        .iter()
        .find(|path| path.to_string_lossy().contains(wanted_slice))
        .cloned()
        .or_else(|| candidates.into_iter().next())
}

fn collect_libraries(path: &Path, candidates: &mut Vec<PathBuf>) {
    let Ok(entries) = fs::read_dir(path) else {
        return;
    };
    for entry in entries.flatten() {
        let path = entry.path();
        if path.is_dir() {
            collect_libraries(&path, candidates);
        } else if path.file_name().and_then(|name| name.to_str()) == Some("libllama.a")
            || path.ends_with("llama.framework/llama")
        {
            candidates.push(path);
        }
    }
}

fn link_library_path(path: &Path) {
    if path.file_name().and_then(|name| name.to_str()) == Some("llama") {
        let framework_dir = path
            .parent()
            .and_then(Path::parent)
            .unwrap_or_else(|| panic!("invalid framework binary path: {}", path.display()));
        println!(
            "cargo:rustc-link-search=framework={}",
            framework_dir.display()
        );
        println!("cargo:rustc-link-lib=framework=llama");
        return;
    }

    let parent = path
        .parent()
        .unwrap_or_else(|| panic!("library path has no parent: {}", path.display()));
    let stem = path
        .file_stem()
        .and_then(|stem| stem.to_str())
        .unwrap_or_else(|| panic!("library path has no stem: {}", path.display()))
        .trim_start_matches("lib")
        .to_string();
    println!("cargo:rustc-link-search=native={}", parent.display());
    println!("cargo:rustc-link-lib=static={stem}");
}

fn run(command: &mut Command) {
    let status = command.status().unwrap_or_else(|error| {
        panic!("failed to run build command {command:?}: {error}");
    });
    if !status.success() {
        panic!("build command failed with {status}: {command:?}");
    }
}
