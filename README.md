# Trouvenir

Trouvenir is starting as an iOS app for turning post-trip photos and memories into collectible travel identity cards, stories, and souvenirs.

## iOS app

Open the SwiftUI prototype in Xcode:

```bash
open ios/Trouvenir.xcodeproj
```

Build from the terminal:

```bash
xcodebuild -project ios/Trouvenir.xcodeproj -scheme Trouvenir -destination 'generic/platform=iOS Simulator' build
```

Build the iOS app through the project verification command:

```bash
npm run verify:ios
```

`verify:ios` only compiles the app. It does not create a Tripo generation task or consume generation credits.

The first version includes:

- A memory creation flow with destination, core memory, companions, feeling, and photo picking.
- A DeepSeek-powered memory generation flow that creates the travel identity card, story, and souvenir candidates without calling Tripo.
- Generated previews for a travel identity card, AI travel story, and souvenir shelf.
- A constrained optional 3D souvenir panel that asks the user for one standalone subject before calling Tripo OpenAPI.
- A collection tab and traveler profile tab to express the long-term "travel memory asset" direction.

## Travel Memory Box web prototype

The web prototype explores the core product direction: AI should not generate a whole scenic landscape in one shot. Instead, Trouvenir composes a collectible travel memory scene from a structured spec:

- AI identifies the destination, memory title, participant action, landmark motif, and emotional objects.
- React Three Fiber renders a premium travel diorama scene with OrbitControls, cinematic lighting, environment reflections, and soft contact shadows.
- Tripo or Tripo Studio is used for single GLB/glTF assets, such as an island base, ocean surface, wooden pier, palm tree, traveler, photo card, or sign.
- The final experience is a rotatable, collectible 3D memory box with clear human participation.

Run the prototype:

```bash
npm run web:dev
```

Open:

```text
http://127.0.0.1:5173
```

Build only:

```bash
npm run web:build
```

Generate local placeholder GLB files for the reserved asset slots:

```bash
npm run web:models
```

The current web prototype includes:

- A React Three Fiber scene with OrbitControls, ambient and directional lights, environment lighting, auto rotation, and contact shadows.
- Asset components for each scene object: `IslandBase`, `Ocean`, `Pier`, `PalmTree`, `Traveler`, `FloatingPhotos`, and `WoodenSign`.
- GLTFLoader-based loading for these reserved paths:
  - `web/public/models/island_base.glb`
  - `web/public/models/ocean_surface.glb`
  - `web/public/models/wooden_pier.glb`
  - `web/public/models/palm_tree.glb`
  - `web/public/models/traveler_back.glb`
  - `web/public/models/photo_card.glb`
  - `web/public/models/wooden_sign.glb`
- Desktop and mobile responsive layouts.

Studio-exported models can be placed under `web/public/models/` using the same filenames. The page will load those real assets automatically. This does not call the Tripo API or consume OpenAPI credits.

## Local AI and Tripo API bridge

This is a small backend wrapper for DeepSeek and the official Tripo3D OpenAPI. It keeps API keys on the server side and exposes simple local endpoints for travel-memory generation, text-to-3D, polling, model proxying, and balance checks.

Official docs used:

- DeepSeek base URL: `https://api.deepseek.com`
- DeepSeek chat endpoint: `POST /chat/completions`
- DeepSeek default model: `deepseek-v4-flash`
- Base URL: `https://api.tripo3d.ai/v2/openapi`
- Auth: `Authorization: Bearer YOUR_TRIPO_API_KEY`
- Create task: `POST /task`
- Poll task: `GET /task/{task_id}`
- Recommended file upload: `POST /upload/sts/token`, then upload to S3 and pass `file.object`

## Setup

```bash
npm install
cp .env.example .env
```

Put your DeepSeek and Tripo keys in `.env`:

```bash
DEEPSEEK_API_KEY=sk_your_deepseek_api_key_here
DEEPSEEK_BASE_URL=https://api.deepseek.com
DEEPSEEK_MODEL=deepseek-v4-flash
TRIPO_API_KEY=tsk_your_api_key_here
```

## Run the server

```bash
npm run dev
```

Health check:

```bash
curl http://localhost:3000/health
```

## Deploy the API bridge for TestFlight

The iOS app must not ship with DeepSeek or Tripo API keys. Deploy this Node bridge as an HTTPS web service and store keys as server-side environment variables.

This repo includes `render.yaml` for Render Blueprint deployment. Push the repo to GitHub, create a Render Blueprint from the repo, and enter these secret values when prompted:

```bash
DEEPSEEK_API_KEY=sk_your_deepseek_api_key_here
TRIPO_API_KEY=tsk_your_api_key_here
```

Render also sets:

```bash
NODE_ENV=production
HOST=0.0.0.0
DEEPSEEK_BASE_URL=https://api.deepseek.com
DEEPSEEK_MODEL=deepseek-v4-flash
TRIPO_BASE_URL=https://api.tripo3d.ai/v2/openapi
TROUVENIR_ENABLE_DEBUG_ENDPOINTS=0
```

After deployment, verify the public service:

```bash
curl https://trouvenir-api.onrender.com/health
```

The iOS app uses `http://127.0.0.1:3000` in Debug builds and `https://trouvenir-api.onrender.com` in Release/TestFlight builds. To temporarily point any build at another bridge, set the `TROUVENIR_BRIDGE_BASE_URL` launch environment variable.

## Run the iOS app with DeepSeek and Tripo

The iOS app calls this local bridge instead of calling DeepSeek or Tripo directly, so API keys stay off the device.

1. For local Debug development, start the bridge:

```bash
npm run dev
```

2. Open `ios/Trouvenir.xcodeproj` in Xcode and run the `Trouvenir` scheme on an iOS Simulator. Release/TestFlight builds use the deployed Render bridge instead.

3. In the `创造` tab, first tap `下一步`. This calls `/api/ai/memory`, which asks DeepSeek to return structured JSON for the destination, title, identity card, story, and souvenir candidates.

4. Answer the 3D subject question by choosing a generic subject type, such as `一个人物主体`, `一个地标局部`, `一个交通工具`, or `一个随身物件`. Add the specific detail in the text field when needed.

5. If you want to spend API credits on a 3D model, tap `生成 3D 纪念品` in the optional 3D panel.

The app uses selected photos as memory context in the product flow. The main memory generation path now calls DeepSeek and does not consume Tripo credits. Before the optional 3D action is enabled, the app asks one narrow question: what standalone subject should Tripo generate? The optional 3D souvenir action then sends a structured text prompt to `/api/tripo/text-to-model`. This keeps the output closer to a complete, freestanding collectible subject instead of turning an entire landscape photo into a broad scene base.

Default model quality is tuned toward premium collectibles:

- `model_version`: `P1-20260311`
- `texture`: `true`
- `pbr`: `true`
- `texture_quality`: `standard`
- `face_limit`: `20000`

The local bridge also compacts prompts before calling Tripo:

- `prompt`: up to 620 characters
- `negative_prompt`: up to 220 characters

This does not run during `npm run verify:ios`; it is only used when the app submits a real Tripo generation task.

DeepSeek memory generation also does not run during `npm run verify:ios`; it is only used when the app calls `/api/ai/memory` from the creation flow.

Souvenir generation constraints:

- Ask the user one constrained question before generating: `这次 Tripo 只生成一个什么单独主体？`
- Prefer one isolated, complete main subject that can stand alone as a small collectible figurine.
- Keep travel context as secondary style input; the user-selected subject is the only generation target.
- Favor a premium handcrafted miniature feel with layered depth, carved details, enamel or ceramic materials, and a clean hero silhouette.
- Preserve the landmark's beauty as a compact sculptural motif. For Mount Fuji, the output should keep the elegant blue-white snow-capped cone, clean symmetrical silhouette, and premium Japanese souvenir feeling.
- Avoid complex tasks such as generating a full scene, multiple people, water areas, broad landscapes, postcard backdrops, or large terrain slabs.
- Convert broad memories into one subject category first. For example, choose `一个地标局部` for a landmark detail, `一个人物主体` for a traveler pose, `一个交通工具` for a ride, or `一个随身物件` for an object from the trip. Add destination-specific detail only after the category is clear.

The app centralizes bridge selection in `TrouvenirAPIEnvironment`: Debug defaults to the local bridge, while Release/TestFlight defaults to the Render bridge.

## API

Text to model:

```bash
curl -X POST http://localhost:3000/api/tripo/text-to-model \
  -H "Content-Type: application/json" \
  -d '{"prompt":"A cute low-poly cat sitting on a suitcase"}'
```

Image URL to model:

```bash
curl -X POST http://localhost:3000/api/tripo/image-to-model/url \
  -H "Content-Type: application/json" \
  -d '{"imageUrl":"https://example.com/object.png"}'
```

Local image upload to model:

```bash
curl -X POST http://localhost:3000/api/tripo/image-to-model/upload \
  -F "file=@./object.png"
```

Check task:

```bash
curl http://localhost:3000/api/tripo/tasks/<task_id>
```

Wait for final task status:

```bash
curl -X POST http://localhost:3000/api/tripo/tasks/<task_id>/wait \
  -H "Content-Type: application/json" \
  -d '{"timeoutMs":600000}'
```

## CLI

```bash
npm run cli -- text "A cute low-poly cat sitting on a suitcase"
npm run cli -- image-url https://example.com/object.png
npm run cli -- image-file ./object.png
npm run cli -- status <task_id>
npm run cli -- wait <task_id>
npm run cli -- download <task_id> output
npm run cli -- balance
```

Task output download URLs usually expire quickly, so run `download` soon after the task succeeds.
