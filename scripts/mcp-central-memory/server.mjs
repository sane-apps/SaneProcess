#!/usr/bin/env node

import fs from 'node:fs';
import path from 'node:path';
import crypto from 'node:crypto';
import process from 'node:process';
import { Pool } from 'pg';

const SERVER_NAME = 'central-memory-mcp';
const SERVER_VERSION = '1.0.0';

const DEFAULT_DB_URL = `postgresql://${encodeURIComponent(process.env.USER || 'sj')}@localhost:5432/central_memory`;
const DB_URL = process.env.CENTRAL_MEMORY_DATABASE_URL || process.env.DATABASE_URL || DEFAULT_DB_URL;
const OPENAI_API_KEY = process.env.OPENAI_API_KEY || '';
const OPENAI_BASE_URL = process.env.CENTRAL_MEMORY_OPENAI_BASE_URL || 'https://api.openai.com/v1';
const EMBEDDING_MODEL = process.env.CENTRAL_MEMORY_EMBED_MODEL || 'text-embedding-3-small';
const EMBEDDING_DIMENSIONS = Number.parseInt(process.env.CENTRAL_MEMORY_EMBED_DIMENSIONS || '1536', 10);

const MAX_RECALL_LIMIT = 50;
const MAX_IMPORT_LIMIT = 5000;
const DEFAULT_RECALL_LIMIT = 8;
const DEFAULT_RECENT_LIMIT = 20;
const DEFAULT_IMPORT_LIMIT = 500;

const pool = new Pool({ connectionString: DB_URL });

function log(message, extra = undefined) {
  const line = extra ? `${message} ${JSON.stringify(extra)}` : message;
  process.stderr.write(`[${SERVER_NAME}] ${line}\n`);
}

function toVectorLiteral(values) {
  return `[${values.join(',')}]`;
}

function normalizeTags(tags) {
  if (!Array.isArray(tags)) return [];
  return tags
    .map((tag) => String(tag || '').trim())
    .filter((tag) => tag.length > 0)
    .slice(0, 64);
}

function clampLimit(raw, fallback) {
  const parsed = Number.parseInt(String(raw ?? ''), 10);
  if (Number.isNaN(parsed) || parsed <= 0) return fallback;
  return Math.min(parsed, MAX_RECALL_LIMIT);
}

function clampImportLimit(raw) {
  const parsed = Number.parseInt(String(raw ?? ''), 10);
  if (Number.isNaN(parsed) || parsed <= 0) return DEFAULT_IMPORT_LIMIT;
  return Math.min(parsed, MAX_IMPORT_LIMIT);
}

function safeJsonParse(text, fallback = null) {
  try {
    return JSON.parse(text);
  } catch {
    return fallback;
  }
}

function stableExternalId(parts) {
  const hash = crypto.createHash('sha256');
  for (const part of parts) {
    hash.update(String(part ?? ''));
    hash.update('|');
  }
  return hash.digest('hex').slice(0, 40);
}

async function createEmbedding(inputText) {
  if (!OPENAI_API_KEY) {
    throw new Error('OPENAI_API_KEY is not set');
  }

  const response = await fetch(`${OPENAI_BASE_URL}/embeddings`, {
    method: 'POST',
    headers: {
      Authorization: `Bearer ${OPENAI_API_KEY}`,
      'Content-Type': 'application/json'
    },
    body: JSON.stringify({
      model: EMBEDDING_MODEL,
      input: inputText,
      dimensions: EMBEDDING_DIMENSIONS,
      encoding_format: 'float'
    })
  });

  const json = await response.json();
  if (!response.ok) {
    const msg = json?.error?.message || `Embedding API failed (${response.status})`;
    throw new Error(msg);
  }

  const embedding = json?.data?.[0]?.embedding;
  if (!Array.isArray(embedding) || embedding.length === 0) {
    throw new Error('Embedding API returned empty vector');
  }
  return embedding;
}

async function ensureSchema() {
  const client = await pool.connect();
  try {
    await client.query('CREATE EXTENSION IF NOT EXISTS vector');
    await client.query(`
      CREATE TABLE IF NOT EXISTS central_memories (
        id BIGSERIAL PRIMARY KEY,
        external_id TEXT UNIQUE,
        content TEXT NOT NULL,
        source TEXT NOT NULL DEFAULT '',
        kind TEXT NOT NULL DEFAULT '',
        tags TEXT[] NOT NULL DEFAULT '{}',
        metadata JSONB NOT NULL DEFAULT '{}',
        embedding vector(${EMBEDDING_DIMENSIONS}) NOT NULL,
        created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
        updated_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
      )
    `);
    await client.query('CREATE INDEX IF NOT EXISTS central_memories_kind_idx ON central_memories(kind)');
    await client.query('CREATE INDEX IF NOT EXISTS central_memories_tags_gin_idx ON central_memories USING GIN(tags)');
    await client.query('CREATE INDEX IF NOT EXISTS central_memories_metadata_gin_idx ON central_memories USING GIN(metadata)');
    await client.query('CREATE INDEX IF NOT EXISTS central_memories_created_idx ON central_memories(created_at DESC)');
    await client.query('CREATE INDEX IF NOT EXISTS central_memories_embedding_hnsw_idx ON central_memories USING hnsw (embedding vector_cosine_ops)');
  } finally {
    client.release();
  }
}

async function upsertMemory({
  content,
  source = '',
  kind = '',
  tags = [],
  metadata = {},
  externalId = null
}) {
  const text = String(content || '').trim();
  if (!text) {
    throw new Error('content is required');
  }

  const embedding = await createEmbedding(text);
  const embeddingLiteral = toVectorLiteral(embedding);
  const normalizedTags = normalizeTags(tags);
  const metadataJson = JSON.stringify(metadata || {});

  const sql = `
    INSERT INTO central_memories
      (external_id, content, source, kind, tags, metadata, embedding)
    VALUES
      ($1, $2, $3, $4, $5, $6::jsonb, $7::vector)
    ON CONFLICT (external_id)
    DO UPDATE SET
      content = EXCLUDED.content,
      source = EXCLUDED.source,
      kind = EXCLUDED.kind,
      tags = EXCLUDED.tags,
      metadata = EXCLUDED.metadata,
      embedding = EXCLUDED.embedding,
      updated_at = NOW()
    RETURNING id, external_id, created_at, updated_at
  `;

  const result = await pool.query(sql, [
    externalId,
    text,
    String(source || ''),
    String(kind || ''),
    normalizedTags,
    metadataJson,
    embeddingLiteral
  ]);

  return result.rows[0];
}

async function recallMemories({
  query,
  limit,
  kind,
  tag,
  minSimilarity
}) {
  const queryText = String(query || '').trim();
  if (!queryText) {
    throw new Error('query is required');
  }

  const vector = await createEmbedding(queryText);
  const vectorLiteral = toVectorLiteral(vector);
  const finalLimit = clampLimit(limit, DEFAULT_RECALL_LIMIT);
  const similarityFloor = Number.isFinite(minSimilarity) ? Number(minSimilarity) : null;

  const sql = `
    SELECT
      id,
      external_id,
      content,
      source,
      kind,
      tags,
      metadata,
      created_at,
      updated_at,
      (1 - (embedding <=> $1::vector)) AS similarity
    FROM central_memories
    WHERE ($2::text IS NULL OR kind = $2)
      AND ($3::text IS NULL OR $3 = ANY(tags))
    ORDER BY embedding <=> $1::vector
    LIMIT $4
  `;

  const rows = (await pool.query(sql, [
    vectorLiteral,
    kind ? String(kind) : null,
    tag ? String(tag) : null,
    finalLimit
  ])).rows;

  const filtered = similarityFloor === null
    ? rows
    : rows.filter((row) => Number(row.similarity) >= similarityFloor);

  return filtered.map((row) => ({
    id: row.id,
    external_id: row.external_id,
    content: row.content,
    source: row.source,
    kind: row.kind,
    tags: row.tags || [],
    metadata: row.metadata || {},
    similarity: Number(row.similarity),
    created_at: row.created_at,
    updated_at: row.updated_at
  }));
}

async function listRecent({ limit }) {
  const finalLimit = clampLimit(limit, DEFAULT_RECENT_LIMIT);
  const rows = (await pool.query(
    `SELECT id, external_id, content, source, kind, tags, metadata, created_at, updated_at
     FROM central_memories
     ORDER BY created_at DESC
     LIMIT $1`,
    [finalLimit]
  )).rows;

  return rows.map((row) => ({
    id: row.id,
    external_id: row.external_id,
    content: row.content,
    source: row.source,
    kind: row.kind,
    tags: row.tags || [],
    metadata: row.metadata || {},
    created_at: row.created_at,
    updated_at: row.updated_at
  }));
}

async function getStats() {
  const total = (await pool.query('SELECT COUNT(*)::bigint AS count FROM central_memories')).rows[0]?.count || 0;
  const byKind = (await pool.query(
    `SELECT kind, COUNT(*)::bigint AS count
     FROM central_memories
     GROUP BY kind
     ORDER BY count DESC, kind ASC`
  )).rows;
  const newest = (await pool.query(
    `SELECT MAX(created_at) AS latest_created_at,
            MAX(updated_at) AS latest_updated_at
     FROM central_memories`
  )).rows[0] || {};

  return {
    total: Number(total),
    by_kind: byKind.map((row) => ({ kind: row.kind, count: Number(row.count) })),
    latest_created_at: newest.latest_created_at,
    latest_updated_at: newest.latest_updated_at,
    db_url: DB_URL,
    embedding_model: EMBEDDING_MODEL,
    embedding_dimensions: EMBEDDING_DIMENSIONS
  };
}

async function deleteByExternalId({ external_id: externalId }) {
  const id = String(externalId || '').trim();
  if (!id) {
    throw new Error('external_id is required');
  }

  const result = await pool.query('DELETE FROM central_memories WHERE external_id = $1', [id]);
  return { deleted: result.rowCount };
}

async function importKnowledgeGraph({
  path: filePath = '/Users/sj/.claude/memory/knowledge-graph.jsonl',
  limit,
  source = 'knowledge-graph'
}) {
  const absolutePath = path.resolve(String(filePath));
  if (!fs.existsSync(absolutePath)) {
    throw new Error(`File not found: ${absolutePath}`);
  }

  const lines = fs.readFileSync(absolutePath, 'utf8').split('\n').filter((line) => line.trim().length > 0);
  const maxItems = clampImportLimit(limit);

  let imported = 0;
  let skipped = 0;
  const errors = [];

  for (const line of lines) {
    const record = safeJsonParse(line, null);
    if (!record || typeof record !== 'object') {
      skipped += 1;
      continue;
    }

    try {
      if (record.type === 'entity' && Array.isArray(record.observations)) {
        for (let i = 0; i < record.observations.length; i += 1) {
          if (imported >= maxItems) break;
          const observation = String(record.observations[i] || '').trim();
          if (!observation) continue;

          const entityName = String(record.name || 'unknown');
          const entityType = String(record.entityType || 'unknown');
          const externalId = stableExternalId(['entity', entityName, entityType, i, observation]);

          await upsertMemory({
            content: `${entityName}: ${observation}`,
            source,
            kind: 'entity_observation',
            tags: ['knowledge-graph', entityType],
            metadata: {
              entity_name: entityName,
              entity_type: entityType,
              observation_index: i
            },
            externalId
          });
          imported += 1;
        }
      } else if (record.type === 'relation') {
        if (imported >= maxItems) break;
        const from = String(record.from || '');
        const rel = String(record.relationType || '');
        const to = String(record.to || '');
        if (!from || !rel || !to) {
          skipped += 1;
          continue;
        }
        const content = `${from} ${rel} ${to}`;
        const externalId = stableExternalId(['relation', from, rel, to]);
        await upsertMemory({
          content,
          source,
          kind: 'relation',
          tags: ['knowledge-graph', 'relation'],
          metadata: { from, relation_type: rel, to },
          externalId
        });
        imported += 1;
      } else {
        skipped += 1;
      }
    } catch (error) {
      errors.push(String(error?.message || error));
    }

    if (imported >= maxItems) break;
  }

  return {
    file: absolutePath,
    imported,
    skipped,
    errors: errors.slice(0, 10)
  };
}

const TOOLS = [
  {
    name: 'remember',
    description: 'Store or upsert one memory item with semantic embedding.',
    inputSchema: {
      type: 'object',
      properties: {
        content: { type: 'string' },
        source: { type: 'string' },
        kind: { type: 'string' },
        tags: { type: 'array', items: { type: 'string' } },
        metadata: { type: 'object' },
        external_id: { type: 'string' }
      },
      required: ['content']
    }
  },
  {
    name: 'recall',
    description: 'Semantic search against stored memories.',
    inputSchema: {
      type: 'object',
      properties: {
        query: { type: 'string' },
        limit: { type: 'number' },
        kind: { type: 'string' },
        tag: { type: 'string' },
        min_similarity: { type: 'number' }
      },
      required: ['query']
    }
  },
  {
    name: 'recent',
    description: 'List most recently added memories.',
    inputSchema: {
      type: 'object',
      properties: {
        limit: { type: 'number' }
      }
    }
  },
  {
    name: 'stats',
    description: 'Return memory database stats and configuration.',
    inputSchema: {
      type: 'object',
      properties: {}
    }
  },
  {
    name: 'delete_by_external_id',
    description: 'Delete one memory row by external ID.',
    inputSchema: {
      type: 'object',
      properties: {
        external_id: { type: 'string' }
      },
      required: ['external_id']
    }
  },
  {
    name: 'import_knowledge_graph',
    description: 'Import entity observations/relations from a memory JSONL file.',
    inputSchema: {
      type: 'object',
      properties: {
        path: { type: 'string' },
        limit: { type: 'number' },
        source: { type: 'string' }
      }
    }
  }
];

function contentResponse(payload) {
  return {
    content: [
      {
        type: 'text',
        text: JSON.stringify(payload, null, 2)
      }
    ]
  };
}

function writeMessage(obj) {
  const json = JSON.stringify(obj);
  const header = `Content-Length: ${Buffer.byteLength(json, 'utf8')}\r\n\r\n`;
  process.stdout.write(header + json);
}

function writeResult(id, result) {
  writeMessage({ jsonrpc: '2.0', id, result });
}

function writeError(id, code, message) {
  writeMessage({
    jsonrpc: '2.0',
    id,
    error: { code, message }
  });
}

async function handleToolsCall(name, args) {
  switch (name) {
    case 'remember': {
      const row = await upsertMemory({
        content: args?.content,
        source: args?.source,
        kind: args?.kind,
        tags: args?.tags,
        metadata: args?.metadata,
        externalId: args?.external_id || null
      });
      return contentResponse({ ok: true, memory: row });
    }
    case 'recall': {
      const rows = await recallMemories({
        query: args?.query,
        limit: args?.limit,
        kind: args?.kind,
        tag: args?.tag,
        minSimilarity: args?.min_similarity
      });
      return contentResponse({ ok: true, count: rows.length, memories: rows });
    }
    case 'recent': {
      const rows = await listRecent({ limit: args?.limit });
      return contentResponse({ ok: true, count: rows.length, memories: rows });
    }
    case 'stats': {
      const stats = await getStats();
      return contentResponse({ ok: true, stats });
    }
    case 'delete_by_external_id': {
      const deleted = await deleteByExternalId({ external_id: args?.external_id });
      return contentResponse({ ok: true, ...deleted });
    }
    case 'import_knowledge_graph': {
      const summary = await importKnowledgeGraph({
        path: args?.path,
        limit: args?.limit,
        source: args?.source
      });
      return contentResponse({ ok: true, ...summary });
    }
    default:
      throw new Error(`Unknown tool: ${name}`);
  }
}

async function handleMessage(message) {
  if (!message || typeof message !== 'object') return;

  const id = Object.prototype.hasOwnProperty.call(message, 'id') ? message.id : null;
  const method = message.method;

  if (!method) return;

  try {
    if (method === 'initialize') {
      writeResult(id, {
        protocolVersion: '2024-11-05',
        serverInfo: {
          name: SERVER_NAME,
          version: SERVER_VERSION
        },
        capabilities: {
          tools: {}
        }
      });
      return;
    }

    if (method === 'notifications/initialized') {
      return;
    }

    if (method === 'tools/list') {
      writeResult(id, { tools: TOOLS });
      return;
    }

    if (method === 'tools/call') {
      const toolName = message?.params?.name;
      const args = message?.params?.arguments || {};
      const result = await handleToolsCall(toolName, args);
      writeResult(id, result);
      return;
    }

    writeError(id, -32601, `Method not found: ${method}`);
  } catch (error) {
    writeError(id, -32000, String(error?.message || error));
  }
}

class MessageParser {
  constructor(onMessage) {
    this.onMessage = onMessage;
    this.buffer = '';
  }

  push(chunk) {
    this.buffer += chunk.toString('utf8');
    this.drain();
  }

  drain() {
    while (this.buffer.length > 0) {
      while (this.buffer.startsWith('\n') || this.buffer.startsWith('\r')) {
        this.buffer = this.buffer.slice(1);
      }
      if (this.buffer.length === 0) return;

      if (this.buffer.startsWith('Content-Length:')) {
        const headerEnd = this.buffer.indexOf('\r\n\r\n');
        if (headerEnd === -1) return;

        const header = this.buffer.slice(0, headerEnd);
        const match = header.match(/Content-Length:\s*(\d+)/i);
        if (!match) {
          this.buffer = this.buffer.slice(headerEnd + 4);
          continue;
        }

        const length = Number.parseInt(match[1], 10);
        const bodyStart = headerEnd + 4;
        const bodyEnd = bodyStart + length;
        if (this.buffer.length < bodyEnd) return;

        const body = this.buffer.slice(bodyStart, bodyEnd);
        this.buffer = this.buffer.slice(bodyEnd);

        const parsed = safeJsonParse(body, null);
        if (parsed) {
          this.onMessage(parsed);
        }
        continue;
      }

      const newlineIndex = this.buffer.indexOf('\n');
      if (newlineIndex === -1) return;
      const line = this.buffer.slice(0, newlineIndex).trim();
      this.buffer = this.buffer.slice(newlineIndex + 1);
      if (!line.startsWith('{')) continue;

      const parsed = safeJsonParse(line, null);
      if (parsed) {
        this.onMessage(parsed);
      }
    }
  }
}

async function main() {
  log('starting', {
    db_url: DB_URL,
    embedding_model: EMBEDDING_MODEL,
    embedding_dimensions: EMBEDDING_DIMENSIONS
  });

  await ensureSchema();

  const parser = new MessageParser((msg) => {
    handleMessage(msg).catch((error) => {
      log('message handler error', { error: String(error?.message || error) });
    });
  });

  process.stdin.on('data', (chunk) => parser.push(chunk));
  process.stdin.resume();
}

main().catch((error) => {
  log('fatal startup error', { error: String(error?.message || error) });
  process.exit(1);
});
