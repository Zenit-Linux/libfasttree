import std/[httpclient, json, strformat, os, strutils, uri]

type
  ImageRef* = object
    registry*, repository*, reference*: string  # reference = tag lub @sha256:...

  Layer* = object
    digest*, mediaType*: string
    size*: int64

  OciAuthError* = object of CatchableError

  AuthCache* = ref object
    ## Token Bearer, jeśli już zdobyty w ramach tego `pull` — przekazywany
    ## jawnie (nie chowany w polu HttpClient) właśnie DLATEGO, że klienci
    ## są teraz jednorazowe (patrz komentarz modułu): coś musi przetrwać
    ## między nimi, żeby nie robić handshake'u tokenu przed KAŻDYM blobem.
    token: string

proc newAuthCache*(): AuthCache = AuthCache(token: "")

proc registryScheme(registry: string): string =
  ## `http` tylko dla oczywistych lokalnych rejestrów deweloperskich
  ## (localhost/127.0.0.1[:port]) — dokładnie ta sama konwencja co Docker/
  ## containerd/buildah stosują domyślnie dla "insecure registries" bez
  ## dodatkowej konfiguracji. Każdy inny host (w tym IP w sieci lokalnej)
  ## dostaje `https` — nie robimy cichych wyjątków bezpieczeństwa poza tym
  ## jednym, powszechnie przyjętym przypadkiem.
  let host = registry.split(':')[0]
  if host == "localhost" or host == "127.0.0.1":
    "http"
  else:
    "https"

proc parseImageRef*(s: string): ImageRef =
  ## np. "ghcr.io/hackeros/system:v2.0" -> registry=ghcr.io, repo=hackeros/system, ref=v2.0
  let slashIdx = s.find('/')
  doAssert slashIdx > 0, "oczekiwano <registry>/<repo>[:tag]"
  let registry = s[0 ..< slashIdx]
  var rest = s[slashIdx+1 .. ^1]
  var reference = "latest"
  let colonIdx = rest.rfind(':')
  if colonIdx > rest.rfind('/'):
    reference = rest[colonIdx+1 .. ^1]
    rest = rest[0 ..< colonIdx]
  ImageRef(registry: registry, repository: rest, reference: reference)

proc parseWwwAuthenticate(header: string): tuple[realm, service, scope: string] =
  ## Parsuje `WWW-Authenticate: Bearer realm="...",service="...",scope="..."`.
  ## Zwraca puste stringi (nie wyjątek), jeśli nagłówek nie jest w tym
  ## formacie — wołający traktuje pusty realm jako "ten rejestr nie używa
  ## Bearer auth" i przerywa próbę autoryzacji.
  result = ("", "", "")
  if not header.startsWith("Bearer"):
    return
  let rest = header["Bearer".len .. ^1].strip()
  for part in rest.split(','):
    let kv = part.strip().split('=', 1)
    if kv.len != 2: continue
    let key = kv[0].strip()
    var val = kv[1].strip()
    if val.len >= 2 and val[0] == '"' and val[^1] == '"':
      val = val[1 ..< ^1]
    case key
    of "realm": result.realm = val
    of "service": result.service = val
    of "scope": result.scope = val

proc fetchBearerToken(realm, service, scope: string): string =
  var url = realm
  var params: seq[string] = @[]
  if service.len > 0: params.add "service=" & encodeUrl(service)
  if scope.len > 0: params.add "scope=" & encodeUrl(scope)
  if params.len > 0: url &= "?" & params.join("&")

  let tokenClient = newHttpClient(timeout = 15_000)
  defer: tokenClient.close()
  let raw = try:
      tokenClient.getContent(url)
    except CatchableError as e:
      raise newException(OciAuthError, "pobranie tokenu z '" & realm & "' nie powiodło się: " & e.msg)

  let j = parseJson(raw)
  # Rejestry różnią się nazwą pola: Docker Hub używa "token", niektóre inne
  # implementacje (m.in. starsze wersje distribution) — "access_token".
  if j.hasKey("token"): j["token"].getStr
  elif j.hasKey("access_token"): j["access_token"].getStr
  else: raise newException(OciAuthError, "odpowiedź serwera tokenów nie zawiera pola 'token' ani 'access_token'")

proc requestGet(url: string, auth: AuthCache): Response =
  ## Świeży klient, jedno żądanie. Jeśli `auth` ma już token z poprzedniego
  ## wywołania w ramach tego samego `pull`, wysyłamy go od razu (unikamy
  ## zbędnego roundtripu 401 dla KAŻDEGO bloba osobno).
  let client = newHttpClient(timeout = 30_000)
  defer: client.close()
  var headers = newHttpHeaders({
    "Accept": "application/vnd.oci.image.manifest.v1+json,application/vnd.docker.distribution.manifest.v2+json"
  })
  if auth.token.len > 0:
    headers["Authorization"] = "Bearer " & auth.token
  client.headers = headers
  result = client.request(url, HttpGet)

  if result.code == Http401:
    let wwwAuth = result.headers.getOrDefault("www-authenticate")
    let (realm, service, scope) = parseWwwAuthenticate(wwwAuth)
    if realm.len == 0:
      return  # 401 bez rozpoznawalnego Bearer challenge — nic więcej nie zrobimy
    auth.token = fetchBearerToken(realm, service, scope)
    let retryClient = newHttpClient(timeout = 30_000)
    defer: retryClient.close()
    retryClient.headers = newHttpHeaders({"Authorization": "Bearer " & auth.token})
    result = retryClient.request(url, HttpGet)

proc fetchManifest*(imgRef: ImageRef, auth: AuthCache): JsonNode =
  let url = &"{registryScheme(imgRef.registry)}://{imgRef.registry}/v2/{imgRef.repository}/manifests/{imgRef.reference}"
  let resp = requestGet(url, auth)
  if resp.code.is4xx or resp.code.is5xx:
    raise newException(OciAuthError,
      &"GET {url} zwróciło {resp.code} — {resp.body[0 ..< min(200, resp.body.len)]}")
  parseJson(resp.body)

proc layersFromManifest*(m: JsonNode): seq[Layer] =
  result = @[]
  for l in m["layers"]:
    result.add Layer(
      digest: l["digest"].getStr,
      mediaType: l["mediaType"].getStr,
      size: l["size"].getBiggestInt)

proc downloadLayer*(imgRef: ImageRef, layer: Layer, destPath: string, auth: AuthCache) =
  let url = &"{registryScheme(imgRef.registry)}://{imgRef.registry}/v2/{imgRef.repository}/blobs/{layer.digest}"
  createDir(destPath.parentDir)
  let resp = requestGet(url, auth)
  if resp.code.is4xx or resp.code.is5xx:
    raise newException(OciAuthError,
      &"GET {url} (blob {layer.digest}) zwróciło {resp.code}")
  writeFile(destPath, resp.body)

type ResolvedLayer* = object
  layer*: Layer
  path*: string        # ścieżka lokalna (cache), gotowa do `tar -xf`
  wasCached*: bool      # false = pobrana w tym wywołaniu, true = już była w cacheDir

proc digestToFilename(digest: string): string = digest.replace(":", "_")

proc resolveImageLayers*(imgRef: ImageRef, cacheDir: string): seq[ResolvedLayer] =
  ## Zwraca WSZYSTKIE warstwy obrazu, w kolejności z manifestu OCI (dół -> góra),
  ## z lokalną ścieżką każdej z nich. Warstwy już obecne w `cacheDir` (z
  ## poprzedniego `pull`, także innego taga współdzielącego bazę) nie są
  ## pobierane ponownie — to realizuje deduplikację na poziomie blobów OCI,
  ## niezależną od deduplikacji na poziomie chunków w store.nim.
  createDir(cacheDir)
  let auth = newAuthCache()
  let manifestJson = fetchManifest(imgRef, auth)
  let layers = layersFromManifest(manifestJson)

  result = @[]
  for layer in layers:
    let dest = cacheDir / digestToFilename(layer.digest)
    let cached = fileExists(dest)
    if not cached:
      downloadLayer(imgRef, layer, dest, auth)
    result.add ResolvedLayer(layer: layer, path: dest, wasCached: cached)
