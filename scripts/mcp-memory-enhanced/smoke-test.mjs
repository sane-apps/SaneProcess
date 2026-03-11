#!/usr/bin/env node

import process from 'node:process';
import { KnowledgeGraphManager, ensureMemoryFilePath } from './server.mjs';

async function main() {
  const query = process.argv.slice(2).join(' ').trim();
  if (!query) {
    console.error('usage: smoke-test.mjs <query>');
    process.exit(1);
  }

  process.env.MEMORY_FILE_PATH ||= '/Users/sj/.claude/memory/knowledge-graph.jsonl';
  const memoryFilePath = await ensureMemoryFilePath();
  const manager = new KnowledgeGraphManager(memoryFilePath);
  const graph = await manager.searchNodes(query);

  const entityNames = graph.entities.map((entity) => entity.name);
  console.log(JSON.stringify({
    query,
    entity_count: graph.entities.length,
    relation_count: graph.relations.length,
    entity_names: entityNames
  }, null, 2));
}

main().catch((error) => {
  console.error(error);
  process.exit(1);
});
