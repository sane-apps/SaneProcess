#!/usr/bin/env node
import { McpServer } from "@modelcontextprotocol/sdk/server/mcp.js";
import { StdioServerTransport } from "@modelcontextprotocol/sdk/server/stdio.js";
import { z } from "zod";
import { promises as fs } from 'fs';
import path from 'path';
import { fileURLToPath } from 'url';
// Define memory file path using environment variable with fallback
export const defaultMemoryPath = path.join(path.dirname(fileURLToPath(import.meta.url)), 'memory.jsonl');
// Handle backward compatibility: migrate memory.json to memory.jsonl if needed
export async function ensureMemoryFilePath() {
    if (process.env.MEMORY_FILE_PATH) {
        // Custom path provided, use it as-is (with absolute path resolution)
        return path.isAbsolute(process.env.MEMORY_FILE_PATH)
            ? process.env.MEMORY_FILE_PATH
            : path.join(path.dirname(fileURLToPath(import.meta.url)), process.env.MEMORY_FILE_PATH);
    }
    // No custom path set, check for backward compatibility migration
    const oldMemoryPath = path.join(path.dirname(fileURLToPath(import.meta.url)), 'memory.json');
    const newMemoryPath = defaultMemoryPath;
    try {
        // Check if old file exists and new file doesn't
        await fs.access(oldMemoryPath);
        try {
            await fs.access(newMemoryPath);
            // Both files exist, use new one (no migration needed)
            return newMemoryPath;
        }
        catch {
            // Old file exists, new file doesn't - migrate
            console.error('DETECTED: Found legacy memory.json file, migrating to memory.jsonl for JSONL format compatibility');
            await fs.rename(oldMemoryPath, newMemoryPath);
            console.error('COMPLETED: Successfully migrated memory.json to memory.jsonl');
            return newMemoryPath;
        }
    }
    catch {
        // Old file doesn't exist, use new path
        return newMemoryPath;
    }
}
// Initialize memory file path (will be set during startup)
let MEMORY_FILE_PATH;
const MAX_DIRECT_SEARCH_RESULTS = 10;
const MAX_TOTAL_SEARCH_RESULTS = 20;
const MAX_NEIGHBOR_EXPANSION_DEGREE = 8;
function normalizeSearchText(value) {
    return String(value ?? '')
        .toLowerCase()
        .normalize('NFKD')
        .replace(/[\u0300-\u036f]/g, '')
        .replace(/[^a-z0-9]+/g, ' ')
        .trim();
}
function tokenizeSearchText(value) {
    const normalized = normalizeSearchText(value);
    if (!normalized) {
        return [];
    }
    return [...new Set(normalized
            .split(/\s+/)
            .filter(token => token.length > 1 || /^\d+$/.test(token)))];
}
function scoreSearchField(fieldText, token, exactWeight, containsWeight) {
    if (!fieldText) {
        return 0;
    }
    const words = fieldText.split(/\s+/);
    if (words.includes(token)) {
        return exactWeight;
    }
    if (fieldText.includes(token)) {
        return containsWeight;
    }
    return 0;
}
function scoreEntityForQuery(entity, query) {
    const normalizedQuery = normalizeSearchText(query);
    const tokens = tokenizeSearchText(query);
    if (!normalizedQuery && tokens.length === 0) {
        return 0;
    }
    const name = normalizeSearchText(entity.name);
    const entityType = normalizeSearchText(entity.entityType);
    const observations = normalizeSearchText((entity.observations || []).join(' '));
    const combined = [name, entityType, observations].filter(Boolean).join(' ');
    let score = 0;
    let matchedTokens = 0;
    if (name === normalizedQuery) {
        score += 300;
    }
    else if (name.includes(normalizedQuery) && normalizedQuery) {
        score += 180;
    }
    if (entityType === normalizedQuery) {
        score += 160;
    }
    else if (entityType.includes(normalizedQuery) && normalizedQuery) {
        score += 70;
    }
    if (observations.includes(normalizedQuery) && normalizedQuery) {
        score += 110;
    }
    for (const token of tokens) {
        const tokenScore = scoreSearchField(name, token, 65, 40) +
            scoreSearchField(entityType, token, 35, 20) +
            scoreSearchField(observations, token, 25, 12);
        if (tokenScore > 0) {
            matchedTokens += 1;
            score += tokenScore;
        }
    }
    if (tokens.length > 1) {
        const minimumTokenMatches = tokens.length === 2 ? 2 : Math.ceil(tokens.length * 0.75);
        if (combined.includes(normalizedQuery)) {
            score += 90;
        }
        else if (matchedTokens < minimumTokenMatches) {
            return 0;
        }
        score += matchedTokens * 18;
    }
    return score;
}
function relationNeighborBonus(relationType) {
    const normalized = normalizeSearchText(relationType);
    if (normalized === 'mirrors') {
        return 30;
    }
    if (normalized === 'matches') {
        return 24;
    }
    if (normalized === 'summarizes') {
        return 18;
    }
    if (normalized === 'affects') {
        return 16;
    }
    return 10;
}
// The KnowledgeGraphManager class contains all operations to interact with the knowledge graph
export class KnowledgeGraphManager {
    memoryFilePath;
    constructor(memoryFilePath) {
        this.memoryFilePath = memoryFilePath;
    }
    async loadGraph() {
        try {
            const data = await fs.readFile(this.memoryFilePath, "utf-8");
            const lines = data.split("\n").filter(line => line.trim() !== "");
            return lines.reduce((graph, line) => {
                const item = JSON.parse(line);
                if (item.type === "entity") {
                    graph.entities.push({
                        name: item.name,
                        entityType: item.entityType,
                        observations: item.observations
                    });
                }
                if (item.type === "relation") {
                    graph.relations.push({
                        from: item.from,
                        to: item.to,
                        relationType: item.relationType
                    });
                }
                return graph;
            }, { entities: [], relations: [] });
        }
        catch (error) {
            if (error instanceof Error && 'code' in error && error.code === "ENOENT") {
                return { entities: [], relations: [] };
            }
            throw error;
        }
    }
    async saveGraph(graph) {
        const lines = [
            ...graph.entities.map(e => JSON.stringify({
                type: "entity",
                name: e.name,
                entityType: e.entityType,
                observations: e.observations
            })),
            ...graph.relations.map(r => JSON.stringify({
                type: "relation",
                from: r.from,
                to: r.to,
                relationType: r.relationType
            })),
        ];
        await fs.writeFile(this.memoryFilePath, lines.join("\n"));
    }
    async createEntities(entities) {
        const graph = await this.loadGraph();
        const newEntities = entities.filter(e => !graph.entities.some(existingEntity => existingEntity.name === e.name));
        graph.entities.push(...newEntities);
        await this.saveGraph(graph);
        return newEntities;
    }
    async createRelations(relations) {
        const graph = await this.loadGraph();
        const newRelations = relations.filter(r => !graph.relations.some(existingRelation => existingRelation.from === r.from &&
            existingRelation.to === r.to &&
            existingRelation.relationType === r.relationType));
        graph.relations.push(...newRelations);
        await this.saveGraph(graph);
        return newRelations;
    }
    async addObservations(observations) {
        const graph = await this.loadGraph();
        const results = observations.map(o => {
            const entity = graph.entities.find(e => e.name === o.entityName);
            if (!entity) {
                throw new Error(`Entity with name ${o.entityName} not found`);
            }
            const newObservations = o.contents.filter(content => !entity.observations.includes(content));
            entity.observations.push(...newObservations);
            return { entityName: o.entityName, addedObservations: newObservations };
        });
        await this.saveGraph(graph);
        return results;
    }
    async deleteEntities(entityNames) {
        const graph = await this.loadGraph();
        graph.entities = graph.entities.filter(e => !entityNames.includes(e.name));
        graph.relations = graph.relations.filter(r => !entityNames.includes(r.from) && !entityNames.includes(r.to));
        await this.saveGraph(graph);
    }
    async deleteObservations(deletions) {
        const graph = await this.loadGraph();
        deletions.forEach(d => {
            const entity = graph.entities.find(e => e.name === d.entityName);
            if (entity) {
                entity.observations = entity.observations.filter(o => !d.observations.includes(o));
            }
        });
        await this.saveGraph(graph);
    }
    async deleteRelations(relations) {
        const graph = await this.loadGraph();
        graph.relations = graph.relations.filter(r => !relations.some(delRelation => r.from === delRelation.from &&
            r.to === delRelation.to &&
            r.relationType === delRelation.relationType));
        await this.saveGraph(graph);
    }
    async readGraph() {
        return this.loadGraph();
    }
    async searchNodes(query) {
        const graph = await this.loadGraph();
        const normalizedQuery = normalizeSearchText(query);
        const entityByName = new Map(graph.entities.map(entity => [entity.name, entity]));
        const relationDegree = new Map();
        for (const relation of graph.relations) {
            relationDegree.set(relation.from, (relationDegree.get(relation.from) || 0) + 1);
            relationDegree.set(relation.to, (relationDegree.get(relation.to) || 0) + 1);
        }
        const scoredMatches = graph.entities
            .map(entity => {
            const rawScore = scoreEntityForQuery(entity, query);
            const normalizedName = normalizeSearchText(entity.name);
            const degree = relationDegree.get(entity.name) || 0;
            const isNameMatch = normalizedName === normalizedQuery || normalizedName.includes(normalizedQuery);
            const hubPenalty = !isNameMatch && degree > MAX_NEIGHBOR_EXPANSION_DEGREE
                ? Math.min(120, (degree - MAX_NEIGHBOR_EXPANSION_DEGREE) * 8)
                : 0;
            return { entity, score: Math.max(0, rawScore - hubPenalty) };
        })
            .filter(match => match.score > 0)
            .sort((left, right) => right.score - left.score || left.entity.name.localeCompare(right.entity.name))
            .slice(0, MAX_DIRECT_SEARCH_RESULTS);
        const included = new Map(scoredMatches.map(match => [match.entity.name, {
                entity: match.entity,
                score: match.score,
                direct: true
            }]));
        const expansionAnchors = new Set(scoredMatches
            .filter(match => match.score >= 80 && (relationDegree.get(match.entity.name) || 0) <= MAX_NEIGHBOR_EXPANSION_DEGREE)
            .map(match => match.entity.name));
        for (const relation of graph.relations) {
            if (included.size >= MAX_TOTAL_SEARCH_RESULTS) {
                break;
            }
            const fromMatch = included.get(relation.from);
            const toMatch = included.get(relation.to);
            if (fromMatch?.direct && expansionAnchors.has(relation.from) && !included.has(relation.to)) {
                const neighbor = entityByName.get(relation.to);
                if (neighbor) {
                    included.set(neighbor.name, {
                        entity: neighbor,
                        score: fromMatch.score - relationNeighborBonus(relation.relationType),
                        direct: false
                    });
                }
            }
            if (included.size >= MAX_TOTAL_SEARCH_RESULTS) {
                break;
            }
            if (toMatch?.direct && expansionAnchors.has(relation.to) && !included.has(relation.from)) {
                const neighbor = entityByName.get(relation.from);
                if (neighbor) {
                    included.set(neighbor.name, {
                        entity: neighbor,
                        score: toMatch.score - relationNeighborBonus(relation.relationType),
                        direct: false
                    });
                }
            }
        }
        const directEntityNames = new Set(scoredMatches.map(match => match.entity.name));
        const filteredEntities = [...included.values()]
            .sort((left, right) => right.score - left.score || left.entity.name.localeCompare(right.entity.name))
            .slice(0, MAX_TOTAL_SEARCH_RESULTS)
            .map(match => match.entity);
        const filteredEntityNames = new Set(filteredEntities.map(entity => entity.name));
        const filteredRelations = graph.relations.filter(relation => filteredEntityNames.has(relation.from) &&
            filteredEntityNames.has(relation.to) &&
            (directEntityNames.has(relation.from) || directEntityNames.has(relation.to)));
        const filteredGraph = {
            entities: filteredEntities,
            relations: filteredRelations,
        };
        return filteredGraph;
    }
    async openNodes(names) {
        const graph = await this.loadGraph();
        // Filter entities
        const filteredEntities = graph.entities.filter(e => names.includes(e.name));
        // Create a Set of filtered entity names for quick lookup
        const filteredEntityNames = new Set(filteredEntities.map(e => e.name));
        // Filter relations to only include those between filtered entities
        const filteredRelations = graph.relations.filter(r => filteredEntityNames.has(r.from) && filteredEntityNames.has(r.to));
        const filteredGraph = {
            entities: filteredEntities,
            relations: filteredRelations,
        };
        return filteredGraph;
    }
}
let knowledgeGraphManager;
// Zod schemas for entities and relations
const EntitySchema = z.object({
    name: z.string().describe("The name of the entity"),
    entityType: z.string().describe("The type of the entity"),
    observations: z.array(z.string()).describe("An array of observation contents associated with the entity")
});
const RelationSchema = z.object({
    from: z.string().describe("The name of the entity where the relation starts"),
    to: z.string().describe("The name of the entity where the relation ends"),
    relationType: z.string().describe("The type of the relation")
});
// The server instance and tools exposed to Claude
const server = new McpServer({
    name: "memory-server",
    version: "0.6.3",
});
// Register create_entities tool
server.registerTool("create_entities", {
    title: "Create Entities",
    description: "Create multiple new entities in the knowledge graph",
    inputSchema: {
        entities: z.array(EntitySchema)
    },
    outputSchema: {
        entities: z.array(EntitySchema)
    }
}, async ({ entities }) => {
    const result = await knowledgeGraphManager.createEntities(entities);
    return {
        content: [{ type: "text", text: JSON.stringify(result, null, 2) }],
        structuredContent: { entities: result }
    };
});
// Register create_relations tool
server.registerTool("create_relations", {
    title: "Create Relations",
    description: "Create multiple new relations between entities in the knowledge graph. Relations should be in active voice",
    inputSchema: {
        relations: z.array(RelationSchema)
    },
    outputSchema: {
        relations: z.array(RelationSchema)
    }
}, async ({ relations }) => {
    const result = await knowledgeGraphManager.createRelations(relations);
    return {
        content: [{ type: "text", text: JSON.stringify(result, null, 2) }],
        structuredContent: { relations: result }
    };
});
// Register add_observations tool
server.registerTool("add_observations", {
    title: "Add Observations",
    description: "Add new observations to existing entities in the knowledge graph",
    inputSchema: {
        observations: z.array(z.object({
            entityName: z.string().describe("The name of the entity to add the observations to"),
            contents: z.array(z.string()).describe("An array of observation contents to add")
        }))
    },
    outputSchema: {
        results: z.array(z.object({
            entityName: z.string(),
            addedObservations: z.array(z.string())
        }))
    }
}, async ({ observations }) => {
    const result = await knowledgeGraphManager.addObservations(observations);
    return {
        content: [{ type: "text", text: JSON.stringify(result, null, 2) }],
        structuredContent: { results: result }
    };
});
// Register delete_entities tool
server.registerTool("delete_entities", {
    title: "Delete Entities",
    description: "Delete multiple entities and their associated relations from the knowledge graph",
    inputSchema: {
        entityNames: z.array(z.string()).describe("An array of entity names to delete")
    },
    outputSchema: {
        success: z.boolean(),
        message: z.string()
    }
}, async ({ entityNames }) => {
    await knowledgeGraphManager.deleteEntities(entityNames);
    return {
        content: [{ type: "text", text: "Entities deleted successfully" }],
        structuredContent: { success: true, message: "Entities deleted successfully" }
    };
});
// Register delete_observations tool
server.registerTool("delete_observations", {
    title: "Delete Observations",
    description: "Delete specific observations from entities in the knowledge graph",
    inputSchema: {
        deletions: z.array(z.object({
            entityName: z.string().describe("The name of the entity containing the observations"),
            observations: z.array(z.string()).describe("An array of observations to delete")
        }))
    },
    outputSchema: {
        success: z.boolean(),
        message: z.string()
    }
}, async ({ deletions }) => {
    await knowledgeGraphManager.deleteObservations(deletions);
    return {
        content: [{ type: "text", text: "Observations deleted successfully" }],
        structuredContent: { success: true, message: "Observations deleted successfully" }
    };
});
// Register delete_relations tool
server.registerTool("delete_relations", {
    title: "Delete Relations",
    description: "Delete multiple relations from the knowledge graph",
    inputSchema: {
        relations: z.array(RelationSchema).describe("An array of relations to delete")
    },
    outputSchema: {
        success: z.boolean(),
        message: z.string()
    }
}, async ({ relations }) => {
    await knowledgeGraphManager.deleteRelations(relations);
    return {
        content: [{ type: "text", text: "Relations deleted successfully" }],
        structuredContent: { success: true, message: "Relations deleted successfully" }
    };
});
// Register read_graph tool
server.registerTool("read_graph", {
    title: "Read Graph",
    description: "Read the entire knowledge graph",
    inputSchema: {},
    outputSchema: {
        entities: z.array(EntitySchema),
        relations: z.array(RelationSchema)
    }
}, async () => {
    const graph = await knowledgeGraphManager.readGraph();
    return {
        content: [{ type: "text", text: JSON.stringify(graph, null, 2) }],
        structuredContent: { ...graph }
    };
});
// Register search_nodes tool
server.registerTool("search_nodes", {
    title: "Search Nodes",
    description: "Search for nodes in the knowledge graph based on a query",
    inputSchema: {
        query: z.string().describe("The search query to match against entity names, types, and observation content")
    },
    outputSchema: {
        entities: z.array(EntitySchema),
        relations: z.array(RelationSchema)
    }
}, async ({ query }) => {
    const graph = await knowledgeGraphManager.searchNodes(query);
    return {
        content: [{ type: "text", text: JSON.stringify(graph, null, 2) }],
        structuredContent: { ...graph }
    };
});
// Register open_nodes tool
server.registerTool("open_nodes", {
    title: "Open Nodes",
    description: "Open specific nodes in the knowledge graph by their names",
    inputSchema: {
        names: z.array(z.string()).describe("An array of entity names to retrieve")
    },
    outputSchema: {
        entities: z.array(EntitySchema),
        relations: z.array(RelationSchema)
    }
}, async ({ names }) => {
    const graph = await knowledgeGraphManager.openNodes(names);
    return {
        content: [{ type: "text", text: JSON.stringify(graph, null, 2) }],
        structuredContent: { ...graph }
    };
});
async function main() {
    // Initialize memory file path with backward compatibility
    MEMORY_FILE_PATH = await ensureMemoryFilePath();
    // Initialize knowledge graph manager with the memory file path
    knowledgeGraphManager = new KnowledgeGraphManager(MEMORY_FILE_PATH);
    const transport = new StdioServerTransport();
    await server.connect(transport);
    console.error("Knowledge Graph MCP Server running on stdio");
}
const isDirectRun = process.argv[1]
    ? path.resolve(process.argv[1]) === fileURLToPath(import.meta.url)
    : false;
if (isDirectRun) {
    main().catch((error) => {
        console.error("Fatal error in main():", error);
        process.exit(1);
    });
}
