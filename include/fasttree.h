#ifndef FASTTREE_H
#define FASTTREE_H

#include <stddef.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

typedef enum {
  FT_OK = 0,
  FT_ERR_INVALID_ARGUMENT = 1,
  FT_ERR_IO = 2,
  FT_ERR_NOT_FOUND = 3,
  FT_ERR_FORMAT = 4,      /* niezgodność formatVersion manifestu/store'u */
  FT_ERR_INTERNAL = 5     /* wyjątek Nim inny niż powyższe — patrz ft_last_error() */
} FtStatus;

typedef struct FtStoreHandle FtStoreHandle;
typedef struct FtManifestHandle FtManifestHandle;

typedef struct {
  size_t   scannedObjects;
  size_t   liveObjects;
  size_t   deletedObjects;
  uint64_t freedBytes;
} FtGcResult;

/* --- Diagnostyka -------------------------------------------------------- */

/* Komunikat błędu dla ostatniego wywołania NA TYM WĄTKU, które zwróciło
 * status != FT_OK. Wskaźnik ważny do następnego wywołania FastTree na tym
 * wątku — skopiuj sobie string, jeśli potrzebujesz go dłużej. */
const char* ft_last_error(void);

/* --- Zarządzanie pamięcią zwracanych buforów ----------------------------- */

void ft_string_free(char* s);      /* dla cstring z ft_*_to_json / ft_*_hex   */
void ft_bytes_free(uint8_t* p);    /* dla surowych bajtów z ft_store_get       */

/* --- Store (content-addressable storage) --------------------------------- */

FtStatus ft_store_open(const char* root, FtStoreHandle** outHandle);
void     ft_store_close(FtStoreHandle* handle);

/* 1 = obiekt istnieje, 0 = nie istnieje LUB błędny hashHex (nie rozróżniamy). */
int ft_store_has(FtStoreHandle* handle, const char* hashHex);

/* outHashHex: owned, zwolnij ft_string_free. data może być NULL tylko gdy dataLen==0. */
FtStatus ft_store_put(FtStoreHandle* handle, const uint8_t* data, size_t dataLen,
                       char** outHashHex);

/* outData: owned, zwolnij ft_bytes_free. FT_ERR_NOT_FOUND jeśli obiekt nie istnieje. */
FtStatus ft_store_get(FtStoreHandle* handle, const char* hashHex,
                       uint8_t** outData, size_t* outLen);

/* --- Manifest (drzewo Merkle całego rootfs) -------------------------------- */

FtStatus ft_manifest_build(const char* sourceDir, FtStoreHandle* storeHandle,
                            FtManifestHandle** outHandle);
FtStatus ft_manifest_from_json(const char* json, FtManifestHandle** outHandle);
FtStatus ft_manifest_to_json(FtManifestHandle* handle, char** outJson);
FtStatus ft_manifest_root_hex(FtManifestHandle* handle, char** outHashHex);
size_t   ft_manifest_entry_count(FtManifestHandle* handle);
int      ft_manifest_format_version(FtManifestHandle* handle); /* -1 jeśli handle==NULL */
void     ft_manifest_close(FtManifestHandle* handle);

/* --- Garbage collection ---------------------------------------------------- */

FtStatus ft_gc_run(const char* ftRoot, int dryRun, FtGcResult* outResult);

/* --- Pull / Deploy (pelny cykl) --------------------------------------------- */

/* Pobiera+cache'uje warstwy OCI do cacheDir, rozpakowuje/scala (whiteout)
 * w workDir, buduje manifest FastTree zapisujac chunki do storeHandle.
 * outHandle: nowy uchwyt, zwolnij ft_manifest_close. */
FtStatus ft_pull_run(const char* imageRef, const char* cacheDir, const char* workDir,
                      FtStoreHandle* storeHandle, FtManifestHandle** outHandle);

typedef struct {
  char* imageDigest;     /* owned, zwolnij przez ft_deploy_result_free */
  char* verityRootHash;  /* owned, zwolnij przez ft_deploy_result_free */
} FtDeployResult;

/* Materializuje manifest do materializedDir, buduje obraz composefs w
 * outputImage, liczy hash-tree dm-verity. Atomowy A/B swap symlinka
 * "current" NIE jest tu robiony (specyficzne dla layoutu instalacji) —
 * to odpowiedzialnosc wolajacego, po sukcesie tej funkcji. */
FtStatus ft_deploy_build_image(FtManifestHandle* manifestHandle, FtStoreHandle* storeHandle,
                                const char* materializedDir, const char* outputImage,
                                FtDeployResult* outResult);
void ft_deploy_result_free(FtDeployResult* r);

/* --- Metadane biblioteki ----------------------------------------------------- */

int         ft_format_version(void);  /* aktualny FastTreeFormatVersion tej libfasttree */
const char* ft_hash_algo(void);       /* "blake3" | "sha256-fallback" — NIE wołaj free na tym */

#ifdef __cplusplus
}
#endif

#endif /* FASTTREE_H */
