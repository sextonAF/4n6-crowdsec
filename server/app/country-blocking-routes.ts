import fs from 'node:fs';
import net from 'node:net';
import { Hono } from 'hono';

interface AgentConfig { url: string; token_file: string }
type Agents = Record<string, AgentConfig>;

function readAgents(fileName: string | undefined): Agents {
  if (!fileName) return {};
  const file = fs.readFileSync(fileName, 'utf8');
  const parsed: unknown = JSON.parse(file);
  if (!parsed || typeof parsed !== 'object' || Array.isArray(parsed)) throw new Error('Invalid country agent configuration');
  const agents: Agents = {};
  for (const [id, value] of Object.entries(parsed)) {
    if (!value || typeof value !== 'object' || Array.isArray(value)) throw new Error('Invalid country agent entry');
    const obj = value as Partial<AgentConfig>;
    if (typeof obj.url !== 'string' || typeof obj.token_file !== 'string') throw new Error('Invalid agent URL or token path');
    const uri = new URL(obj.url);
    // SSRF prevention: country-agent endpoints must target only a fixed, trusted local interface.
    if (uri.protocol !== 'http:' || uri.username || uri.password || uri.search || uri.hash ||
        uri.pathname !== '/' || net.isIP(uri.hostname) !== 4 ||
        !(uri.hostname.startsWith('172.') || uri.hostname.startsWith('10.') || uri.hostname.startsWith('192.168.') || uri.hostname === '127.0.0.1')) {
      throw new Error('Country agents must use a configured local IPv4 endpoint');
    }
    agents[id] = { url:uri.origin, token_file:obj.token_file };
  }
  return agents;
}

export function registerCountryBlockingRoutes(deps: {
  app: Hono;
  basePath: string;
  ensureAuth: (context: any, next: any) => Promise<Response | void>;
  canManage: (context: any) => boolean;
  instances: Array<{ id: string; name: string }>;
  agentsFile?: string;
}) {
  const { app, basePath, ensureAuth, canManage, instances } = deps;
  const agents = readAgents(deps.agentsFile);
  function instanceOf(id: string) {
    return instances.find((entry) => entry.id === id);
  }
  async function proxy(c: any, action: 'status' | 'preview' | 'apply') {
    if (!instanceOf(c.req.param('instanceId'))) return c.json({error:'Unknown server'},404);
    const id = c.req.param('instanceId') as string;
    if (action !== 'status' && !canManage(c)) return c.json({error:'Administrator permission required'},403);
    const agent = agents[id];
    if (!agent) return c.json({error:'Country-blocking agent not configured for this server'},503);
    let countries: string[] | undefined;
    if (action !== 'status') {
      const body: unknown = await c.req.json().catch(() => null);
      if (!body || typeof body !== 'object' || Array.isArray(body) ||
          Object.keys(body).length !== 1 || !('countries' in body)) {
        return c.json({error:'Expected countries array'},400);
      }
      const list = (body as {countries:unknown}).countries;
      if (!Array.isArray(list) || list.length > 30 ||
          list.some((x) => typeof x !== 'string' || !/^[A-Z]{2}$/.test(x)) ||
          new Set(list).size !== list.length) {
        return c.json({error:'Invalid countries'},400);
      }
      countries = list;
    }
    let token: string;
    try {
      token = fs.readFileSync(agent.token_file,'utf8').trim();
      if (token.length < 32) throw new Error('short token');
    } catch {
      return c.json({error:'Agent credential unavailable'},503);
    }
    try {
      const result = await fetch(agent.url + '/v1/' + action, {
        method: action === 'status' ? 'GET' : 'POST',
        headers: {
          Authorization: 'Bearer ' + token,
          ...(action === 'status' ? {} : {'Content-Type':'application/json'}),
        },
        ...(action === 'status' ? {} : {body:JSON.stringify({countries})}),
        signal: AbortSignal.timeout(action === 'status' ? 5000 : 180000),
      });
      const payload = await result.json() as Record<string,unknown>;
      if (payload.server_id !== id && result.ok) return c.json({error:'Agent server identity mismatch'},502);
      return c.json(payload, result.status as any);
    } catch {
      return c.json({error:'Country agent unreachable or timed out'},502);
    }
  }
  app.get(`${basePath}/api/country-blocking/:instanceId/status`, ensureAuth, (c) => proxy(c,'status'));
  app.post(`${basePath}/api/country-blocking/:instanceId/preview`, ensureAuth, (c) => proxy(c,'preview'));
  app.post(`${basePath}/api/country-blocking/:instanceId/apply`, ensureAuth, (c) => proxy(c,'apply'));
}
