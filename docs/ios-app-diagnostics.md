# iOS App Diagnostics

Use this for Trouvenir iOS App bugs where destinations are grouped under the wrong city or country, archive counts look wrong, tabs behave differently after switching, or a user flow needs compact event evidence.

## Log Locations

When the local bridge is running with `npm run dev`, app diagnostics are mirrored to:

```bash
tail -n 160 artifacts/ios-app-diagnostics/app.ndjson
curl -s "http://127.0.0.1:3000/debug/app-log?limit=160" | jq
```

The iOS App also writes a local fallback log so diagnostics survive if the bridge is down:

```bash
APP_CONTAINER="$(xcrun simctl get_app_container booted com.zhuzichen.Trouvenir data)"
tail -n 160 "$APP_CONTAINER/Library/Caches/TrouvenirDiagnostics/app.ndjson"
```

## What Gets Recorded

The logger stores compact NDJSON events with millisecond timestamps, a per-launch session ID, call sites, event names, and sanitized payloads. It redacts secret-like fields, summarizes URLs, caps each line, writes on a utility queue, rotates local app logs around 512 KB, rotates bridge logs around 1 MB, and cleans rotated files after about 7 days.

Useful event families:

- `app.appear`, `app.scenePhase.changed`, `app.tab.changed`: launch, window state, and root tab switching.
- `collection.tab.changed`: collection shelf tab switching.
- `identity.archive.appear`: profile archive list opening for countries, cities, or memories.
- `location.resolve`: destination-to-city/country decisions, including raw input, normalized key, matched rule, output city, output country, and call site.
- `location.ai.resolve.*`, `location.cache.updated`: DeepSeek-backed location normalization for destinations that are not covered by deterministic rules.
- `location.country.resolve.ai.*`: country archive results that came from the DeepSeek location cache instead of CLGeocoder.
- `location.country.resolve.start`, `location.country.resolve.geocode.*`: country resolver work, CLGeocoder fallback results, and rejected low-confidence geocoder matches.
- `debug.memory.seeded`: Debug-only simulator fixture used for deterministic E2E reproduction.

## Reading City/Country Bugs

1. Reproduce the issue once in the simulator or on device.
2. Read the newest `location.resolve` events:

```bash
tail -n 240 artifacts/ios-app-diagnostics/app.ndjson | jq -c 'select(.event=="location.resolve")'
```

3. Check these fields:

- `data.input`: the destination string saved on the memory.
- `data.normalizedKey`: the compact comparison key used by rules.
- `data.rule`: the deterministic rule that matched, or `fallback.destination`.
- `data.city`: the archive city shown in the UI.
- `data.country`: the known country used before CLGeocoder fallback.
- `call`: which view or resolver asked for the mapping.

4. If `data.rule` is `fallback.destination`, check for a nearby `location.ai.resolve.success`. This means the app used DeepSeek to normalize a long-tail place and cached the city/country result.
5. If `location.ai.resolve.cancelled` appears, the view task was interrupted by navigation or tab switching. The app should emit `location.country.resolve.ai.pending` and must not fall through to CLGeocoder in that same pass.
6. If `location.ai.resolve.error` appears, inspect the bridge `/api/ai/location` path, DeepSeek config, and network logs before adding another local rule.
7. If `location.ai.resolve.unusable` appears, DeepSeek returned low confidence or no country. Add a deterministic rule for high-value regressions, then keep CLGeocoder as the last fallback.
8. If a `location.country.resolve.geocode.rejected` event appears, the app intentionally ignored a low-confidence CLGeocoder match. For Latin-letter place names, the placemark must contain a core token from the original query before the country is accepted.
9. If a `location.country.resolve.geocode.success` event disagrees with the deterministic or DeepSeek rule, keep the deterministic/DeepSeek result authoritative and treat the geocoder result as suspect evidence.

## DeepSeek Location Resolver

The bridge exposes a dedicated location resolver:

```bash
curl -s http://127.0.0.1:3000/api/ai/location \
  -H 'Content-Type: application/json' \
  -d '{"input":"哈利法塔"}' | jq
```

Expected healthy shape:

```json
{"cityName":"迪拜","countryName":"阿联酋","regionCode":"AE","confidence":"high","reason":"哈利法塔位于迪拜"}
```

The iOS archive resolver uses this order:

1. deterministic `TravelArchive` rules for known regressions and high-confidence landmarks;
2. DeepSeek `/api/ai/location` for long-tail user input;
3. CLGeocoder only as the final fallback, with rejection rules for suspicious matches.

## Simulator Repro Seed

For simulator-only E2E without calling DeepSeek, launch a Debug build with:

```bash
SIMCTL_CHILD_TROUVENIR_DEBUG_SEED_MEMORY_DESTINATION="Alcatraz Island" \
SIMCTL_CHILD_TROUVENIR_APP_DIAGNOSTICS_URL="http://127.0.0.1:3000/debug/app-log" \
xcrun simctl launch --terminate-running-process booted com.zhuzichen.Trouvenir
```

The Debug-only launch hook inserts one in-memory travel record. Release builds ignore this hook.

## Healthy Alcatraz Evidence

A healthy run for the known regression should include:

```json
{"event":"location.resolve","data":{"input":"Alcatraz Island","city":"旧金山","country":"美国","regionCode":"US","rule":"known.sanFrancisco","matchedTerm":"alcatraz"}}
```

The UI should then show:

- `城市` list: `旧金山`, subtitle `美国`.
- `国家` list: `美国`, subtitle `1 个城市`.

## Healthy Newport Beach Evidence

A healthy run for the Newport Beach regression should include:

```json
{"event":"location.resolve","data":{"input":"Newport Beach","city":"Newport Beach","country":"美国","regionCode":"US","rule":"known.newportBeach","matchedTerm":"newportbeach"}}
```

The previous broken pattern was `fallback.destination` followed by `location.country.resolve.geocode.success` with a China placemark such as `广东省揭阳市惠来县海滩`. After this fix, that kind of unrelated Latin-query geocoder result is rejected instead of being used as the archive country.

## Healthy Los Angeles Evidence

A healthy run for the Hollywood / Los Angeles regression should include:

```json
{"event":"location.resolve","data":{"input":"好莱坞环球影城","city":"洛杉矶","country":"美国","regionCode":"US","rule":"known.losAngeles","matchedTerm":"好莱坞环球影城"}}
```

The previous broken pattern was `fallback.destination` for `洛杉矶`, followed by `location.country.resolve.geocode.success` with a China placemark such as `福建省厦门市思明区源昌国际城2期269号楼`. The deterministic Los Angeles rule should make the country resolver emit `location.country.resolve.known` instead. If a non-Latin query still falls through to CLGeocoder, China placemarks are rejected unless the placemark evidence contains the original query.

## Healthy Yellowstone Evidence

A healthy run for the Yellowstone regression should include:

```json
{"event":"location.resolve","data":{"input":"黄石","city":"黄石","country":"美国","regionCode":"US","rule":"known.yellowstone","matchedTerm":"黄石"}}
```

The previous broken pattern was `location.ai.resolve.start` followed by `location.ai.resolve.error` with `message: "cancelled"`, then immediate `location.country.resolve.geocode.success` with `isoCountryCode: "CN"` and `placemarkName: "黄石市"`. A cancelled DeepSeek task should now produce `location.country.resolve.ai.pending` instead of accepting the CLGeocoder China result.
