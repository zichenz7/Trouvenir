# iOS 3D Souvenir Render Diagnostics

Use this for Trouvenir iOS App bugs where the `3D 模型预览` sheet is blank, stuck on `正在下载并解析 3D 模型...`, fails after reopening, or behaves differently after tab/window switches.

## Log Locations

When the local bridge is running with `npm run dev`, App and bridge diagnostics are mirrored to:

```bash
tail -n 120 artifacts/ios-render-diagnostics/render.ndjson
curl -s "http://127.0.0.1:3000/debug/render-log?limit=120" | jq
```

The iOS App also writes a local fallback log so diagnostics survive if the bridge is down:

```bash
APP_CONTAINER="$(xcrun simctl get_app_container booted com.zhuzichen.Trouvenir data)"
tail -n 120 "$APP_CONTAINER/Library/Caches/TrouvenirDiagnostics/model-viewer.ndjson"
```

The model proxy cache lives here:

```text
artifacts/tripo-model-cache/
```

## What Gets Recorded

The logger stores compact NDJSON events with timestamps, session IDs, call sites, and sanitized payloads. It intentionally removes signed URL query strings and secrets. App logs rotate around 768 KB; bridge logs rotate around 1 MB; both keep about 7 days. The model cache is capped by age and total bytes.

Useful event families:

- `model.open.request`: which screen opened the preview and which proxied model URL was used.
- `app.tab.changed`, `collection.tab.changed`, `model.sheet.*`: navigation and sheet lifecycle.
- `tripo.generate.start`, `tripo.task.created`, `tripo.task.poll`, `tripo.task.poll.error`, `tripo.task.resume`: generation and recovery flow.
- `bridge.tripoRequest.response`, `bridge.tripoRequest.retry`: Tripo API calls and idempotent GET retries.
- `model.webview.loadHTML`, `model.webview.reloadSkipped`: whether SwiftUI caused a WebView reload.
- `js.component.import.*`: `<model-viewer>` CDN loading.
- `js.model.fetch.*`: model proxy HTTP status, bytes, content type, cache hit/miss, and fetch timing.
- `bridge.modelProxy.*`: Tripo model proxy validation, cache, download, GLB magic bytes, and response timing.
- `js.model.load.success`, `js.model.load.error`, `js.model.parse.timeout`: final viewer parse/render outcome.
- `js.document.visibility`, `js.window.focus`, `js.window.blur`, `js.viewer.pointerdown`, `js.document.click`: interaction and window state.

## Repro Flow

1. Start the local bridge:

```bash
npm run dev
```

2. Build or run the iOS target:

```bash
npm run verify:ios
```

3. In the App, generate a 3D souvenir or open an existing souvenir from `收藏馆`, then tap `打开模型`.
4. If the sheet stalls, inspect the latest session ID in `artifacts/ios-render-diagnostics/render.ndjson`.
5. A healthy run should show `bridge.modelProxy.response`, `js.model.fetch.success`, `js.model.src.assigned`, then `js.model.load.success`.

For simulator-only E2E without spending Tripo credits, launch a Debug build with these environment variables:

```bash
TROUVENIR_DEBUG_PROXIED_MODEL_URL="http://127.0.0.1:3008/api/tripo/model-proxy?url=..." \
TROUVENIR_RENDER_DIAGNOSTICS_URL="http://127.0.0.1:3008/debug/render-log"
```

The Debug-only launch hook opens the same `ModelViewerSheet` used by production UI. Release builds ignore this hook.

## Reading Failures

- Component failure: `js.component.import.failure` for both CDN sources means the App could not load `<model-viewer>`.
- Proxy failure: `bridge.error` or missing `bridge.modelProxy.response` points to model URL validation, download, or local bridge availability.
- Generation poll failure: `tripo.task.poll` followed by `bridge.error` with `curl: (35) Recv failure: Connection reset by peer` means the Tripo task may still finish remotely. Use the same task ID and continue polling instead of creating a new paid task.
- Bad bytes: `bridge.modelProxy.response` with `glbMagic` not equal to `glTF` means Tripo returned a non-GLB body.
- Repeated reloads: multiple `model.webview.loadHTML` events for the same session without `model.webview.reloadSkipped` means SwiftUI is rebuilding the WebView path.
- Parser stall: `js.model.fetch.success` followed by `js.model.parse.timeout` means bytes arrived but `<model-viewer>` could not parse/render them.
