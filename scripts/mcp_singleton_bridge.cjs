#!/usr/bin/env node
const fs = require('fs');
const http = require('http');
const os = require('os');
const path = require('path');
const process = require('process');
const { spawnSync } = require('child_process');
const { randomUUID } = require('crypto');

const SCRIPT_PATH = fs.realpathSync(__filename);
const HOME = os.homedir();
const NODE_EXECUTABLE = process.execPath;
const LOG_DIR = path.join(HOME, 'Library', 'Logs', 'SaneApps', 'mcp-singleton');
const PLIST_DIR = path.join(HOME, 'Library', 'LaunchAgents');
const PLIST_LABEL_PREFIX = 'com.saneapps.mcp-singleton';

function unique(values) {
  return [...new Set(values.filter(Boolean))];
}

function homePath(...parts) {
  return path.join(HOME, ...parts);
}

function firstExecutable(candidates) {
  for (const candidate of candidates) {
    if (!candidate || !path.isAbsolute(candidate)) {
      continue;
    }
    try {
      fs.accessSync(candidate, fs.constants.X_OK);
      return candidate;
    } catch {}
  }
  return candidates.find(Boolean);
}

const NPX_EXECUTABLE = firstExecutable([
  path.join(path.dirname(NODE_EXECUTABLE), 'npx'),
  '/opt/homebrew/bin/npx',
  '/usr/local/bin/npx',
  'npx',
]);
const UVX_EXECUTABLE = firstExecutable([
  homePath('.local', 'bin', 'uvx'),
  '/opt/homebrew/bin/uvx',
  '/usr/local/bin/uvx',
  'uvx',
]);
const BACKEND_PATH = unique([
  path.dirname(NODE_EXECUTABLE),
  homePath('.local', 'bin'),
  '/opt/homebrew/bin',
  '/usr/local/bin',
  '/usr/bin',
  '/bin',
  '/usr/sbin',
  '/sbin',
  process.env.PATH,
]).join(':');

function backendEnv(spec) {
  return {
    ...process.env,
    HOME,
    PATH: BACKEND_PATH,
    ...(spec.env || {}),
  };
}

const SERVER_SPECS = {
  'apple-docs': {
    port: 37911,
    command: NPX_EXECUTABLE,
    args: ['-y', '@mweinbach/apple-docs-mcp@1.3.1'],
  },
  'macos-automator': {
    port: 37913,
    command: NPX_EXECUTABLE,
    args: ['-y', '@steipete/macos-automator-mcp@0.4.1'],
  },
  memory: {
    port: 37914,
    command: NODE_EXECUTABLE,
    args: [homePath('SaneApps', 'infra', 'SaneProcess', 'scripts', 'mcp-memory-enhanced', 'server.mjs')],
    env: {
      MEMORY_FILE_PATH: homePath('.claude', 'memory', 'knowledge-graph.jsonl'),
    },
  },
  serena: {
    port: 37917,
    command: UVX_EXECUTABLE,
    args: [
      '--from',
      'git+https://github.com/oraios/serena',
      'serena',
      'start-mcp-server',
      '--context',
      'claude-code',
      '--project-from-cwd',
    ],
    cwd: homePath('SaneApps'),
    env: {
      ENABLE_TOOL_SEARCH: 'true',
    },
  },
};

function npmRootCandidates() {
  const roots = [
    homePath('.npm-global', 'lib', 'node_modules'),
    '/opt/homebrew/lib/node_modules',
    '/usr/local/lib/node_modules',
  ];
  for (const npm of [path.join(path.dirname(NODE_EXECUTABLE), 'npm'), '/opt/homebrew/bin/npm', '/usr/local/bin/npm', 'npm']) {
    const res = spawnSync(npm, ['root', '-g'], { encoding: 'utf8' });
    if (res.status === 0) {
      roots.push((res.stdout || '').trim());
    }
  }
  return unique(roots);
}

const SDK_BASE_CANDIDATES = npmRootCandidates().flatMap((root) => [
  path.join(root, '@modelcontextprotocol', 'sdk', 'dist', 'cjs'),
  path.join(root, '@modelcontextprotocol', 'server-memory', 'node_modules', '@modelcontextprotocol', 'sdk', 'dist', 'cjs'),
  path.join(root, '@steipete', 'macos-automator-mcp', 'node_modules', '@modelcontextprotocol', 'sdk', 'dist', 'cjs'),
  path.join(root, '@mweinbach', 'apple-docs-mcp', 'node_modules', '@modelcontextprotocol', 'sdk', 'dist', 'cjs'),
]);

let Client;
let StdioClientTransport;
let Server;
let StreamableHTTPServerTransport;
let CallToolRequestSchema;
let CompleteRequestSchema;
let ErrorCode;
let GetPromptRequestSchema;
let ListPromptsRequestSchema;
let ListResourcesRequestSchema;
let ListResourceTemplatesRequestSchema;
let ListToolsRequestSchema;
let McpError;
let ReadResourceRequestSchema;
let SubscribeRequestSchema;
let UnsubscribeRequestSchema;

function resolveSdkBase() {
  for (const candidate of SDK_BASE_CANDIDATES) {
    if (fs.existsSync(path.join(candidate, 'client', 'index.js'))) {
      return candidate;
    }
  }
  throw new Error('Unable to locate @modelcontextprotocol/sdk runtime');
}

function loadSdkRuntime() {
  if (Client) {
    return;
  }

  const sdkBase = resolveSdkBase();
  ({ Client } = require(path.join(sdkBase, 'client', 'index.js')));
  ({ StdioClientTransport } = require(path.join(sdkBase, 'client', 'stdio.js')));
  ({ Server } = require(path.join(sdkBase, 'server', 'index.js')));
  ({ StreamableHTTPServerTransport } = require(path.join(sdkBase, 'server', 'streamableHttp.js')));
  ({
    CallToolRequestSchema,
    CompleteRequestSchema,
    ErrorCode,
    GetPromptRequestSchema,
    ListPromptsRequestSchema,
    ListResourcesRequestSchema,
    ListResourceTemplatesRequestSchema,
    ListToolsRequestSchema,
    McpError,
    ReadResourceRequestSchema,
    SubscribeRequestSchema,
    UnsubscribeRequestSchema,
  } = require(path.join(sdkBase, 'types.js')));
}

function specFor(name) {
  const spec = SERVER_SPECS[name];
  if (!spec) {
    throw new Error(`Unknown MCP singleton server: ${name}`);
  }
  return {
    name,
    url: `http://127.0.0.1:${spec.port}/mcp`,
    healthUrl: `http://127.0.0.1:${spec.port}/healthz`,
    ...spec,
  };
}

function allSpecs() {
  return Object.keys(SERVER_SPECS)
    .sort()
    .map((name) => specFor(name));
}

function plistLabel(name) {
  return `${PLIST_LABEL_PREFIX}.${name}`;
}

function plistPath(name) {
  return path.join(PLIST_DIR, `${plistLabel(name)}.plist`);
}

function plistXml(spec) {
  const outLog = path.join(LOG_DIR, `${spec.name}.out.log`);
  const errLog = path.join(LOG_DIR, `${spec.name}.err.log`);
  return `<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key>
  <string>${plistLabel(spec.name)}</string>
  <key>ProgramArguments</key>
  <array>
    <string>${process.execPath}</string>
    <string>${SCRIPT_PATH}</string>
    <string>serve</string>
    <string>${spec.name}</string>
  </array>
  <key>RunAtLoad</key>
  <true/>
  <key>KeepAlive</key>
  <true/>
  <key>WorkingDirectory</key>
  <string>${HOME}</string>
  <key>StandardOutPath</key>
  <string>${outLog}</string>
  <key>StandardErrorPath</key>
  <string>${errLog}</string>
</dict>
</plist>
`;
}

function expandTargets(name) {
  if (!name || name === 'all') {
    return allSpecs();
  }
  return [specFor(name)];
}

function launchctlDomain() {
  return `gui/${process.getuid()}`;
}

function launchctlLabel(spec) {
  return `${launchctlDomain()}/${plistLabel(spec.name)}`;
}

function runLaunchctl(args, allowFailure = false) {
  const result = spawnSync('/bin/launchctl', args, { encoding: 'utf8' });
  if (result.status !== 0 && !allowFailure) {
    const detail = (result.stderr || result.stdout || `launchctl ${args.join(' ')} failed`).trim();
    throw new Error(detail);
  }
  return result;
}

function installAgents(name) {
  fs.mkdirSync(LOG_DIR, { recursive: true });
  fs.mkdirSync(PLIST_DIR, { recursive: true });

  for (const spec of expandTargets(name)) {
    const targetPath = plistPath(spec.name);
    fs.writeFileSync(targetPath, plistXml(spec), 'utf8');
    runLaunchctl(['bootout', launchctlDomain(), targetPath], true);
    runLaunchctl(['bootstrap', launchctlDomain(), targetPath]);
    runLaunchctl(['enable', launchctlLabel(spec)], true);
    console.log(`installed ${spec.name}\t${targetPath}`);
  }
}

function uninstallAgents(name) {
  for (const spec of expandTargets(name)) {
    const targetPath = plistPath(spec.name);
    runLaunchctl(['bootout', launchctlDomain(), targetPath], true);
    if (fs.existsSync(targetPath)) {
      fs.unlinkSync(targetPath);
    }
    console.log(`uninstalled ${spec.name}\t${targetPath}`);
  }
}

function createBridgeCapabilities(client) {
  const backend = client.getServerCapabilities() || {};
  const caps = {};
  if (backend.tools) {
    caps.tools = { listChanged: !!backend.tools.listChanged };
  }
  if (backend.resources) {
    caps.resources = {
      listChanged: !!backend.resources.listChanged,
      subscribe: !!backend.resources.subscribe,
    };
  }
  if (backend.prompts) {
    caps.prompts = { listChanged: !!backend.prompts.listChanged };
  }
  if (backend.completions) {
    caps.completions = {};
  }
  return caps;
}

function attachHandler(server, schema, handler) {
  server.setRequestHandler(schema, async (request, extra) => {
    try {
      return await handler(request, extra);
    } catch (error) {
      if (error instanceof McpError) {
        throw error;
      }
      const message = error && error.message ? error.message : String(error);
      throw new McpError(ErrorCode.InternalError, message);
    }
  });
}

function createBridgeServer(spec, client) {
  const server = new Server(
    {
      name: `${spec.name}-singleton-bridge`,
      version: '1.0.0',
    },
    {
      capabilities: createBridgeCapabilities(client),
    }
  );

  attachHandler(server, ListToolsRequestSchema, (request) => client.listTools(request.params));
  attachHandler(server, CallToolRequestSchema, (request) => client.callTool(request.params));

  const backendCaps = client.getServerCapabilities() || {};
  if (backendCaps.resources) {
    attachHandler(server, ListResourcesRequestSchema, (request) => client.listResources(request.params));
    attachHandler(server, ReadResourceRequestSchema, (request) => client.readResource(request.params));
    attachHandler(server, ListResourceTemplatesRequestSchema, (request) => client.listResourceTemplates(request.params));
    if (backendCaps.resources.subscribe) {
      attachHandler(server, SubscribeRequestSchema, (request) => client.subscribeResource(request.params));
      attachHandler(server, UnsubscribeRequestSchema, (request) => client.unsubscribeResource(request.params));
    }
  }

  if (backendCaps.prompts) {
    attachHandler(server, ListPromptsRequestSchema, (request) => client.listPrompts(request.params));
    attachHandler(server, GetPromptRequestSchema, (request) => client.getPrompt(request.params));
  }

  if (backendCaps.completions) {
    attachHandler(server, CompleteRequestSchema, (request) => client.complete(request.params));
  }

  return server;
}

function isInitializeRequest(body) {
  return body && typeof body === 'object' && body.method === 'initialize';
}

function sendJson(res, status, body) {
  const payload = JSON.stringify(body);
  res.writeHead(status, {
    'content-type': 'application/json',
    'content-length': Buffer.byteLength(payload),
    'cache-control': 'no-store',
  });
  res.end(payload);
}

function readJsonBody(req) {
  return new Promise((resolve, reject) => {
    const chunks = [];
    req.on('data', (chunk) => chunks.push(chunk));
    req.on('end', () => {
      const raw = Buffer.concat(chunks).toString('utf8').trim();
      if (!raw) {
        resolve(undefined);
        return;
      }
      try {
        resolve(JSON.parse(raw));
      } catch (error) {
        reject(error);
      }
    });
    req.on('error', reject);
  });
}

async function connectBackend(spec) {
  const transport = new StdioClientTransport({
    command: spec.command,
    args: spec.args,
    env: backendEnv(spec),
    cwd: spec.cwd,
    stderr: 'pipe',
  });

  if (transport.stderr) {
    transport.stderr.on('data', (chunk) => {
      process.stderr.write(`[${spec.name}] ${chunk}`);
    });
  }

  transport.onclose = () => {
    console.error(`[${spec.name}] backend transport closed`);
    process.exit(1);
  };

  transport.onerror = (error) => {
    console.error(`[${spec.name}] backend transport error: ${error.message}`);
  };

  const client = new Client(
    {
      name: `${spec.name}-singleton-bridge-client`,
      version: '1.0.0',
    },
    { capabilities: {} }
  );
  await client.connect(transport);

  return {
    client,
    transport,
    serverVersion: client.getServerVersion(),
    capabilities: client.getServerCapabilities() || {},
  };
}

async function serve(spec) {
  loadSdkRuntime();
  const backend = await connectBackend(spec);
  const sessions = new Map();

  const server = http.createServer(async (req, res) => {
    try {
      const url = new URL(req.url || '/', `http://${req.headers.host || `127.0.0.1:${spec.port}`}`);
      if (req.method === 'GET' && url.pathname === '/healthz') {
        sendJson(res, 200, {
          ok: true,
          name: spec.name,
          port: spec.port,
          url: spec.url,
          backendPid: backend.transport.pid,
          backendVersion: backend.serverVersion || null,
          backendCapabilities: backend.capabilities,
        });
        return;
      }

      if (url.pathname !== '/mcp') {
        sendJson(res, 404, { error: 'not_found' });
        return;
      }

      if (req.method === 'OPTIONS') {
        res.writeHead(204, {
          'access-control-allow-origin': '*',
          'access-control-allow-methods': 'GET,POST,DELETE,OPTIONS',
          'access-control-allow-headers': 'Content-Type, Accept, Mcp-Session-Id, Last-Event-Id',
          'access-control-max-age': '86400',
        });
        res.end();
        return;
      }

      const sessionId = req.headers['mcp-session-id'];
      if (req.method === 'POST') {
        const body = await readJsonBody(req);
        if (!sessionId) {
          if (!isInitializeRequest(body)) {
            sendJson(res, 400, {
              jsonrpc: '2.0',
              error: { code: -32000, message: 'Bad Request: initialize required' },
              id: null,
            });
            return;
          }

          let transport;
          const bridgeServer = createBridgeServer(spec, backend.client);
          transport = new StreamableHTTPServerTransport({
            sessionIdGenerator: () => randomUUID(),
            onsessioninitialized: (newSessionId) => {
              sessions.set(newSessionId, { transport, bridgeServer });
            },
          });
          transport.onclose = () => {
            if (transport.sessionId) {
              sessions.delete(transport.sessionId);
            }
          };
          await bridgeServer.connect(transport);
          await transport.handleRequest(req, res, body);
          return;
        }

        const current = sessions.get(sessionId);
        if (!current) {
          sendJson(res, 404, {
            jsonrpc: '2.0',
            error: { code: -32001, message: 'Unknown MCP session' },
            id: null,
          });
          return;
        }
        await current.transport.handleRequest(req, res, body);
        return;
      }

      if (req.method === 'GET') {
        if (!sessionId || !sessions.has(sessionId)) {
          res.writeHead(400, { 'content-type': 'text/plain' });
          res.end('Invalid or missing session ID');
          return;
        }
        await sessions.get(sessionId).transport.handleRequest(req, res);
        return;
      }

      if (req.method === 'DELETE') {
        if (!sessionId || !sessions.has(sessionId)) {
          res.writeHead(400, { 'content-type': 'text/plain' });
          res.end('Invalid or missing session ID');
          return;
        }
        await sessions.get(sessionId).transport.handleRequest(req, res);
        return;
      }

      sendJson(res, 405, { error: 'method_not_allowed' });
    } catch (error) {
      console.error(`[${spec.name}] bridge request error:`, error);
      if (!res.headersSent) {
        sendJson(res, 500, {
          jsonrpc: '2.0',
          error: { code: -32603, message: 'Internal server error' },
          id: null,
        });
      }
    }
  });

  server.listen(spec.port, '127.0.0.1', () => {
    console.log(`mcp-singleton-bridge ${spec.name} listening on ${spec.url}`);
  });

  async function shutdown() {
    server.close();
    for (const { transport, bridgeServer } of sessions.values()) {
      try {
        await transport.close();
      } catch {}
      try {
        await bridgeServer.close();
      } catch {}
    }
    sessions.clear();
    try {
      await backend.transport.close();
    } catch {}
    process.exit(0);
  }

  process.on('SIGINT', shutdown);
  process.on('SIGTERM', shutdown);
}

function installUsage() {
  console.error('Usage:');
  console.error('  mcp_singleton_bridge.cjs list');
  console.error('  mcp_singleton_bridge.cjs plist <server>');
  console.error('  mcp_singleton_bridge.cjs install <server|all>');
  console.error('  mcp_singleton_bridge.cjs uninstall <server|all>');
  console.error('  mcp_singleton_bridge.cjs serve <server>');
  process.exit(1);
}

async function main() {
  const [command, name] = process.argv.slice(2);
  if (command === 'list') {
    allSpecs().forEach((spec) => {
      console.log(`${spec.name}\t${spec.url}\t${spec.command}`);
    });
    return;
  }

  if (command === 'plist') {
    if (!name) installUsage();
    process.stdout.write(plistXml(specFor(name)));
    return;
  }

  if (command === 'install') {
    installAgents(name || 'all');
    return;
  }

  if (command === 'uninstall') {
    uninstallAgents(name || 'all');
    return;
  }

  if (command === 'serve') {
    if (!name) installUsage();
    fs.mkdirSync(LOG_DIR, { recursive: true });
    await serve(specFor(name));
    return;
  }

  installUsage();
}

main().catch((error) => {
  console.error(error.stack || error.message || String(error));
  process.exit(1);
});
