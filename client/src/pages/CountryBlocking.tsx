import { useEffect, useMemo, useState } from 'react';
import { AlertTriangle, Globe2, RefreshCw, Search, Server, ShieldBan } from 'lucide-react';
import { Card, CardContent, CardHeader, CardTitle } from '../components/ui/Card';
import { fetchConfig } from '../lib/api';
import { useAuth } from '../contexts/AuthContext';
import { apiUrl } from '../lib/basePath';
import { sessionFetch } from '../lib/sessionFetch';

const CODES = ('AD AE AF AG AI AL AM AO AQ AR AS AT AU AW AX AZ BA BB BD BE BF BG BH BI BJ BL BM BN BO BQ BR BS BT BV BW BY BZ CA CC CD CF CG CH CI CK CL CM CN CO CR CU CV CW CX CY CZ DE DJ DK DM DO DZ EC EE EG EH ER ES ET FI FJ FK FM FO FR GA GB GD GE GF GG GH GI GL GM GN GP GQ GR GS GT GU GW GY HK HM HN HR HT HU ID IE IL IM IN IO IQ IR IS IT JE JM JO JP KE KG KH KI KM KN KP KR KW KY KZ LA LB LC LI LK LR LS LT LU LV LY MA MC MD ME MF MG MH MK ML MM MN MO MP MQ MR MS MT MU MV MW MX MY MZ NA NC NE NF NG NI NL NO NP NR NU NZ OM PA PE PF PG PH PK PL PM PN PR PS PT PW PY QA RE RO RS RU RW SA SB SC SD SE SG SH SI SJ SK SL SM SN SO SR SS ST SV SX SY SZ TC TD TF TG TH TJ TK TL TM TN TO TR TT TV TW TZ UA UG UM US UY UZ VA VC VE VG VI VN VU WF WS YE YT ZA ZM ZW').split(' ');
const displayNames = new Intl.DisplayNames(['en'], { type: 'region' });
const COUNTRIES = CODES.map((code) => ({ code, name: displayNames.of(code) || code }))
  .sort((a, b) => a.name.localeCompare(b.name));
type Instance = {id:string; name:string};
type AgentStatus = {server_id:string; countries:string[]; enforcement_enabled:boolean; applied:boolean; mode:string; updated_at?:string; table_present?:boolean};
type Preview = {server_id:string; countries:string[]; counts:{ipv4:number;ipv6:number}; dry_run:boolean; applied:boolean};

async function agentCall<T>(instance: string, action: 'status'|'preview'|'apply', countries?:string[]):Promise<T> {
  const response = await sessionFetch(apiUrl(`/api/country-blocking/${encodeURIComponent(instance)}/${action}`), {
    method: action === 'status' ? 'GET' : 'POST',
    ...(action === 'status' ? {} : {headers:{'Content-Type':'application/json'},body:JSON.stringify({countries})}),
  });
  const body = await response.json().catch(() => ({})) as {error?:string};
  if (!response.ok) throw new Error(body.error || `Country agent request failed (${response.status})`);
  return body as T;
}

export function CountryBlocking() {
  const {user} = useAuth();
  const [instances,setInstances] = useState<Instance[]>([]);
  const [instance,setInstance] = useState('');
  const [status,setStatus] = useState<AgentStatus|null>(null);
  const [selected,setSelected] = useState<string[]>([]);
  const [search,setSearch] = useState('');
  const [busy,setBusy] = useState(false);
  const [error,setError] = useState('');
  const [notice,setNotice] = useState('');
  const [preview,setPreview] = useState<Preview|null>(null);
  const [confirmedSelection,setConfirmedSelection] = useState('');
  const signature = [...selected].sort().join(',');
  const ready = !!status && status.mode === 'enforcement';
  const matches = useMemo(() => COUNTRIES.filter((country) =>
    country.name.toLowerCase().includes(search.trim().toLowerCase()) ||
    country.code.toLowerCase().includes(search.trim().toLowerCase())), [search]);

  useEffect(() => {
    let cancelled=false;
    fetchConfig().then((config)=>{
      if (cancelled) return;
      const found=(config.instances||[]).map(({id,name})=>({id,name}));
      setInstances(found);
      setInstance(found[0]?.id || '');
    }).catch(()=>{if(!cancelled)setError('Cannot load configured servers');});
    return ()=>{cancelled=true;};
  },[]);
  useEffect(()=>{
    if(!instance) return;
    let cancelled=false;
    void agentCall<AgentStatus>(instance,'status')
      .then((value)=>{if(!cancelled){setStatus(value);setSelected(value.countries||[]);}})
      .catch((reason:unknown)=>{if(!cancelled)setError(reason instanceof Error?reason.message:'Agent unavailable');});
    return ()=>{cancelled=true;};
  },[instance]);

  const toggle = (code:string) => {
    setSelected((current)=>current.includes(code)?current.filter(x=>x!==code):[...current,code]);
    setPreview(null);setConfirmedSelection('');setNotice('');
  };
  const review = async () => {
    if (!instance || !ready) return;
    setBusy(true);setError('');setNotice('');
    try {
      const result=await agentCall<Preview>(instance,'preview',[...selected].sort());
      if(result.server_id!==instance || !result.dry_run || result.applied) throw new Error('Invalid agent preview response');
      setPreview(result);setConfirmedSelection(signature);
    } catch (reason) {setError(reason instanceof Error?reason.message:'Preview failed');}
    finally {setBusy(false);}
  };
  const apply = async () => {
    if(!instance || !ready || !preview || confirmedSelection!==signature || user?.role!=='admin')return;
    const name=instances.find(x=>x.id===instance)?.name||instance;
    if(!window.confirm(`Apply inbound country restrictions on ${name}?\n\n${selected.length?selected.map(code=>COUNTRIES.find(c=>c.code===code)?.name||code).join(', '):'REMOVE ALL COUNTRY BLOCKS'}\n\nThis affects all inbound ports, including SSH.`))return;
    setBusy(true);setError('');setNotice('');
    try {
      const result=await agentCall<AgentStatus>(instance,'apply',[...selected].sort());
      if(result.server_id!==instance || !result.applied) throw new Error('Agent did not confirm enforcement');
      const verified=await agentCall<AgentStatus>(instance,'status');
      if(verified.server_id!==instance || !verified.applied ||
         [...verified.countries].sort().join(',')!==signature) throw new Error('Applied policy failed verification');
      setStatus(verified);setSelected(verified.countries);setPreview(null);setConfirmedSelection('');
      setNotice('Country policy applied and verified on the selected server.');
    } catch(reason){setError(reason instanceof Error?reason.message:'Apply failed — verify server status');}
    finally {setBusy(false);}
  };
  return <div className="mx-auto w-full max-w-5xl space-y-5 pb-8">
    <div className="flex items-center gap-3">
      <Globe2 className="h-7 w-7 text-primary-600" aria-hidden="true"/>
      <div><h1 className="text-2xl font-semibold text-gray-900 dark:text-white">Country Blocking</h1>
      <p className="text-sm text-gray-500">Block selected countries across all inbound ports, IPv4 and IPv6.</p></div>
    </div>
    {error && <div role="alert" className="rounded-lg border border-red-300 bg-red-50 p-3 text-sm text-red-900 dark:border-red-800 dark:bg-red-950 dark:text-red-100">{error}</div>}
    {notice && <div role="status" className="rounded-lg border border-green-300 bg-green-50 p-3 text-sm text-green-900 dark:border-green-800 dark:bg-green-950 dark:text-green-100">{notice}</div>}
    <Card><CardHeader><CardTitle className="flex items-center gap-2"><Server className="h-5 w-5"/> Server</CardTitle></CardHeader>
      <CardContent><label className="mb-2 block text-sm font-medium" htmlFor="country-target">Select server</label>
        <select id="country-target" value={instance} disabled={busy||!instances.length} onChange={e=>{setStatus(null);setSelected([]);setPreview(null);setConfirmedSelection('');setError('');setNotice('');setInstance(e.target.value);}}
          className="w-full max-w-md rounded border border-gray-300 bg-white p-2 text-gray-900 dark:border-gray-600 dark:bg-gray-800 dark:text-white">
          {!instances.length && <option value="">No configured servers</option>}
          {instances.map(item=><option key={item.id} value={item.id}>{item.name}</option>)}
        </select>
        <p className="mt-2 text-sm text-gray-500">{ready ? (status?.enforcement_enabled
          ? `Enforcing ${status?.countries.length||0} selected countries` : 'No country blocks currently active')
          : 'Firewall agent not connected or not enabled for this server'}</p>
        {status?.updated_at && <p className="mt-1 text-xs text-gray-500">Last change: {new Date(status.updated_at).toLocaleString()}</p>}
      </CardContent>
    </Card>
    <Card><CardHeader><CardTitle className="flex items-center gap-2"><ShieldBan className="h-5 w-5"/> Country selection</CardTitle></CardHeader>
      <CardContent><label htmlFor="country-search" className="mb-2 block text-sm font-medium">Find country</label>
        <div className="relative max-w-md"><Search className="absolute left-3 top-2.5 h-4 w-4 text-gray-400" aria-hidden="true"/>
        <input id="country-search" value={search} onChange={e=>setSearch(e.target.value)} placeholder="Country name or ISO code"
          className="w-full rounded border border-gray-300 bg-white py-2 pl-9 pr-3 text-gray-900 dark:border-gray-600 dark:bg-gray-800 dark:text-white"/>
        </div>
        <p className="mt-2 text-xs text-gray-500">Selected: {selected.length} / 30 maximum. Changes do not take effect until Apply.</p>
        <div className="mt-3 max-h-72 overflow-y-auto divide-y divide-gray-100 dark:divide-gray-700">
          {matches.map(country=><label key={country.code} className="flex cursor-pointer items-center justify-between py-2.5 text-sm">
            <span>{country.name} <span className="text-gray-500">({country.code})</span></span>
            <input type="checkbox" disabled={!ready||busy||user?.role!=='admin'||(!selected.includes(country.code)&&selected.length>=30)}
              checked={selected.includes(country.code)} onChange={()=>toggle(country.code)} className="h-4 w-4"/>
          </label>)}
          {!matches.length&&<p className="py-3 text-sm text-gray-500">No matching country.</p>}
        </div>
      </CardContent>
    </Card>
    <Card><CardHeader><CardTitle>Review and apply</CardTitle></CardHeader><CardContent>
      <p className="text-sm text-gray-600 dark:text-gray-300">
        {selected.length ? selected.map(code=>COUNTRIES.find(country=>country.code===code)?.name||code).join(', ') : 'No countries selected — applying this selection removes all country blocks.'}
      </p>
      {preview && confirmedSelection===signature && <p className="mt-3 text-sm text-gray-600 dark:text-gray-300">
        Verified preview: {preview.counts.ipv4.toLocaleString()} IPv4 ranges and {preview.counts.ipv6.toLocaleString()} IPv6 ranges.
      </p>}
      <div className="mt-4 flex flex-wrap gap-3">
        <button type="button" onClick={review} disabled={busy||!ready||user?.role!=='admin'}
          className="inline-flex items-center gap-2 rounded bg-primary-600 px-4 py-2 text-sm font-medium text-white disabled:opacity-40"><RefreshCw className="h-4 w-4"/> Preview changes</button>
        <button type="button" onClick={apply} disabled={busy||!ready||!preview||confirmedSelection!==signature||user?.role!=='admin'}
          className="rounded bg-red-700 px-4 py-2 text-sm font-medium text-white disabled:opacity-40">
          {busy?'Processing…':'Apply to server'}
        </button>
      </div>
      <p className="mt-3 flex items-start gap-2 text-xs text-amber-700 dark:text-amber-300">
        <AlertTriangle className="mt-0.5 h-4 w-4 shrink-0" aria-hidden="true"/>
        Blocking takes priority over the OpenGov and CrowdSec firewalls. No port or application exemptions are made.
      </p>
    </CardContent></Card>
  </div>;
}
