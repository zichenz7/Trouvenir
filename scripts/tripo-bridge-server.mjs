import { spawn } from "node:child_process";
import { createHash } from "node:crypto";
import { createServer } from "node:http";
import { readFileSync } from "node:fs";
import { appendFile, mkdir, readdir, readFile, rename, stat, unlink, writeFile } from "node:fs/promises";
import { dirname, resolve } from "node:path";
import { fileURLToPath } from "node:url";

const projectRoot = resolve(dirname(fileURLToPath(import.meta.url)), "..");
const envPath = resolve(projectRoot, ".env");
const defaultModelVersion = "P1-20260311";

loadEnv();

const port = Number(process.env.PORT || 3000);
const host = process.env.HOST || "127.0.0.1";
const debugEndpointsEnabled = process.env.TROUVENIR_ENABLE_DEBUG_ENDPOINTS === "1"
  || process.env.NODE_ENV !== "production";
const tripoBaseURL = (process.env.TRIPO_BASE_URL || "https://api.tripo3d.ai/v2/openapi").replace(/\/$/, "");
const deepseekBaseURL = (process.env.DEEPSEEK_BASE_URL || "https://api.deepseek.com").replace(/\/$/, "");
const deepseekModel = process.env.DEEPSEEK_MODEL || "deepseek-v4-flash";
const diagnosticDir = resolve(projectRoot, "artifacts", "ios-render-diagnostics");
const diagnosticLogPath = resolve(diagnosticDir, "render.ndjson");
const diagnosticMaxBytes = Number(process.env.TROUVENIR_RENDER_LOG_MAX_BYTES || 1_000_000);
const diagnosticMaxAgeMs = Number(process.env.TROUVENIR_RENDER_LOG_MAX_AGE_MS || 7 * 24 * 60 * 60 * 1000);
const appDiagnosticDir = resolve(projectRoot, "artifacts", "ios-app-diagnostics");
const appDiagnosticLogPath = resolve(appDiagnosticDir, "app.ndjson");
const appDiagnosticMaxBytes = Number(process.env.TROUVENIR_APP_LOG_MAX_BYTES || 1_000_000);
const appDiagnosticMaxAgeMs = Number(process.env.TROUVENIR_APP_LOG_MAX_AGE_MS || 7 * 24 * 60 * 60 * 1000);
const modelCacheDir = resolve(projectRoot, "artifacts", "tripo-model-cache");
const modelCacheMaxBytes = Number(process.env.TROUVENIR_MODEL_CACHE_MAX_BYTES || 220 * 1024 * 1024);
const modelCacheMaxAgeMs = Number(process.env.TROUVENIR_MODEL_CACHE_MAX_AGE_MS || 7 * 24 * 60 * 60 * 1000);
const configuredAllowedModelHosts = String(process.env.TROUVENIR_MODEL_PROXY_ALLOW_HOSTS || "")
  .split(",")
  .map((host) => host.trim().toLowerCase())
  .filter(Boolean);
let lastDiagnosticCleanupAt = 0;
let lastAppDiagnosticCleanupAt = 0;
let lastModelCacheCleanupAt = 0;

createServer(async (request, response) => {
  try {
    const method = request.method ?? "GET";
    const requestURL = new URL(request.url ?? "/", `http://${request.headers.host ?? "localhost"}`);
    const pathname = requestURL.pathname;

    if (method === "GET" && pathname === "/health") {
      sendJson(response, 200, { ok: true });
      return;
    }

    if (debugEndpointsEnabled && method === "GET" && pathname === "/debug/config") {
      sendJson(response, 200, {
        ok: true,
        envPath,
        hasTripoApiKey: Boolean(process.env.TRIPO_API_KEY),
        tripoApiKeyLength: process.env.TRIPO_API_KEY?.length ?? 0,
        hasTripoBaseURL: Boolean(process.env.TRIPO_BASE_URL),
        tripoBaseURL,
        hasTripoResolveIP: Boolean(process.env.TRIPO_RESOLVE_IP),
        tripoResolveIP: process.env.TRIPO_RESOLVE_IP || "",
        hasDeepseekApiKey: Boolean(process.env.DEEPSEEK_API_KEY),
        deepseekApiKeyLength: process.env.DEEPSEEK_API_KEY?.length ?? 0,
        hasDeepseekBaseURL: Boolean(process.env.DEEPSEEK_BASE_URL),
        deepseekBaseURL,
        deepseekModel,
        hasHttpsProxy: Boolean(process.env.HTTPS_PROXY || process.env.https_proxy),
        hasHttpProxy: Boolean(process.env.HTTP_PROXY || process.env.http_proxy)
      });
      return;
    }

    if (debugEndpointsEnabled && method === "OPTIONS" && pathname === "/debug/render-log") {
      response.writeHead(204, corsHeaders());
      response.end();
      return;
    }

    if (debugEndpointsEnabled && method === "POST" && pathname === "/debug/render-log") {
      const body = await readJson(request, 64 * 1024);
      await appendRenderDiagnostic({
        ...body,
        source: body.source || "ios-app"
      });
      sendJson(response, 200, { ok: true }, corsHeaders());
      return;
    }

    if (debugEndpointsEnabled && method === "GET" && pathname === "/debug/render-log") {
      const limit = Number(requestURL.searchParams.get("limit") || 200);
      sendJson(response, 200, await readRenderDiagnostics(limit), corsHeaders());
      return;
    }

    if (debugEndpointsEnabled && method === "OPTIONS" && pathname === "/debug/app-log") {
      response.writeHead(204, corsHeaders());
      response.end();
      return;
    }

    if (debugEndpointsEnabled && method === "POST" && pathname === "/debug/app-log") {
      const body = await readJson(request, 64 * 1024);
      await appendAppDiagnostic({
        ...body,
        source: body.source || "ios-app"
      });
      sendJson(response, 200, { ok: true }, corsHeaders());
      return;
    }

    if (debugEndpointsEnabled && method === "GET" && pathname === "/debug/app-log") {
      const limit = Number(requestURL.searchParams.get("limit") || 200);
      sendJson(response, 200, await readAppDiagnostics(limit), corsHeaders());
      return;
    }

    if (method === "POST" && pathname === "/api/ai/memory") {
      const body = await readJson(request);
      sendJson(response, 200, await createTravelMemory(body));
      return;
    }

    if (method === "GET" && pathname === "/api/tripo/balance") {
      sendJson(response, 200, await tripoRequest("/user/balance"));
      return;
    }

    if (method === "GET" && pathname === "/api/tripo/model-proxy") {
      await proxyModelFile(requestURL, request, response);
      return;
    }

    if (method === "POST" && pathname === "/api/tripo/text-to-model") {
      const body = await readJson(request);
      const taskId = await createTextToModelTask(body);
      sendJson(response, 202, { task_id: taskId });
      return;
    }

    const taskMatch = pathname.match(/^\/api\/tripo\/tasks\/([^/]+)$/);
    if (method === "GET" && taskMatch) {
      sendJson(response, 200, await tripoRequest(`/task/${encodeURIComponent(taskMatch[1])}`));
      return;
    }

    sendJson(response, 404, { error: "Not found" });
  } catch (error) {
    sendError(response, error);
  }
}).listen(port, host, () => {
  console.log(`Tripo API bridge listening on http://${host}:${port}`);
});

async function createTravelMemory(input) {
  const prompt = compactText(input.prompt, 1200);
  const destination = compactText(input.destination, 80);
  const tripTitle = compactText(input.tripTitle, 80);
  const companions = compactText(input.companions, 80);
  const feeling = compactText(input.feeling, 260);

  if (!prompt && !destination && !tripTitle && !feeling) {
    throw new BridgeError("请先输入这次旅行的线索。", 400);
  }

  const userContent = JSON.stringify({
    prompt,
    destination,
    tripTitle,
    companions,
    feeling,
    photoCount: Number(input.photoCount || 0)
  });

  const payload = {
    model: deepseekModel,
    messages: [
      {
        role: "system",
        content: [
          "你是 Trouvenir 的旅行记忆生成器。",
          "请把用户输入整理成一个可收藏的旅行记忆对象。",
          "只输出 JSON，不要 Markdown，不要解释。",
          "语气温暖、克制、有纪念感，不要营销腔。",
          "纪念品要具体、易收藏、适合旅行收藏馆展示。",
          "旅行故事标题必须像一本小书或一张明信片的标题：短、有画面、不要复述用户原句。"
        ].join("\n")
      },
      {
        role: "user",
        content: [
          "根据以下旅行线索生成 JSON。",
          userContent,
          "JSON schema:",
          JSON.stringify({
            title: "18字以内的旅行标题",
            destination: "目的地，尽量简短",
            identityTitle: "例如 富士山收藏家",
            companions: "同行的人，未知则用 独自旅行",
            walkingDistance: "例如 42 公里，无法判断可合理估计",
            duration: "例如 5 天 4 晚，无法判断可合理估计",
            storyTitle: "8到14字中文标题，必须带书名号，不要逗号、句号、数字流水账或完整句子",
            story: "80到150字中文旅行故事，包含具体瞬间和情绪",
            accentKey: "teal | coral | gold | blue",
            souvenirs: [
              {
                name: "纪念品名称",
                caption: "一句收藏说明",
                symbol: "合适的 SF Symbol 名称",
                colorKey: "teal | coral | gold | blue"
              }
            ]
          }),
          "souvenirs 必须正好 4 个。"
        ].join("\n")
      }
    ],
    temperature: 0.35,
    max_tokens: 1400,
    response_format: { type: "json_object" }
  };

  const startedAt = Date.now();
  const result = await deepseekRequest("/chat/completions", {
    method: "POST",
    body: JSON.stringify(payload)
  });
  const content = messageContent(result.choices?.[0]?.message);
  let memory;
  try {
    memory = parseJsonObject(content);
  } catch (error) {
    console.error(JSON.stringify({
      event: "deepseek_invalid_json_fallback",
      model: result.model ?? deepseekModel,
      content: compactText(content, 500)
    }));
    memory = fallbackTravelMemory(input);
  }
  const normalized = normalizeTravelMemory(memory, input);

  console.log(JSON.stringify({
    event: "deepseek_memory_created",
    model: result.model ?? deepseekModel,
    promptLength: prompt.length,
    durationMs: Date.now() - startedAt
  }));

  return normalized;
}

async function createTextToModelTask(input) {
  if (!String(input.prompt ?? "").trim()) {
    throw new BridgeError("prompt is required", 400);
  }

  const payload = cleanObject({
    type: "text_to_model",
    model_version: defaultModelVersion,
    ...input,
    prompt: compactText(input.prompt, 620),
    negative_prompt: input.negative_prompt ? compactText(input.negative_prompt, 220) : undefined
  });
  const debugSummary = summarizeTaskPayload(payload);

  console.log(JSON.stringify({
    event: "tripo_text_to_model_request",
    ...debugSummary
  }));

  const created = await tripoRequest("/task", {
    method: "POST",
    body: JSON.stringify(payload),
    debug: debugSummary
  });

  if (!created.task_id) {
    throw new BridgeError("Tripo did not return task_id", 502, created);
  }

  return created.task_id;
}

async function tripoRequest(path, init = {}) {
  const apiKey = process.env.TRIPO_API_KEY;
  if (!apiKey) {
    throw new BridgeError("Missing TRIPO_API_KEY. Put it in .env or export it in your shell.", 500);
  }

  const method = init.method ?? "GET";
  const headers = cleanObject({
    Authorization: `Bearer ${apiKey}`,
    "Content-Type": init.body ? "application/json" : undefined,
    ...init.headers
  });
  const retryable = init.retry ?? method === "GET";
  const maxAttempts = retryable ? Number(process.env.TRIPO_GET_RETRY_ATTEMPTS || 4) : 1;
  const url = `${tripoBaseURL}${path}`;
  const resolveHost = tripoResolveHost();
  let lastError;

  for (let attempt = 1; attempt <= maxAttempts; attempt += 1) {
    const startedAt = Date.now();
    try {
      const { status, payload } = await curlJson({
        method,
        url,
        headers,
        body: init.body,
        resolveHost
      });

      await appendRenderDiagnostic({
        event: "bridge.tripoRequest.response",
        level: status >= 500 || status === 429 ? "warn" : "info",
        source: "bridge",
        data: {
          method,
          path,
          status,
          attempt,
          durationMs: Date.now() - startedAt
        }
      });

      if ((status >= 500 || status === 408 || status === 429) && attempt < maxAttempts) {
        await appendRenderDiagnostic({
          event: "bridge.tripoRequest.retry",
          level: "warn",
          source: "bridge",
          data: {
            method,
            path,
            status,
            attempt,
            nextDelayMs: retryDelayMs(attempt)
          }
        });
        await sleep(retryDelayMs(attempt));
        continue;
      }

      if (status < 200 || status >= 300 || payload.code !== 0) {
        throw new BridgeError(payload.message ?? `Tripo request failed with HTTP ${status}`, status, {
          tripo: payload,
          request: init.debug
        });
      }

      return payload.data;
    } catch (error) {
      lastError = error;
      if (retryable && isRetryableBridgeError(error) && attempt < maxAttempts) {
        await appendRenderDiagnostic({
          event: "bridge.tripoRequest.retry",
          level: "warn",
          source: "bridge",
          data: {
            method,
            path,
            status: error.status,
            message: error.message,
            attempt,
            nextDelayMs: retryDelayMs(attempt)
          }
        });
        await sleep(retryDelayMs(attempt));
        continue;
      }

      throw error;
    }
  }

  throw lastError;
}

async function deepseekRequest(path, init = {}) {
  const apiKey = process.env.DEEPSEEK_API_KEY;
  if (!apiKey) {
    throw new BridgeError("Missing DEEPSEEK_API_KEY. Put it in .env or export it in your shell.", 500);
  }

  const method = init.method ?? "GET";
  const headers = cleanObject({
    Authorization: `Bearer ${apiKey}`,
    "Content-Type": init.body ? "application/json" : undefined,
    ...init.headers
  });
  const { status, payload } = await curlJson({
    method,
    url: `${deepseekBaseURL}${path}`,
    headers,
    body: init.body
  });

  if (status < 200 || status >= 300 || payload.error) {
    throw new BridgeError(
      payload.error?.message ?? payload.message ?? `DeepSeek request failed with HTTP ${status}`,
      status,
      { deepseek: payload }
    );
  }

  return payload;
}

async function proxyModelFile(requestURL, request, response) {
  const target = requestURL.searchParams.get("url");
  if (!target) {
    throw new BridgeError("url is required", 400);
  }

  let targetURL;
  try {
    targetURL = new URL(target);
  } catch {
    throw new BridgeError("url must be valid", 400);
  }

  if (targetURL.protocol !== "https:" || !isAllowedTripoModelHost(targetURL.hostname)) {
    await appendRenderDiagnostic({
      event: "bridge.modelProxy.denied",
      level: "warn",
      source: "bridge",
      data: {
        targetURL: summarizeURL(targetURL.toString()),
        reason: "host_not_allowed"
      }
    });
    throw new BridgeError("Only Tripo model URLs can be proxied", 400);
  }

  const range = typeof request.headers.range === "string" ? request.headers.range : undefined;
  const startedAt = Date.now();
  const cacheKey = createHash("sha256").update(targetURL.toString()).digest("hex");
  const cachePath = resolve(modelCacheDir, `${cacheKey}.glb`);
  const metadataPath = resolve(modelCacheDir, `${cacheKey}.json`);

  await appendRenderDiagnostic({
    event: "bridge.modelProxy.request",
    source: "bridge",
    data: {
      targetURL: summarizeURL(targetURL.toString()),
      requestedRange: range ? compactText(range, 80) : null,
      cacheKey: cacheKey.slice(0, 16)
    }
  });

  await mkdir(modelCacheDir, { recursive: true });
  let body = await readCachedModel(cachePath, modelCacheMaxAgeMs);
  let cacheStatus = "hit";

  if (!body) {
    cacheStatus = "miss";
    const download = await curlBinary({
      url: targetURL.toString(),
      userAgent: request.headers["user-agent"] || "Trouvenir/0.1 model proxy"
    });

    if (download.status < 200 || download.status >= 300) {
      await appendRenderDiagnostic({
        event: "bridge.modelProxy.downloadFailed",
        level: "error",
        source: "bridge",
        data: {
          targetURL: summarizeURL(targetURL.toString()),
          status: download.status,
          durationMs: Date.now() - startedAt
        }
      });
      throw new BridgeError(`Model download failed with HTTP ${download.status}`, download.status);
    }

    if (!download.body.byteLength) {
      throw new BridgeError("Model download returned an empty file", 502);
    }

    body = download.body;
    await writeFile(cachePath, body);
    await writeFile(metadataPath, JSON.stringify({
      createdAt: new Date().toISOString(),
      source: summarizeURL(targetURL.toString()),
      bytes: body.byteLength,
      magic: body.subarray(0, 4).toString("utf8")
    }, null, 2));
  }

  const magic = body.subarray(0, 4).toString("utf8");
  await appendRenderDiagnostic({
    event: "bridge.modelProxy.response",
    level: magic === "glTF" ? "info" : "warn",
    source: "bridge",
    data: {
      cacheStatus,
      bytes: body.byteLength,
      durationMs: Date.now() - startedAt,
      glbMagic: magic,
      requestedRange: range ? compactText(range, 80) : null
    }
  });

  response.writeHead(200, cleanObject({
    "Access-Control-Allow-Origin": "*",
    "Accept-Ranges": "none",
    "Cache-Control": "public, max-age=3600",
    "Content-Disposition": "inline; filename=\"trouvenir-model.glb\"",
    "Content-Length": String(body.byteLength),
    "Content-Type": "model/gltf-binary",
    "X-Trouvenir-Model-Cache": cacheStatus,
    "X-Trouvenir-Model-Bytes": String(body.byteLength)
  }));
  response.end(body);

  void cleanupModelCache();
}

async function curlJson({ method, url, headers, body, resolveHost }) {
  const args = [
    "-sS",
    "--connect-timeout",
    "20",
    "--max-time",
    "120",
    "-w",
    "\n%{http_code}",
    "-X",
    method
  ];

  if (resolveHost) {
    args.push("--resolve", resolveHost);
  }

  args.push(url);

  for (const [key, value] of Object.entries(headers)) {
    args.push("-H", `${key}: ${value}`);
  }

  if (body) {
    args.push("--data-binary", body);
  }

  const { stdout, stderr, exitCode } = await runCurl(args);
  if (exitCode !== 0) {
    throw new BridgeError(
      `Network request failed: ${stderr || `curl exited with ${exitCode}`}`,
      502,
      {
        hasHttpsProxy: Boolean(process.env.HTTPS_PROXY || process.env.https_proxy),
        hasHttpProxy: Boolean(process.env.HTTP_PROXY || process.env.http_proxy),
        resolveHost: resolveHost ?? null
      }
    );
  }

  const separator = stdout.lastIndexOf("\n");
  const rawBody = separator === -1 ? "" : stdout.slice(0, separator);
  const status = Number(separator === -1 ? stdout : stdout.slice(separator + 1));

  let payload;
  try {
    payload = rawBody ? JSON.parse(rawBody) : {};
  } catch {
    payload = { message: rawBody };
  }

  return { status, payload };
}

async function curlBinary({ url, userAgent }) {
  const args = [
    "-L",
    "-sS",
    "--connect-timeout",
    "20",
    "--max-time",
    "300",
    "-w",
    "\n%{http_code}",
    "-H",
    `User-Agent: ${userAgent || "Trouvenir/0.1 model proxy"}`,
    "-H",
    "Accept: model/gltf-binary,application/octet-stream,*/*"
  ];

  args.push(url);

  const { stdout, stderr, exitCode } = await runCurlBuffer(args);
  if (exitCode !== 0) {
    throw new BridgeError(
      `Model download failed: ${stderr || `curl exited with ${exitCode}`}`,
      502
    );
  }

  const separator = stdout.lastIndexOf(0x0a);
  if (separator === -1) {
    throw new BridgeError("Model download returned an invalid response", 502);
  }

  const body = stdout.subarray(0, separator);
  const status = Number(stdout.subarray(separator + 1).toString("utf8"));
  return { status, body };
}

function runCurl(args) {
  return new Promise((resolve) => {
    const child = spawn("/usr/bin/curl", args, {
      env: process.env,
      stdio: ["ignore", "pipe", "pipe"]
    });
    const stdout = [];
    const stderr = [];

    child.stdout.on("data", (chunk) => stdout.push(chunk));
    child.stderr.on("data", (chunk) => stderr.push(chunk));
    child.on("close", (exitCode) => {
      resolve({
        exitCode: exitCode ?? 1,
        stdout: Buffer.concat(stdout).toString("utf8"),
        stderr: Buffer.concat(stderr).toString("utf8").trim()
      });
    });
    child.on("error", (error) => {
      resolve({
        exitCode: 1,
        stdout: "",
        stderr: error.message
      });
    });
  });
}

function streamCurlBinary(url, response) {
  return new Promise((resolve) => {
    const child = spawn("/usr/bin/curl", [
      "-L",
      "--fail",
      "-sS",
      "--connect-timeout",
      "20",
      "--max-time",
      "300",
      url
    ], {
      env: process.env,
      stdio: ["ignore", "pipe", "pipe"]
    });

    const stderr = [];
    child.stdout.on("data", (chunk) => {
      response.write(chunk);
    });
    child.stderr.on("data", (chunk) => stderr.push(chunk));
    child.on("close", (exitCode) => {
      if (exitCode !== 0) {
        console.error(JSON.stringify({
          event: "tripo_model_proxy_failed",
          exitCode,
          error: Buffer.concat(stderr).toString("utf8")
        }));
      }
      response.end();
      resolve();
    });
  });
}

function runCurlBuffer(args) {
  return new Promise((resolve) => {
    const child = spawn("/usr/bin/curl", args, {
      env: process.env,
      stdio: ["ignore", "pipe", "pipe"]
    });
    const stdout = [];
    const stderr = [];

    child.stdout.on("data", (chunk) => stdout.push(chunk));
    child.stderr.on("data", (chunk) => stderr.push(chunk));
    child.on("close", (exitCode) => {
      resolve({
        exitCode: exitCode ?? 1,
        stdout: Buffer.concat(stdout),
        stderr: Buffer.concat(stderr).toString("utf8").trim()
      });
    });
    child.on("error", (error) => {
      resolve({
        exitCode: 1,
        stdout: Buffer.alloc(0),
        stderr: error.message
      });
    });
  });
}

async function readJson(request, maxBytes = 1_000_000) {
  const chunks = [];
  let byteLength = 0;
  for await (const chunk of request) {
    const buffer = Buffer.isBuffer(chunk) ? chunk : Buffer.from(chunk);
    byteLength += buffer.byteLength;
    if (byteLength > maxBytes) {
      throw new BridgeError("Request body is too large", 413);
    }
    chunks.push(buffer);
  }

  const raw = Buffer.concat(chunks).toString("utf8");
  if (!raw) {
    return {};
  }

  try {
    return JSON.parse(raw);
  } catch {
    throw new BridgeError("Request body must be valid JSON", 400);
  }
}

async function readResponseJson(response) {
  const text = await response.text();
  if (!text) {
    return {};
  }

  try {
    return JSON.parse(text);
  } catch {
    return { message: text };
  }
}

function sendJson(response, status, payload, headers = {}) {
  response.writeHead(status, {
    ...headers,
    "Content-Type": "application/json; charset=utf-8"
  });
  response.end(JSON.stringify(payload));
}

function sendError(response, error) {
  if (error instanceof BridgeError) {
    console.error(JSON.stringify({
      name: error.name,
      message: error.message,
      status: error.status,
      detail: error.detail
    }));
    void appendRenderDiagnostic({
      event: "bridge.error",
      level: "error",
      source: "bridge",
      data: {
        message: error.message,
        status: error.status,
        detail: error.detail
      }
    });
    sendJson(response, error.status, {
      error: error.message,
      detail: error.detail
    });
    return;
  }

  console.error(error);
  void appendRenderDiagnostic({
    event: "bridge.error",
    level: "error",
    source: "bridge",
    data: {
      message: error?.message ?? String(error)
    }
  });
  sendJson(response, 500, { error: "Internal server error" });
}

function corsHeaders() {
  return {
    "Access-Control-Allow-Origin": "*",
    "Access-Control-Allow-Methods": "GET,POST,OPTIONS",
    "Access-Control-Allow-Headers": "Content-Type"
  };
}

async function appendRenderDiagnostic(input) {
  const entry = sanitizeDiagnosticObject({
    ts: new Date().toISOString(),
    level: input.level || "info",
    source: input.source || "bridge",
    event: input.event || "bridge.event",
    session: input.session || input.sessionID || null,
    data: input.data || {}
  });

  await mkdir(diagnosticDir, { recursive: true });
  await rotateDiagnosticLogIfNeeded();
  await appendFile(diagnosticLogPath, `${JSON.stringify(entry)}\n`, "utf8");

  const now = Date.now();
  if (now - lastDiagnosticCleanupAt > 60_000) {
    lastDiagnosticCleanupAt = now;
    void cleanupDiagnosticLogs();
  }
}

async function appendAppDiagnostic(input) {
  const entry = sanitizeDiagnosticObject({
    ts: new Date().toISOString(),
    level: input.level || "info",
    source: input.source || "ios-app",
    event: input.event || "app.event",
    session: input.session || input.sessionID || null,
    call: input.call || null,
    data: input.data || {}
  });

  await mkdir(appDiagnosticDir, { recursive: true });
  await rotateAppDiagnosticLogIfNeeded();
  await appendFile(appDiagnosticLogPath, `${JSON.stringify(entry)}\n`, "utf8");

  const now = Date.now();
  if (now - lastAppDiagnosticCleanupAt > 60_000) {
    lastAppDiagnosticCleanupAt = now;
    void cleanupAppDiagnosticLogs();
  }
}

async function readRenderDiagnostics(limit) {
  let raw = "";
  try {
    raw = await readFile(diagnosticLogPath, "utf8");
  } catch {
    return { ok: true, path: diagnosticLogPath, entries: [] };
  }

  const entries = raw
    .trim()
    .split("\n")
    .filter(Boolean)
    .slice(-Math.max(1, Math.min(limit || 200, 1000)))
    .map((line) => {
      try {
        return JSON.parse(line);
      } catch {
        return { event: "diagnostic.parseError", raw: compactText(line, 260) };
      }
    });

  return { ok: true, path: diagnosticLogPath, entries };
}

async function readAppDiagnostics(limit) {
  let raw = "";
  try {
    raw = await readFile(appDiagnosticLogPath, "utf8");
  } catch {
    return { ok: true, path: appDiagnosticLogPath, entries: [] };
  }

  const entries = raw
    .trim()
    .split("\n")
    .filter(Boolean)
    .slice(-Math.max(1, Math.min(limit || 200, 1000)))
    .map((line) => {
      try {
        return JSON.parse(line);
      } catch {
        return { event: "diagnostic.parseError", raw: compactText(line, 260) };
      }
    });

  return { ok: true, path: appDiagnosticLogPath, entries };
}

async function rotateDiagnosticLogIfNeeded() {
  const current = await stat(diagnosticLogPath).catch(() => null);
  if (!current || current.size < diagnosticMaxBytes) {
    return;
  }

  for (let index = 4; index >= 1; index -= 1) {
    const from = `${diagnosticLogPath}.${index}`;
    const to = `${diagnosticLogPath}.${index + 1}`;
    try {
      await rename(from, to);
    } catch {
      // Older rotations may not exist.
    }
  }

  try {
    await rename(diagnosticLogPath, `${diagnosticLogPath}.1`);
  } catch {
    // A concurrent append can recreate the file first; losing one rotation is acceptable.
  }
}

async function rotateAppDiagnosticLogIfNeeded() {
  const current = await stat(appDiagnosticLogPath).catch(() => null);
  if (!current || current.size < appDiagnosticMaxBytes) {
    return;
  }

  for (let index = 4; index >= 1; index -= 1) {
    const from = `${appDiagnosticLogPath}.${index}`;
    const to = `${appDiagnosticLogPath}.${index + 1}`;
    try {
      await rename(from, to);
    } catch {
      // Older rotations may not exist.
    }
  }

  try {
    await rename(appDiagnosticLogPath, `${appDiagnosticLogPath}.1`);
  } catch {
    // A concurrent append can recreate the file first; losing one rotation is acceptable.
  }
}

async function cleanupDiagnosticLogs() {
  const files = await readdir(diagnosticDir, { withFileTypes: true }).catch(() => []);
  const now = Date.now();

  await Promise.all(files
    .filter((file) => file.isFile() && file.name.startsWith("render.ndjson."))
    .map(async (file) => {
      const path = resolve(diagnosticDir, file.name);
      const info = await stat(path).catch(() => null);
      if (!info) return;
      if (now - info.mtimeMs > diagnosticMaxAgeMs || file.name.endsWith(".5")) {
        await unlink(path).catch(() => {});
      }
    }));
}

async function cleanupAppDiagnosticLogs() {
  const files = await readdir(appDiagnosticDir, { withFileTypes: true }).catch(() => []);
  const now = Date.now();

  await Promise.all(files
    .filter((file) => file.isFile() && file.name.startsWith("app.ndjson."))
    .map(async (file) => {
      const path = resolve(appDiagnosticDir, file.name);
      const info = await stat(path).catch(() => null);
      if (!info) return;
      if (now - info.mtimeMs > appDiagnosticMaxAgeMs || file.name.endsWith(".5")) {
        await unlink(path).catch(() => {});
      }
    }));
}

async function readCachedModel(cachePath, maxAgeMs) {
  const info = await stat(cachePath).catch(() => null);
  if (!info || info.size <= 0 || Date.now() - info.mtimeMs > maxAgeMs) {
    return null;
  }

  return readFile(cachePath);
}

async function cleanupModelCache() {
  const now = Date.now();
  if (now - lastModelCacheCleanupAt < 60_000) {
    return;
  }
  lastModelCacheCleanupAt = now;

  const files = await readdir(modelCacheDir, { withFileTypes: true }).catch(() => []);
  const entries = [];

  for (const file of files) {
    if (!file.isFile()) continue;
    const path = resolve(modelCacheDir, file.name);
    const info = await stat(path).catch(() => null);
    if (!info) continue;
    if (now - info.mtimeMs > modelCacheMaxAgeMs) {
      await unlink(path).catch(() => {});
      continue;
    }
    entries.push({ path, size: info.size, mtimeMs: info.mtimeMs });
  }

  let totalBytes = entries.reduce((sum, entry) => sum + entry.size, 0);
  for (const entry of entries.sort((a, b) => a.mtimeMs - b.mtimeMs)) {
    if (totalBytes <= modelCacheMaxBytes) break;
    await unlink(entry.path).catch(() => {});
    totalBytes -= entry.size;
  }
}

function isAllowedTripoModelHost(hostname) {
  const host = hostname.toLowerCase();
  const defaults = [
    "tripo3d.com",
    ".tripo3d.com",
    "tripo3d.ai",
    ".tripo3d.ai"
  ];
  const allowed = defaults.concat(configuredAllowedModelHosts);
  return allowed.some((pattern) => {
    if (pattern.startsWith(".")) {
      return host.endsWith(pattern);
    }
    return host === pattern || host.endsWith(`.${pattern}`);
  });
}

function summarizeURL(value) {
  try {
    const url = value instanceof URL ? value : new URL(String(value));
    return {
      scheme: url.protocol.replace(":", ""),
      host: url.hostname,
      path: compactText(url.pathname, 220),
      hasQuery: Boolean(url.search),
      hash: createHash("sha256").update(url.toString()).digest("hex").slice(0, 16)
    };
  } catch {
    return compactText(value, 220);
  }
}

function sanitizeDiagnosticObject(value, depth = 0, keyHint = "") {
  if (depth > 5) {
    return "[depth-limit]";
  }

  if (value === null || value === undefined) {
    return null;
  }

  if (typeof value === "string") {
    if (/url$/i.test(keyHint) || keyHint.toLowerCase().includes("url")) {
      return summarizeURL(value);
    }
    if (/api[_-]?key|token|authorization|secret|password/i.test(keyHint)) {
      return "[redacted]";
    }
    return compactText(value, 700);
  }

  if (typeof value === "number" || typeof value === "boolean") {
    return value;
  }

  if (Array.isArray(value)) {
    return value
      .slice(0, 24)
      .map((entry) => sanitizeDiagnosticObject(entry, depth + 1, keyHint));
  }

  if (typeof value === "object") {
    return Object.fromEntries(Object.entries(value)
      .slice(0, 40)
      .map(([key, entry]) => [compactText(key, 80), sanitizeDiagnosticObject(entry, depth + 1, key)]));
  }

  return compactText(String(value), 220);
}

function cleanObject(value) {
  return Object.fromEntries(Object.entries(value).filter(([, entry]) => entry !== undefined));
}

function sleep(ms) {
  return new Promise((resolve) => setTimeout(resolve, ms));
}

function retryDelayMs(attempt) {
  return Math.min(12_000, 1_000 * (2 ** Math.max(0, attempt - 1)));
}

function isRetryableBridgeError(error) {
  if (!(error instanceof BridgeError)) {
    return false;
  }

  if ([408, 429, 500, 502, 503, 504].includes(error.status)) {
    return true;
  }

  return /network request failed|connection reset|recv failure|timed out|timeout/i.test(error.message);
}

function summarizeTaskPayload(payload) {
  return {
    type: payload.type,
    model_version: payload.model_version,
    promptLength: typeof payload.prompt === "string" ? payload.prompt.length : 0,
    negativePromptLength: typeof payload.negative_prompt === "string" ? payload.negative_prompt.length : 0,
    texture: payload.texture,
    pbr: payload.pbr,
    texture_quality: payload.texture_quality,
    face_limit: payload.face_limit,
    keys: Object.keys(payload).sort()
  };
}

function compactText(value, maxLength) {
  const compacted = String(value ?? "")
    .replace(/\s+/g, " ")
    .trim();

  if (compacted.length <= maxLength) {
    return compacted;
  }

  return compacted.slice(0, maxLength).trim();
}

function parseJsonObject(content) {
  if (typeof content !== "string" || !content.trim()) {
    throw new BridgeError("DeepSeek returned an empty response", 502);
  }

  const stripped = content
    .trim()
    .replace(/^```(?:json)?/i, "")
    .replace(/```$/i, "")
    .trim();

  try {
    return JSON.parse(stripped);
  } catch {
    const start = stripped.indexOf("{");
    const end = stripped.lastIndexOf("}");
    if (start !== -1 && end > start) {
      try {
        return JSON.parse(stripped.slice(start, end + 1));
      } catch {
        // Fall through to the structured error below.
      }
    }
  }

  throw new BridgeError("DeepSeek returned invalid JSON", 502, {
    content: compactText(stripped, 500)
  });
}

function messageContent(message) {
  const content = message?.content;
  if (typeof content === "string") {
    return content;
  }

  if (Array.isArray(content)) {
    return content
      .map((part) => typeof part === "string" ? part : part?.text ?? "")
      .join("\n")
      .trim();
  }

  return "";
}

function fallbackTravelMemory(input) {
  const destination = compactText(input.destination, 40) ||
    inferDestination(input.prompt) ||
    "新的目的地";
  const prompt = compactText(input.prompt, 120);
  const companions = compactText(input.companions, 30) ||
    inferCompanions(input.prompt) ||
    "独自旅行";

  return {
    title: compactText(input.tripTitle, 30) || prompt || "一段新的旅行记忆",
    destination,
    identityTitle: `${destination}收藏家`,
    companions,
    walkingDistance: "待补充",
    duration: "待补充",
    storyTitle: fallbackStoryTitle({
      destination,
      title: input.tripTitle,
      story: input.feeling,
      prompt: input.prompt
    }),
    story: compactText(input.feeling || input.prompt, 180) ||
      "这段旅程留下了一个值得收藏的瞬间。",
    accentKey: "teal",
    souvenirs: [
      fallbackSouvenir(destination, 0),
      fallbackSouvenir(destination, 1),
      fallbackSouvenir(destination, 2),
      fallbackSouvenir(destination, 3)
    ]
  };
}

function normalizeTravelMemory(memory, input) {
  const destination = compactText(memory.destination, 40) ||
    compactText(input.destination, 40) ||
    inferDestination(input.prompt) ||
    "新的目的地";
  const title = compactText(memory.title, 30) ||
    compactText(input.tripTitle, 30) ||
    compactText(input.prompt, 18) ||
    "一段新的旅行记忆";
  const companions = compactText(memory.companions, 30) ||
    compactText(input.companions, 30) ||
    inferCompanions(input.prompt) ||
    "独自旅行";
  const story = compactText(memory.story, 260) ||
    compactText(input.feeling || input.prompt, 180) ||
    "这段旅程留下了一个值得反复想起的瞬间。";
  const storyTitle = normalizeStoryTitle(memory.storyTitle, {
    title,
    destination,
    story,
    prompt: input.prompt
  });
  const souvenirs = Array.isArray(memory.souvenirs) ? memory.souvenirs.slice(0, 4) : [];

  while (souvenirs.length < 4) {
    const fallback = fallbackSouvenir(destination, souvenirs.length);
    souvenirs.push(fallback);
  }

  return {
    title,
    destination,
    identityTitle: compactText(memory.identityTitle, 36) || `${destination}收藏家`,
    companions,
    walkingDistance: compactText(memory.walkingDistance, 16) || "42 公里",
    duration: compactText(memory.duration, 16) || "5 天 4 晚",
    storyTitle,
    story,
    accentKey: oneOf(memory.accentKey, ["teal", "coral", "gold", "blue"], "teal"),
    souvenirs: souvenirs.map((item, index) => ({
      name: compactText(item?.name, 24) || fallbackSouvenir(destination, index).name,
      caption: compactText(item?.caption, 44) || fallbackSouvenir(destination, index).caption,
      symbol: compactText(item?.symbol, 28) || fallbackSouvenir(destination, index).symbol,
      colorKey: oneOf(item?.colorKey, ["teal", "coral", "gold", "blue"], ["teal", "gold", "coral", "blue"][index % 4])
    }))
  };
}

function fallbackSouvenir(destination, index) {
  const items = [
    { name: `${destination}身份卡`, caption: "属于这次旅程的身份", symbol: "lanyardcard", colorKey: "teal" },
    { name: `${destination}纪念章`, caption: "把最重要的瞬间留下", symbol: "seal.fill", colorKey: "gold" },
    { name: `${destination}故事卡`, caption: "多年后还能重新读到", symbol: "text.book.closed", colorKey: "coral" },
    { name: `${destination}记忆海报`, caption: "适合保存和分享", symbol: "photo.artframe", colorKey: "blue" }
  ];
  return items[index % items.length];
}

function normalizeStoryTitle(rawTitle, context) {
  const cleaned = compactText(rawTitle, 36)
    .replace(/[《》"'“”]/g, "")
    .replace(/\s+/g, "");
  const weak = !cleaned ||
    cleaned.length > 18 ||
    /[，,。.!！?？；;、]/.test(cleaned) ||
    /[0-9０-９]/.test(cleaned) ||
    /小时|公里|天|晚|终于|最后|终$/.test(cleaned) ||
    compactText(context.prompt, 80).includes(cleaned);

  const title = weak ? fallbackStoryTitle(context) : cleaned;
  return `《${compactText(title, 16)}》`;
}

function fallbackStoryTitle(context) {
  const combined = `${context.destination} ${context.title} ${context.story} ${context.prompt}`;
  if (/富士山|河口湖|登顶|爬山|山顶/.test(combined)) return "云开见富士";
  if (/旧金山|金门|Golden Gate|San Francisco/i.test(combined)) return "雾里的金门桥";
  if (/海岛|海边|海风|沙滩|island|beach|Hamilton/i.test(combined)) return "海风抵达时";
  const place = compactText(context.destination, 6);
  return place ? `${place}的心跳` : "那一刻的心跳";
}

function oneOf(value, allowed, fallback) {
  return allowed.includes(value) ? value : fallback;
}

function tripoResolveHost() {
  const resolvedIP = String(process.env.TRIPO_RESOLVE_IP ?? "").trim();
  if (!resolvedIP) {
    return undefined;
  }

  try {
    const hostname = new URL(tripoBaseURL).hostname;
    return `${hostname}:443:${resolvedIP}`;
  } catch {
    return `api.tripo3d.ai:443:${resolvedIP}`;
  }
}

function inferDestination(text) {
  const value = String(text ?? "");
  if (value.includes("富士山") || value.includes("河口湖")) return "富士山";
  if (value.includes("旧金山") || value.includes("金门")) return "旧金山";
  if (value.includes("东京")) return "东京";
  if (/hamilton/i.test(value)) return "Hamilton Island";
  return "";
}

function inferCompanions(text) {
  const value = String(text ?? "");
  if (value.includes("弟弟")) return "弟弟";
  if (value.includes("朋友")) return "朋友";
  if (value.includes("家人")) return "家人";
  return "";
}

function loadEnv() {
  let raw;
  try {
    raw = readFileSync(envPath, "utf8");
  } catch {
    return;
  }

  for (const line of raw.split(/\r?\n/)) {
    const trimmed = line.trim();
    if (!trimmed || trimmed.startsWith("#")) {
      continue;
    }

    const separator = trimmed.indexOf("=");
    if (separator === -1) {
      continue;
    }

    const key = trimmed.slice(0, separator).trim();
    const value = trimmed.slice(separator + 1).trim().replace(/^['"]|['"]$/g, "");
    if (!process.env[key]) {
      process.env[key] = value;
    }
  }
}

class BridgeError extends Error {
  constructor(message, status = 500, detail = undefined) {
    super(message);
    this.name = "BridgeError";
    this.status = status;
    this.detail = detail;
  }
}
