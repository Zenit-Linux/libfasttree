use fasttree_sys as sys;
use std::ffi::{CStr, CString};
use std::os::raw::c_char;
use std::path::Path;
use std::sync::Once;

static RUNTIME_INIT: Once = Once::new();

/// Inicjalizuje runtime Nim (GC itp.). Wołane automatycznie i idempotentnie
/// (`std::sync::Once`) na początku każdej funkcji publicznej tego crate'a —
/// nie musisz wołać tego ręcznie, ale jest publiczne na wypadek, gdybyś
/// chciał zainicjalizować wcześnie (np. na starcie procesu, przed pierwszym
/// realnym wywołaniem, żeby uniknąć narzutu inicjalizacji na ścieżce "hot").
pub fn ensure_runtime_init() {
    RUNTIME_INIT.call_once(|| unsafe { sys::NimMain() });
}

/// Błędy zwracane przez FastTree. Owinięty komunikat pochodzi z
/// `ft_last_error()` po stronie Nim (patrz capi.nim — per-wątek, ważny do
/// następnego wywołania, dlatego kopiujemy go do `String` od razu tutaj).
#[derive(thiserror::Error, Debug)]
pub enum FastTreeError {
    #[error("nieprawidłowy argument: {0}")]
    InvalidArgument(String),
    #[error("błąd We/Wy: {0}")]
    Io(String),
    #[error("obiekt nie znaleziony: {0}")]
    NotFound(String),
    #[error("niezgodność formatu (manifest/store): {0}")]
    Format(String),
    #[error("błąd wewnętrzny FastTree: {0}")]
    Internal(String),
    #[error("nieprawidłowy hash hex: {0}")]
    InvalidHash(String),
    #[error("ścieżka zawiera bajt NUL, niekompatybilne z C-string: {0}")]
    NulInPath(String),
}

fn last_error_string() -> String {
    unsafe {
        let ptr = sys::ft_last_error();
        if ptr.is_null() {
            "(brak dodatkowego komunikatu)".to_string()
        } else {
            CStr::from_ptr(ptr).to_string_lossy().into_owned()
        }
    }
}

fn status_to_result(raw: i32) -> Result<(), FastTreeError> {
    match sys::FtStatus::from_raw(raw) {
        sys::FtStatus::Ok => Ok(()),
        sys::FtStatus::ErrInvalidArgument => Err(FastTreeError::InvalidArgument(last_error_string())),
        sys::FtStatus::ErrIo => Err(FastTreeError::Io(last_error_string())),
        sys::FtStatus::ErrNotFound => Err(FastTreeError::NotFound(last_error_string())),
        sys::FtStatus::ErrFormat => Err(FastTreeError::Format(last_error_string())),
        sys::FtStatus::ErrInternal => Err(FastTreeError::Internal(last_error_string())),
    }
}

fn path_to_cstring(p: &Path) -> Result<CString, FastTreeError> {
    CString::new(p.to_string_lossy().as_bytes())
        .map_err(|_| FastTreeError::NulInPath(p.display().to_string()))
}

/// Kopiuje `owned` C-string (allocShared po stronie Nim) do Rust `String`
/// i zwalnia go przez `ft_string_free` — od tego momentu wołający po stronie
/// Rust nie musi (i nie powinien) o nim więcej pamiętać.
unsafe fn take_owned_cstring(ptr: *mut c_char) -> String {
    debug_assert!(!ptr.is_null(), "owned cstring nie powinien być NULL po statusie Ok");
    let s = CStr::from_ptr(ptr).to_string_lossy().into_owned();
    sys::ft_string_free(ptr);
    s
}

/// Content-addressable store: zapisuje/odczytuje bloki po ich hashu.
/// Odpowiednik `store.Store` z biblioteki Nim, przez granicę FFI.
pub struct Store {
    handle: *mut sys::FtStoreHandle,
}

// Uchwyt to surowy wskaźnik na strukturę żyjącą na stercie Nim, bez
// wewnętrznej synchronizacji — świadomie NIE implementujemy Send/Sync.
// Współdzielenie Store między wątkami wymaga zewnętrznego Mutex<Store>
// (albo osobnego Store per wątek, wskazującego na ten sam katalog na dysku —
// CAS na dysku jest bezpieczny do współdzielenia, sam uchwyt w pamięci nie).

impl Store {
    /// Otwiera (lub inicjalizuje, jeśli pusty) CAS pod `root`.
    pub fn open(root: impl AsRef<Path>) -> Result<Self, FastTreeError> {
        ensure_runtime_init();
        let c_root = path_to_cstring(root.as_ref())?;
        let mut handle: *mut sys::FtStoreHandle = std::ptr::null_mut();
        let raw = unsafe { sys::ft_store_open(c_root.as_ptr(), &mut handle) };
        status_to_result(raw)?;
        Ok(Store { handle })
    }

    /// Sprawdza obecność obiektu. `hash_hex` musi być 64-znakowym hexem
    /// (zwraca `false`, nie błąd, dla niepoprawnego formatu — patrz capi.nim).
    pub fn has(&self, hash_hex: &str) -> bool {
        let Ok(c_hash) = CString::new(hash_hex) else { return false };
        unsafe { sys::ft_store_has(self.handle, c_hash.as_ptr()) != 0 }
    }

    /// Zapisuje blok danych, zwraca jego hash jako lowercase hex.
    pub fn put(&self, data: &[u8]) -> Result<String, FastTreeError> {
        let mut out_hash: *mut c_char = std::ptr::null_mut();
        let raw = unsafe {
            sys::ft_store_put(
                self.handle,
                if data.is_empty() { std::ptr::null() } else { data.as_ptr() },
                data.len(),
                &mut out_hash,
            )
        };
        status_to_result(raw)?;
        Ok(unsafe { take_owned_cstring(out_hash) })
    }

    /// Odczytuje blok po jego hex-hashu. Zwraca `FastTreeError::NotFound`,
    /// jeśli obiekt nie istnieje w store.
    pub fn get(&self, hash_hex: &str) -> Result<Vec<u8>, FastTreeError> {
        let c_hash = CString::new(hash_hex)
            .map_err(|_| FastTreeError::InvalidHash(hash_hex.to_string()))?;
        let mut out_data: *mut u8 = std::ptr::null_mut();
        let mut out_len: usize = 0;
        let raw = unsafe { sys::ft_store_get(self.handle, c_hash.as_ptr(), &mut out_data, &mut out_len) };
        status_to_result(raw)?;
        let result = unsafe { std::slice::from_raw_parts(out_data, out_len).to_vec() };
        unsafe { sys::ft_bytes_free(out_data) };
        Ok(result)
    }
}

impl Drop for Store {
    fn drop(&mut self) {
        if !self.handle.is_null() {
            unsafe { sys::ft_store_close(self.handle) };
            self.handle = std::ptr::null_mut();
        }
    }
}

/// Manifest — drzewo Merkle całego rootfs (patrz `manifest.nim` w bibliotece
/// Nim). Niemutowalny z perspektywy Rust: budujesz go raz (`build`/`from_json`)
/// i tylko odczytujesz.
pub struct Manifest {
    handle: *mut sys::FtManifestHandle,
}

impl Manifest {
    /// Buduje manifest z katalogu źródłowego, chunkując pliki (FastCDC)
    /// i zapisując chunki do podanego `store`.
    pub fn build(source_dir: impl AsRef<Path>, store: &Store) -> Result<Self, FastTreeError> {
        ensure_runtime_init();
        let c_dir = path_to_cstring(source_dir.as_ref())?;
        let mut handle: *mut sys::FtManifestHandle = std::ptr::null_mut();
        let raw = unsafe { sys::ft_manifest_build(c_dir.as_ptr(), store.handle, &mut handle) };
        status_to_result(raw)?;
        Ok(Manifest { handle })
    }

    /// Pełny `pull`: pobiera/cache'uje warstwy OCI z `image_ref` (np.
    /// `"ghcr.io/org/repo:tag"`) do `cache_dir`, scala je (whiteout/opaque
    /// whiteout) w `work_dir`, buduje manifest zapisując chunki do `store`.
    /// Odpowiednik `cli.cmdPull` po stronie Nim, wywoływalny bezpośrednio
    /// z Rust bez przechodzenia przez binarkę `fasttree`.
    pub fn pull(
        image_ref: &str,
        cache_dir: impl AsRef<Path>,
        work_dir: impl AsRef<Path>,
        store: &Store,
    ) -> Result<Self, FastTreeError> {
        ensure_runtime_init();
        let c_ref = CString::new(image_ref)
            .map_err(|_| FastTreeError::InvalidArgument("image_ref zawiera bajt NUL".into()))?;
        let c_cache = path_to_cstring(cache_dir.as_ref())?;
        let c_work = path_to_cstring(work_dir.as_ref())?;
        let mut handle: *mut sys::FtManifestHandle = std::ptr::null_mut();
        let raw = unsafe {
            sys::ft_pull_run(c_ref.as_ptr(), c_cache.as_ptr(), c_work.as_ptr(), store.handle, &mut handle)
        };
        status_to_result(raw)?;
        Ok(Manifest { handle })
    }

    /// Odtwarza manifest z JSON (patrz format opisany w README głównego repo —
    /// `formatVersion`/`hashAlgo`/`chunker`/`root`/`entries`).
    pub fn from_json(json: &str) -> Result<Self, FastTreeError> {
        ensure_runtime_init();
        let c_json = CString::new(json)
            .map_err(|_| FastTreeError::InvalidArgument("json zawiera bajt NUL".into()))?;
        let mut handle: *mut sys::FtManifestHandle = std::ptr::null_mut();
        let raw = unsafe { sys::ft_manifest_from_json(c_json.as_ptr(), &mut handle) };
        status_to_result(raw)?;
        Ok(Manifest { handle })
    }

    /// Serializuje z powrotem do JSON (pretty-printed, jak `manifest.toJson`
    /// po stronie Nim).
    pub fn to_json(&self) -> Result<String, FastTreeError> {
        let mut out_json: *mut c_char = std::ptr::null_mut();
        let raw = unsafe { sys::ft_manifest_to_json(self.handle, &mut out_json) };
        status_to_result(raw)?;
        Ok(unsafe { take_owned_cstring(out_json) })
    }

    /// Root-hash drzewa Merkle (hex) — najtańszy sposób na porównanie dwóch
    /// wersji: identyczna zawartość = identyczny root, bez chodzenia po drzewie.
    pub fn root_hex(&self) -> Result<String, FastTreeError> {
        let mut out_hash: *mut c_char = std::ptr::null_mut();
        let raw = unsafe { sys::ft_manifest_root_hex(self.handle, &mut out_hash) };
        status_to_result(raw)?;
        Ok(unsafe { take_owned_cstring(out_hash) })
    }

    pub fn entry_count(&self) -> usize {
        unsafe { sys::ft_manifest_entry_count(self.handle) }
    }

    /// `FastTreeFormatVersion`, z którym ten konkretny manifest został
    /// zbudowany/wczytany (patrz manifest.nim — reguła kompatybilności wstecz).
    pub fn format_version(&self) -> i32 {
        unsafe { sys::ft_manifest_format_version(self.handle) }
    }

    /// Materializuje manifest do drzewa plików, buduje obraz composefs i
    /// liczy jego hash-tree dm-verity. Odpowiednik kroku budowy obrazu
    /// w `cli.cmdDeploy` — atomowy A/B swap symlinka `current` zostaje po
    /// stronie wołającego (zależy od układu katalogów instalacji).
    pub fn deploy_image(
        &self,
        store: &Store,
        materialized_dir: impl AsRef<Path>,
        output_image: impl AsRef<Path>,
    ) -> Result<DeployResult, FastTreeError> {
        let c_mat = path_to_cstring(materialized_dir.as_ref())?;
        let c_out = path_to_cstring(output_image.as_ref())?;
        let mut raw = sys::FtDeployResult { image_digest: std::ptr::null_mut(), verity_root_hash: std::ptr::null_mut() };
        let raw_status = unsafe {
            sys::ft_deploy_build_image(self.handle, store.handle, c_mat.as_ptr(), c_out.as_ptr(), &mut raw)
        };
        let result = status_to_result(raw_status).map(|_| DeployResult {
            image_digest: unsafe { CStr::from_ptr(raw.image_digest).to_string_lossy().into_owned() },
            verity_root_hash: unsafe { CStr::from_ptr(raw.verity_root_hash).to_string_lossy().into_owned() },
        });
        unsafe { sys::ft_deploy_result_free(&mut raw) };
        result
    }
}

/// Wynik `Manifest::deploy_image` — patrz `composefs.buildImage` +
/// `composefs.dmVerityFormat` po stronie Nim.
#[derive(Debug, Clone)]
pub struct DeployResult {
    pub image_digest: String,
    pub verity_root_hash: String,
}

impl Drop for Manifest {
    fn drop(&mut self) {
        if !self.handle.is_null() {
            unsafe { sys::ft_manifest_close(self.handle) };
            self.handle = std::ptr::null_mut();
        }
    }
}

/// Wynik `gc_run` — patrz `gc.nim` po stronie Nim.
#[derive(Debug, Clone, Copy)]
pub struct GcResult {
    pub scanned_objects: usize,
    pub live_objects: usize,
    pub deleted_objects: usize,
    pub freed_bytes: u64,
}

impl From<sys::FtGcResult> for GcResult {
    fn from(r: sys::FtGcResult) -> Self {
        GcResult {
            scanned_objects: r.scanned_objects,
            live_objects: r.live_objects,
            deleted_objects: r.deleted_objects,
            freed_bytes: r.freed_bytes,
        }
    }
}

/// Uruchamia GC na drzewie stanu FastTree pod `ft_root` (odpowiednik
/// `$FASTTREE_ROOT` z CLI: zawiera `store/`, `manifests/`, `CURRENT_TAG`,
/// `pins.json`). `dry_run=true` liczy statystyki bez usuwania.
pub fn gc_run(ft_root: impl AsRef<Path>, dry_run: bool) -> Result<GcResult, FastTreeError> {
    ensure_runtime_init();
    let c_root = path_to_cstring(ft_root.as_ref())?;
    let mut raw_result = sys::FtGcResult { scanned_objects: 0, live_objects: 0, deleted_objects: 0, freed_bytes: 0 };
    let raw = unsafe { sys::ft_gc_run(c_root.as_ptr(), if dry_run { 1 } else { 0 }, &mut raw_result) };
    status_to_result(raw)?;
    Ok(raw_result.into())
}

/// `FastTreeFormatVersion` obsługiwany przez zlinkowaną bibliotekę.
pub fn format_version() -> i32 {
    ensure_runtime_init();
    unsafe { sys::ft_format_version() }
}

/// `"blake3"` lub `"sha256-fallback"`, zależnie od tego, z czym zbudowano
/// `libfasttree` (patrz feature `blake3` w `fasttree-sys/Cargo.toml`).
pub fn hash_algo() -> &'static str {
    ensure_runtime_init();
    unsafe {
        let ptr = sys::ft_hash_algo();
        CStr::from_ptr(ptr).to_str().unwrap_or("(nieprawidłowy utf8)")
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use tempfile::tempdir;

    #[test]
    fn store_put_get_roundtrip() {
        let dir = tempdir().unwrap();
        let store = Store::open(dir.path()).unwrap();
        let hash = store.put(b"dane testowe z bezpiecznego wrappera").unwrap();
        assert!(store.has(&hash));
        let data = store.get(&hash).unwrap();
        assert_eq!(data, b"dane testowe z bezpiecznego wrappera");
    }

    #[test]
    fn store_get_missing_returns_not_found() {
        let dir = tempdir().unwrap();
        let store = Store::open(dir.path()).unwrap();
        let err = store.get(&"0".repeat(64)).unwrap_err();
        assert!(matches!(err, FastTreeError::NotFound(_)), "oczekiwano NotFound, dostałem {err:?}");
    }

    #[test]
    fn store_get_bad_hash_returns_invalid_argument() {
        let dir = tempdir().unwrap();
        let store = Store::open(dir.path()).unwrap();
        let err = store.get("za-krotki-hash").unwrap_err();
        assert!(matches!(err, FastTreeError::InvalidArgument(_)), "oczekiwano InvalidArgument, dostałem {err:?}");
    }

    #[test]
    fn manifest_build_and_json_roundtrip() {
        let store_dir = tempdir().unwrap();
        let src_dir = tempdir().unwrap();
        std::fs::write(src_dir.path().join("a.txt"), b"zawartosc A").unwrap();
        std::fs::create_dir(src_dir.path().join("sub")).unwrap();
        std::fs::write(src_dir.path().join("sub").join("b.txt"), b"zawartosc B, troche dluzsza").unwrap();

        let store = Store::open(store_dir.path()).unwrap();
        let manifest = Manifest::build(src_dir.path(), &store).unwrap();
        assert_eq!(manifest.entry_count(), 3); // a.txt, sub/, sub/b.txt
        assert_eq!(manifest.format_version(), format_version());

        let json = manifest.to_json().unwrap();
        let reloaded = Manifest::from_json(&json).unwrap();
        assert_eq!(reloaded.root_hex().unwrap(), manifest.root_hex().unwrap());
    }

    #[test]
    fn gc_dry_run_on_empty_root_does_not_error() {
        let root = tempdir().unwrap();
        std::fs::create_dir_all(root.path().join("store")).unwrap();
        std::fs::create_dir_all(root.path().join("manifests")).unwrap();
        let res = gc_run(root.path(), true).unwrap();
        assert_eq!(res.scanned_objects, 0);
        assert_eq!(res.deleted_objects, 0);
    }

    #[test]
    fn reports_hash_algo_and_format_version() {
        // Zbudowane domyślnie (bez feature "blake3") -> fallback SHA-256.
        assert_eq!(hash_algo(), "sha256-fallback");
        assert!(format_version() >= 1);
    }
}
