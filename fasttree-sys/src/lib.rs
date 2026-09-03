#![allow(non_camel_case_types)]

use std::os::raw::{c_char, c_int};

/// Odpowiednik `FtStatus` z fasttree.h. `#[repr(i32)]`, bo Nim eksportuje
/// enum jako `NI32` (patrz `{.size: sizeof(cint).}` w capi.nim).
#[repr(i32)]
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum FtStatus {
    Ok = 0,
    ErrInvalidArgument = 1,
    ErrIo = 2,
    ErrNotFound = 3,
    ErrFormat = 4,
    ErrInternal = 5,
}

impl FtStatus {
    /// Konwersja z surowego `c_int` zwróconego przez FFI. `unreachable!` na
    /// nieznanej wartości jest świadomy: capi.nim gwarantuje zamknięty zbiór
    /// wartości (enum po stronie Nim), więc cokolwiek innego to bug w ABI,
    /// nie sytuacja, którą wołający powinien "obsłużyć".
    pub fn from_raw(v: c_int) -> Self {
        match v {
            0 => FtStatus::Ok,
            1 => FtStatus::ErrInvalidArgument,
            2 => FtStatus::ErrIo,
            3 => FtStatus::ErrNotFound,
            4 => FtStatus::ErrFormat,
            5 => FtStatus::ErrInternal,
            other => unreachable!("nieznany FtStatus={other} — rozjazd ABI Rust<->Nim"),
        }
    }
}

/// Nieprzezroczysty uchwyt store'a. Nigdy nie dereferencjonuj — tylko
/// przekazuj wskaźnik tam i z powrotem do funkcji `ft_store_*`.
#[repr(C)]
pub struct FtStoreHandle {
    _private: [u8; 0],
}

/// Nieprzezroczysty uchwyt manifestu.
#[repr(C)]
pub struct FtManifestHandle {
    _private: [u8; 0],
}

#[repr(C)]
#[derive(Debug, Clone, Copy)]
pub struct FtGcResult {
    pub scanned_objects: usize,
    pub live_objects: usize,
    pub deleted_objects: usize,
    pub freed_bytes: u64,
}

#[repr(C)]
pub struct FtDeployResult {
    pub image_digest: *mut c_char,     // owned, wolne przez ft_deploy_result_free
    pub verity_root_hash: *mut c_char, // owned, wolne przez ft_deploy_result_free
}

extern "C" {
    /// Inicjalizacja runtime'u Nim (GC, itp.). MUSI zostać wywołana dokładnie
    /// raz, przed jakimkolwiek innym wywołaniem `ft_*` — biblioteka zbudowana
    /// jest z `--noMain`, więc to wołający (my) jest odpowiedzialny za start.
    /// `fasttree-rs` (bezpieczny wrapper) robi to automatycznie przez
    /// `std::sync::Once` — patrz `fasttree::ensure_runtime_init`.
    pub fn NimMain();

    pub fn ft_last_error() -> *const c_char;

    pub fn ft_string_free(s: *mut c_char);
    pub fn ft_bytes_free(p: *mut u8);

    pub fn ft_store_open(root: *const c_char, out_handle: *mut *mut FtStoreHandle) -> c_int;
    pub fn ft_store_close(handle: *mut FtStoreHandle);
    pub fn ft_store_has(handle: *mut FtStoreHandle, hash_hex: *const c_char) -> c_int;
    pub fn ft_store_put(
        handle: *mut FtStoreHandle,
        data: *const u8,
        data_len: usize,
        out_hash_hex: *mut *mut c_char,
    ) -> c_int;
    pub fn ft_store_get(
        handle: *mut FtStoreHandle,
        hash_hex: *const c_char,
        out_data: *mut *mut u8,
        out_len: *mut usize,
    ) -> c_int;

    pub fn ft_manifest_build(
        source_dir: *const c_char,
        store_handle: *mut FtStoreHandle,
        out_handle: *mut *mut FtManifestHandle,
    ) -> c_int;
    pub fn ft_manifest_from_json(json: *const c_char, out_handle: *mut *mut FtManifestHandle) -> c_int;
    pub fn ft_manifest_to_json(handle: *mut FtManifestHandle, out_json: *mut *mut c_char) -> c_int;
    pub fn ft_manifest_root_hex(handle: *mut FtManifestHandle, out_hash_hex: *mut *mut c_char) -> c_int;
    pub fn ft_manifest_entry_count(handle: *mut FtManifestHandle) -> usize;
    pub fn ft_manifest_format_version(handle: *mut FtManifestHandle) -> c_int;
    pub fn ft_manifest_close(handle: *mut FtManifestHandle);

    pub fn ft_gc_run(ft_root: *const c_char, dry_run: c_int, out_result: *mut FtGcResult) -> c_int;

    pub fn ft_pull_run(
        image_ref: *const c_char,
        cache_dir: *const c_char,
        work_dir: *const c_char,
        store_handle: *mut FtStoreHandle,
        out_handle: *mut *mut FtManifestHandle,
    ) -> c_int;

    pub fn ft_deploy_build_image(
        manifest_handle: *mut FtManifestHandle,
        store_handle: *mut FtStoreHandle,
        materialized_dir: *const c_char,
        output_image: *const c_char,
        out_result: *mut FtDeployResult,
    ) -> c_int;
    pub fn ft_deploy_result_free(r: *mut FtDeployResult);

    pub fn ft_format_version() -> c_int;
    pub fn ft_hash_algo() -> *const c_char;
}

#[cfg(test)]
mod tests {
    //! Testy tego crate'a celowo wołają surowe FFI wprost (nie przez
    //! `fasttree-rs`), żeby zweryfikować bindingi niezależnie od wygody
    //! wrappera. `fasttree-rs/tests` sprawdza to samo z drugiej strony.
    use super::*;
    use std::ffi::{CStr, CString};
    use std::sync::Once;

    static INIT: Once = Once::new();
    fn init() {
        INIT.call_once(|| unsafe { NimMain() });
    }

    #[test]
    fn open_store_put_get_roundtrip() {
        init();
        let dir = std::env::temp_dir().join(format!("fasttree-sys-test-{}", std::process::id()));
        std::fs::create_dir_all(&dir).unwrap();
        let root = CString::new(dir.to_str().unwrap()).unwrap();

        unsafe {
            let mut store: *mut FtStoreHandle = std::ptr::null_mut();
            let st = ft_store_open(root.as_ptr(), &mut store);
            assert_eq!(FtStatus::from_raw(st), FtStatus::Ok);
            assert!(!store.is_null());

            let payload = b"hello from rust sys crate";
            let mut hash_hex: *mut c_char = std::ptr::null_mut();
            let st = ft_store_put(store, payload.as_ptr(), payload.len(), &mut hash_hex);
            assert_eq!(FtStatus::from_raw(st), FtStatus::Ok);
            assert!(!hash_hex.is_null());

            assert_eq!(ft_store_has(store, hash_hex), 1);

            let mut out_data: *mut u8 = std::ptr::null_mut();
            let mut out_len: usize = 0;
            let st = ft_store_get(store, hash_hex, &mut out_data, &mut out_len);
            assert_eq!(FtStatus::from_raw(st), FtStatus::Ok);
            assert_eq!(out_len, payload.len());
            let slice = std::slice::from_raw_parts(out_data, out_len);
            assert_eq!(slice, payload);

            ft_bytes_free(out_data);
            ft_string_free(hash_hex);
            ft_store_close(store);
        }
        std::fs::remove_dir_all(&dir).ok();
    }

    #[test]
    fn last_error_reports_invalid_hex() {
        init();
        let dir = std::env::temp_dir().join(format!("fasttree-sys-test-err-{}", std::process::id()));
        std::fs::create_dir_all(&dir).unwrap();
        let root = CString::new(dir.to_str().unwrap()).unwrap();
        unsafe {
            let mut store: *mut FtStoreHandle = std::ptr::null_mut();
            assert_eq!(FtStatus::from_raw(ft_store_open(root.as_ptr(), &mut store)), FtStatus::Ok);

            let bad_hex = CString::new("too-short").unwrap();
            let mut out_data: *mut u8 = std::ptr::null_mut();
            let mut out_len: usize = 0;
            let st = ft_store_get(store, bad_hex.as_ptr(), &mut out_data, &mut out_len);
            assert_eq!(FtStatus::from_raw(st), FtStatus::ErrInvalidArgument);

            let err = CStr::from_ptr(ft_last_error()).to_string_lossy();
            assert!(err.contains("64"), "komunikat błędu powinien wspomnieć oczekiwaną długość: {err}");

            ft_store_close(store);
        }
        std::fs::remove_dir_all(&dir).ok();
    }
}
