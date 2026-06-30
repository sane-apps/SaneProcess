#!/usr/bin/env node
import { spawn, execFileSync } from "node:child_process";
import fs from "node:fs";
import os from "node:os";
import path from "node:path";
import process from "node:process";

const HOME_DIR = os.homedir();
const GITHUB_SERVER_PATH = path.join(
  HOME_DIR,
  ".npm-global",
  "lib",
  "node_modules",
  "@modelcontextprotocol",
  "server-github",
  "dist",
  "index.js",
);
const GITHUB_SERVER_PACKAGE = "@modelcontextprotocol/server-github";
const GITHUB_SERVER_VERSION = "2025.4.8";
const GITHUB_SERVER_PATH_CANDIDATES = [
  process.env.SANE_GITHUB_MCP_SERVER_PATH,
  GITHUB_SERVER_PATH,
  "/opt/homebrew/lib/node_modules/@modelcontextprotocol/server-github/dist/index.js",
  "/usr/local/lib/node_modules/@modelcontextprotocol/server-github/dist/index.js",
].filter(Boolean);

const GH_BIN_CANDIDATES = [
  "gh",
  "/opt/homebrew/bin/gh",
  "/usr/local/bin/gh",
  "/usr/bin/gh",
];
const LOCAL_TOKEN_FILE = path.join(os.homedir(), ".codex", "secrets", "github_token");

function resolveServerLaunch() {
  for (const candidate of GITHUB_SERVER_PATH_CANDIDATES) {
    if (fs.existsSync(candidate)) {
      return { command: process.execPath, args: [candidate] };
    }
  }

  console.error(
    `GitHub MCP bridge: ${GITHUB_SERVER_PACKAGE}@${GITHUB_SERVER_VERSION} is not installed locally. ` +
      "Install it with `npm install -g @modelcontextprotocol/server-github@2025.4.8`; refusing dynamic npx fallback while holding a GitHub token.",
  );
  process.exit(78);
}

function tokenFromGhCli() {
  for (const bin of GH_BIN_CANDIDATES) {
    try {
      const token = execFileSync(bin, ["auth", "token"], {
        encoding: "utf8",
        stdio: ["ignore", "pipe", "ignore"],
      }).trim();
      if (token) return token;
    } catch {
      // Try next candidate.
    }
  }
  return null;
}

function tokenFromGhHostsFile() {
  try {
    const hostsPath = path.join(os.homedir(), ".config", "gh", "hosts.yml");
    const yaml = fs.readFileSync(hostsPath, "utf8");
    const match = yaml.match(/^\s*oauth_token:\s*([^\s]+)\s*$/m);
    return match?.[1] ?? null;
  } catch {
    return null;
  }
}

function tokenFromLocalFile() {
  try {
    const token = fs.readFileSync(LOCAL_TOKEN_FILE, "utf8").trim();
    return token || null;
  } catch {
    return null;
  }
}

function resolveToken() {
  if (process.env.GITHUB_PERSONAL_ACCESS_TOKEN?.trim()) {
    return process.env.GITHUB_PERSONAL_ACCESS_TOKEN.trim();
  }
  if (process.env.GITHUB_TOKEN?.trim()) {
    return process.env.GITHUB_TOKEN.trim();
  }

  const localFileToken = tokenFromLocalFile();
  if (localFileToken) return localFileToken;

  const ghCliToken = tokenFromGhCli();
  if (ghCliToken) return ghCliToken;

  const ghHostsToken = tokenFromGhHostsFile();
  if (ghHostsToken) return ghHostsToken;

  return null;
}

const launch = resolveServerLaunch();
const token = resolveToken();
if (!token) {
  console.error("GitHub MCP bridge: no GitHub token found. Starting without auth token.");
}

function childEnvironment(resolvedToken) {
  const childEnv = {
    HOME: HOME_DIR,
    PATH: [
      path.dirname(process.execPath),
      path.join(HOME_DIR, ".local", "bin"),
      "/opt/homebrew/bin",
      "/usr/local/bin",
      "/usr/bin",
      "/bin",
      "/usr/sbin",
      "/sbin",
    ].join(":"),
    TMPDIR: process.env.TMPDIR || os.tmpdir(),
    USER: process.env.USER || os.userInfo().username,
    LOGNAME: process.env.LOGNAME || process.env.USER || os.userInfo().username,
    LANG: process.env.LANG || "en_US.UTF-8",
  };

  if (process.env.SSL_CERT_FILE) childEnv.SSL_CERT_FILE = process.env.SSL_CERT_FILE;
  if (process.env.NODE_EXTRA_CA_CERTS) childEnv.NODE_EXTRA_CA_CERTS = process.env.NODE_EXTRA_CA_CERTS;
  if (resolvedToken) {
    childEnv.GITHUB_PERSONAL_ACCESS_TOKEN = resolvedToken;
    childEnv.GITHUB_TOKEN = resolvedToken;
  }
  return childEnv;
}

const childEnv = childEnvironment(token);

const child = spawn(launch.command, launch.args, {
  stdio: ["pipe", "pipe", "pipe"],
  env: childEnv,
});

child.stderr.on("data", (chunk) => {
  process.stderr.write(chunk);
});

let parentBuffer = Buffer.alloc(0);
let childBuffer = Buffer.alloc(0);

function tryReadMessage(buffer) {
  if (buffer.length === 0) return { message: null, rest: buffer };

  const crlfHeaderEnd = buffer.indexOf("\r\n\r\n");
  const lfHeaderEnd = buffer.indexOf("\n\n");
  let headerEnd = -1;
  let delimiterLength = 0;

  if (crlfHeaderEnd !== -1 && (lfHeaderEnd === -1 || crlfHeaderEnd < lfHeaderEnd)) {
    headerEnd = crlfHeaderEnd;
    delimiterLength = 4;
  } else if (lfHeaderEnd !== -1) {
    headerEnd = lfHeaderEnd;
    delimiterLength = 2;
  }

  if (headerEnd !== -1) {
    const headerBlock = buffer.subarray(0, headerEnd).toString("utf8");
    const lines = headerBlock.split(/\r?\n/);
    let contentLength = null;

    for (const line of lines) {
      const m = /^content-length\s*:\s*(\d+)\s*$/i.exec(line);
      if (m) {
        contentLength = Number.parseInt(m[1], 10);
        break;
      }
    }

    if (contentLength !== null) {
      const bodyStart = headerEnd + delimiterLength;
      const bodyEnd = bodyStart + contentLength;
      if (buffer.length < bodyEnd) return { message: null, rest: buffer };

      const body = buffer.subarray(bodyStart, bodyEnd).toString("utf8");
      return { message: body, rest: buffer.subarray(bodyEnd) };
    }
  }

  const newlineIndex = buffer.indexOf("\n");
  if (newlineIndex === -1) return { message: null, rest: buffer };

  const line = buffer.subarray(0, newlineIndex).toString("utf8").replace(/\r$/, "");
  return { message: line, rest: buffer.subarray(newlineIndex + 1) };
}

function encodeFramed(jsonText) {
  const bytes = Buffer.byteLength(jsonText, "utf8");
  return `Content-Length: ${bytes}\r\n\r\n${jsonText}`;
}

process.stdin.on("data", (chunk) => {
  parentBuffer = Buffer.concat([parentBuffer, chunk]);

  while (true) {
    const parsed = tryReadMessage(parentBuffer);
    if (parsed.message === null) break;
    parentBuffer = parsed.rest;

    const trimmed = parsed.message.trim();
    if (!trimmed) continue;

    let normalized;
    try {
      normalized = JSON.stringify(JSON.parse(trimmed));
    } catch (err) {
      console.error(`GitHub MCP bridge: dropping invalid parent JSON: ${err}`);
      continue;
    }

    child.stdin.write(`${normalized}\n`);
  }
});

child.stdout.on("data", (chunk) => {
  childBuffer = Buffer.concat([childBuffer, chunk]);

  while (true) {
    const parsed = tryReadMessage(childBuffer);
    if (parsed.message === null) break;
    childBuffer = parsed.rest;

    const trimmed = parsed.message.trim();
    if (!trimmed) continue;

    let normalized;
    try {
      normalized = JSON.stringify(JSON.parse(trimmed));
    } catch (err) {
      console.error(`GitHub MCP bridge: dropping invalid child JSON: ${err}`);
      continue;
    }

    process.stdout.write(encodeFramed(normalized));
  }
});

child.on("exit", (code, signal) => {
  if (signal) {
    console.error(`GitHub MCP bridge: child exited via signal ${signal}`);
    process.exit(1);
  }
  process.exit(code ?? 0);
});

child.on("error", (err) => {
  console.error(`GitHub MCP bridge: failed to spawn child: ${err}`);
  process.exit(1);
});

process.on("SIGINT", () => child.kill("SIGINT"));
process.on("SIGTERM", () => child.kill("SIGTERM"));

process.stdin.resume();
