use std::env;
use std::path::{Path, PathBuf};
use std::process::Command;

fn main() {
    let manifest_dir = PathBuf::from(env::var("CARGO_MANIFEST_DIR").unwrap());
    // Layout repo: <root>/fasttree.nimble, <root>/src/..., <root>/include/fasttree.h,
    // <root>/fasttree-sys/Cargo.toml (ten plik) — więc korzeń projektu Nim to ".." stąd.
    let nim_root = manifest_dir.parent().expect("fasttree-sys powinno leżeć obok fasttree.nimble");
    let nim_src = nim_root.join("src");
    let include_dir = nim_root.join("include");
    let capi_entry = nim_src.join("fasttree").join("capi.nim");

    let out_dir = PathBuf::from(env::var("OUT_DIR").unwrap());
    let nimcache = out_dir.join("nimcache");

    println!("cargo:rerun-if-changed={}", nim_src.display());
    println!("cargo:rerun-if-changed={}", include_dir.join("fasttree.h").display());
    println!("cargo:rerun-if-env-changed=FASTTREE_NIM_BIN");

    let use_blake3 = env::var("CARGO_FEATURE_BLAKE3").is_ok();
    let profile = env::var("PROFILE").unwrap_or_else(|_| "debug".into());

    let nim_bin = env::var("FASTTREE_NIM_BIN").unwrap_or_else(|_| "nim".into());
    let lib_path = out_dir.join("libfasttree.a");

    let mut path_arg = std::ffi::OsString::from("--path:");
    path_arg.push(&nim_src);
    let mut nimcache_arg = std::ffi::OsString::from("--nimcache:");
    nimcache_arg.push(&nimcache);
    let mut out_arg = std::ffi::OsString::from("-o:");
    out_arg.push(&lib_path);

    let mut cmd = Command::new(&nim_bin);
    cmd.arg("c")
        .arg("--app:staticlib")
        .arg("--noMain")
        .arg("--hints:off")
        .arg(path_arg)
        .arg(nimcache_arg)
        .arg(out_arg);

    apply_cross_compilation_flags(&mut cmd);

    if !use_blake3 {
        cmd.arg("-d:fasttreeNoBlake3");
    }
    if profile == "release" {
        cmd.arg("-d:release");
    }
    cmd.arg(&capi_entry);

    eprintln!("[fasttree-sys/build.rs] uruchamiam: {:?}", cmd);
    let status = cmd
        .status()
        .unwrap_or_else(|e| panic!(
            "nie udało się uruchomić '{}': {e}. Zainstaluj kompilator Nim (https://nim-lang.org) \
             lub ustaw FASTTREE_NIM_BIN na jego ścieżkę.", nim_bin));
    if !status.success() {
        panic!("kompilacja Nim -> libfasttree.a nie powiodła się (kod {status})");
    }
    assert!(lib_path.exists(), "nim zwrócił sukces, ale {} nie istnieje", lib_path.display());

    println!("cargo:rustc-link-search=native={}", out_dir.display());
    println!("cargo:rustc-link-lib=static=fasttree");
    // Runtime Nim (nawet z --noMain) potrzebuje libm; na Linuksie zwykle
    // wystarcza libc+libm, które są linkowane domyślnie przez cc/ld, ale
    // dopinamy je jawnie, żeby build był odtwarzalny na różnych dystrybucjach.
    println!("cargo:rustc-link-lib=m");
    if use_blake3 {
        println!("cargo:rustc-link-search=native=/usr/local/lib");
        println!("cargo:rustc-link-lib=static=blake3");
    }

    generate_bindings_if_requested(&include_dir, &out_dir);
}

#[cfg(not(feature = "bindgen"))]
fn generate_bindings_if_requested(_include_dir: &Path, _out_dir: &Path) {
    // Domyślnie: bindingi są ręcznie napisane w src/lib.rs (zweryfikowane
    // ręcznie względem include/fasttree.h — patrz komentarz na górze tego pliku).
}

#[cfg(feature = "bindgen")]
fn generate_bindings_if_requested(include_dir: &Path, out_dir: &Path) {
    let header = include_dir.join("fasttree.h");
    println!("cargo:rerun-if-changed={}", header.display());
    let bindings = bindgen::Builder::default()
        .header(header.to_string_lossy())
        .allowlist_function("ft_.*")
        .allowlist_type("Ft.*")
        .generate()
        .expect("bindgen: generowanie bindingów z fasttree.h nie powiodło się");
    bindings
        .write_to_file(out_dir.join("bindgen_bindings.rs"))
        .expect("bindgen: zapis bindings.rs nie powiódł się");
    println!(
        "cargo:warning=wygenerowano bindgen_bindings.rs w {} — żeby ich użyć zamiast \
         ręcznych bindingów, podmień `mod raw` w src/lib.rs na include!()",
        out_dir.display()
    );
}

/// Cross-kompilacja: mapuje trójkę celu Cargo (`CARGO_CFG_TARGET_ARCH`/
/// `CARGO_CFG_TARGET_OS`, zawsze ustawione przez cargo w build scriptach)
/// na `--cpu`/`--os` Nim. Jeśli TARGET != HOST, dodaje też cross-toolchain
/// C (domyślnie zgaduje `<target-triple>-gcc`, nadpisywalne przez
/// `FASTTREE_NIM_CROSS_CC`).
///
/// UCZCIWA UWAGA: to jest mechanizm, nie magiczne zero-config rozwiązanie.
/// Zweryfikowane ręcznie działa dla: cross Linux x86_64 -> Linux aarch64
/// (przez `apt install gcc-aarch64-linux-gnu`; sprawdzone `file`/`objdump`,
/// że wynikowy .o to faktycznie `ELF 64-bit LSB relocatable, ARM aarch64`).
/// Dla innych par (macOS, Windows/MinGW, Android) mapowanie architektury/OS
/// jest napisane wg dokumentacji Nim (`nim --help` -> `--cpu`/`--os`), ale
/// wymaga własnego cross-toolchaina C dla tej pary, którego nie dało się
/// zweryfikować bez tego celu zainstalowanego w środowisku, w którym to
/// pisano — jeśli budowa się nie powiedzie, ustaw `FASTTREE_NIM_CROSS_CC`
/// na właściwy kompilator C dla Twojego celu.
fn apply_cross_compilation_flags(cmd: &mut Command) {
    let host = env::var("HOST").unwrap_or_default();
    let target = env::var("TARGET").unwrap_or_default();
    if host == target || target.is_empty() {
        return; // budowa natywna — nic do zrobienia
    }

    let arch = env::var("CARGO_CFG_TARGET_ARCH").unwrap_or_default();
    let os = env::var("CARGO_CFG_TARGET_OS").unwrap_or_default();

    let nim_cpu = match arch.as_str() {
        "x86_64" => "amd64",
        "aarch64" => "arm64",
        "arm" => "arm",
        "x86" => "i386",
        "riscv64" => "riscv64",
        "powerpc64" => "powerpc64",
        other => {
            println!("cargo:warning=fasttree-sys: nieznana architektura '{other}' dla cross-compilation, \
                       pomijam mapowanie --cpu (może się nie udać)");
            ""
        }
    };
    let nim_os = match os.as_str() {
        "linux" => "linux",
        "macos" => "macosx",
        "windows" => "windows",
        "android" => "android",
        "ios" => "ios",
        other => {
            println!("cargo:warning=fasttree-sys: nieznany OS '{other}' dla cross-compilation, \
                       pomijam mapowanie --os (może się nie udać)");
            ""
        }
    };

    if !nim_cpu.is_empty() {
        cmd.arg(format!("--cpu:{nim_cpu}"));
    }
    if !nim_os.is_empty() {
        cmd.arg(format!("--os:{nim_os}"));
    }

    // Cross-toolchain C: Nim i tak generuje C, więc potrzebuje kompilatora C
    // dla CELU, nie hosta. Zgadujemy typowy prefiks Debian/Ubuntu
    // (`<target-triple>-gcc`, np. `aarch64-linux-gnu-gcc` — dokładnie ten
    // użyty przy weryfikacji tego mechanizmu), z możliwością nadpisania.
    let cross_cc = env::var("FASTTREE_NIM_CROSS_CC").unwrap_or_else(|_| format!("{target}-gcc"));
    println!("cargo:rerun-if-env-changed=FASTTREE_NIM_CROSS_CC");
    if which(&cross_cc) {
        cmd.arg(format!("--gcc.exe:{cross_cc}"));
        cmd.arg(format!("--gcc.linkerexe:{cross_cc}"));
    } else {
        println!("cargo:warning=fasttree-sys: cross-kompilator '{cross_cc}' nie znaleziony w PATH — \
                   zainstaluj go (np. `apt install gcc-aarch64-linux-gnu` dla Debiana/Ubuntu, \
                   dostosuj nazwę pakietu do architektury docelowej) albo ustaw \
                   FASTTREE_NIM_CROSS_CC na właściwą ścieżkę.");
    }
}

fn which(bin: &str) -> bool {
    if let Ok(path) = env::var("PATH") {
        for dir in env::split_paths(&path) {
            if dir.join(bin).is_file() {
                return true;
            }
        }
    }
    false
}
