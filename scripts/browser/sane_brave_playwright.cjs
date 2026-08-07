#!/usr/bin/env node
/**
 * Canonical Playwright launch policy for visible Brave QA on the Mac Mini.
 *
 * The helper keeps Playwright from injecting --no-sandbox, suppresses crash
 * recovery UI in disposable profiles, and closes tracked contexts on signals.
 */
const fs = require("fs");
const path = require("path");

const BRAVE_EXECUTABLE = "/Applications/Brave Browser.app/Contents/MacOS/Brave Browser";
const CLEAN_EXIT_PREFERENCE = "brave.dont_ask_for_crash_reporting";
const REQUIRED_ARGS = [
  "--disable-crash-reporter",
  "--disable-session-crashed-bubble",
  "--noerrdialogs",
  "--no-first-run",
  "--no-default-browser-check",
];
const trackedContexts = new Set();
let signalHandlersInstalled = false;

function readJson(file) {
  try {
    return JSON.parse(fs.readFileSync(file, "utf8"));
  } catch (_) {
    return {};
  }
}

function writeJson(file, value) {
  fs.mkdirSync(path.dirname(file), { recursive: true });
  fs.writeFileSync(file, `${JSON.stringify(value)}\n`, { mode: 0o600 });
}

function assertIsolatedProfile(userDataDir) {
  const resolved = path.resolve(userDataDir);
  const realBraveRoot = path.join(
    process.env.HOME || "",
    "Library/Application Support/BraveSoftware/Brave-Browser"
  );
  if (!resolved.startsWith("/tmp/brave-") || resolved.startsWith(realBraveRoot)) {
    throw new Error(
      `Visible Brave QA requires an isolated /tmp/brave-* profile, got ${resolved}`
    );
  }
  return resolved;
}

function prepareIsolatedProfile(userDataDir) {
  const resolved = assertIsolatedProfile(userDataDir);
  const preferencesFile = path.join(resolved, "Default", "Preferences");
  const preferences = readJson(preferencesFile);
  preferences.profile = {
    ...(preferences.profile || {}),
    exit_type: "Normal",
    exited_cleanly: true,
  };
  preferences.brave = {
    ...(preferences.brave || {}),
    dont_ask_for_crash_reporting: true,
  };
  writeJson(preferencesFile, preferences);
  return resolved;
}

function braveLaunchOptions(options = {}) {
  const args = [...(options.args || []), ...REQUIRED_ARGS]
    .filter((arg) => arg !== "--no-sandbox")
    .filter((arg, index, all) => all.indexOf(arg) === index);
  const ignoreDefaultArgs = [
    ...(Array.isArray(options.ignoreDefaultArgs) ? options.ignoreDefaultArgs : []),
    "--no-sandbox",
  ].filter((arg, index, all) => all.indexOf(arg) === index);

  if (args.includes("--no-sandbox") || !ignoreDefaultArgs.includes("--no-sandbox")) {
    throw new Error("Brave safety invariant failed: --no-sandbox would reach the browser");
  }

  return {
    ...options,
    executablePath: options.executablePath || BRAVE_EXECUTABLE,
    args,
    ignoreDefaultArgs,
  };
}

async function closeTrackedContexts() {
  const contexts = [...trackedContexts];
  trackedContexts.clear();
  await Promise.allSettled(contexts.map((context) => context.close()));
}

function installSignalHandlers() {
  if (signalHandlersInstalled) return;
  signalHandlersInstalled = true;
  for (const [signal, exitCode] of [["SIGINT", 130], ["SIGTERM", 143]]) {
    process.once(signal, async () => {
      await closeTrackedContexts();
      process.exitCode = exitCode;
    });
  }
}

async function launchSaneBravePersistentContext(chromium, userDataDir, options = {}) {
  const isolatedProfile = prepareIsolatedProfile(userDataDir);
  const launchOptions = braveLaunchOptions(options);
  installSignalHandlers();
  const context = await chromium.launchPersistentContext(isolatedProfile, launchOptions);
  trackedContexts.add(context);
  context.once("close", () => trackedContexts.delete(context));
  return context;
}

async function closeSaneBraveContext(context) {
  if (!context) return;
  trackedContexts.delete(context);
  await context.close().catch(() => {});
}

module.exports = {
  BRAVE_EXECUTABLE,
  CLEAN_EXIT_PREFERENCE,
  assertIsolatedProfile,
  braveLaunchOptions,
  closeSaneBraveContext,
  launchSaneBravePersistentContext,
  prepareIsolatedProfile,
};
