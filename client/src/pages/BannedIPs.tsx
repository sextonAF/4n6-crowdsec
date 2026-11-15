import { useCallback, useEffect, useMemo, useState } from 'react';
import { Ban, RefreshCw, Search, ShieldBan } from 'lucide-react';
import { fetchConfig, fetchDecisionsPaginated, deleteDecision } from '../lib/api';
import { Card, CardContent, CardHeader, CardTitle } from '../components/ui/Card';
import { Modal } from '../components/ui/Modal';
import { AddDecisionModal } from '../components/AddDecisionModal';
import type { DecisionListItem, InstanceSummary } from '../types';

const PAGE_SIZE = 50;
const ACTIVE_BAN_QUERY = 'type:ban AND status:active AND origin:cscli';

export function BannedIPs() {
  const [instances, setInstances] = useState<InstanceSummary[]>([]);
  const [canManage, setCanManage] = useState(false);
  const [scope, setScope] = useState('all');
  const [page, setPage] = useState(1);
  const [records, setRecords] = useState<DecisionListItem[]>([]);
  const [total, setTotal] = useState(0);
  const [loading, setLoading] = useState(true);
  const [refreshKey, setRefreshKey] = useState(0);
  const [search, setSearch] = useState('');
  const [showAdd, setShowAdd] = useState(false);
  const [pendingUnban, setPendingUnban] = useState<DecisionListItem|null>(null);
  const [unbanning, setUnbanning] = useState(false);
  const [error, setError] = useState('');
  const [notice, setNotice] = useState('');

  useEffect(() => {
    let cancelled=false;
    void fetchConfig().then(config=>{
      if(cancelled)return;
      setInstances(config.instances||[]);
      setCanManage(config.permissions?.can_manage_enforcement===true);
    }).catch(()=>{if(!cancelled)setError('Unable to load CrowdSec server configuration.');});
    return ()=>{cancelled=true;};
  },[]);

  useEffect(() => {
    let cancelled=false;
    void fetchDecisionsPaginated(page,PAGE_SIZE,{
      q:ACTIVE_BAN_QUERY, instance:scope, hide_duplicates:'false',
    }).then(result=>{
      if(cancelled)return;
      setRecords(result.data.filter(item=>!item.expired && item.detail?.type?.toLowerCase()==='ban'));
      setTotal(result.pagination.total);
      setLoading(false);
    }).catch((reason:unknown)=>{
      if(cancelled)return;
      setLoading(false);
      setError(reason instanceof Error?reason.message:'Unable to load the banned-IP list.');
    });
    return ()=>{cancelled=true;};
  },[scope,page,refreshKey]);

  const reload=useCallback(()=>{setLoading(true);setRefreshKey(value=>value+1);},[]);
  const visible=useMemo(()=>{
    const q=search.trim().toLowerCase();
    return q ? records.filter(item=>(item.value||'').toLowerCase().includes(q) ||
      (item.instance_name||'').toLowerCase().includes(q) ||
      (item.detail?.reason||item.scenario||'').toLowerCase().includes(q)) : records;
  },[records,search]);
  const unban=async()=>{
    if(!pendingUnban || unbanning)return;
    setUnbanning(true);setError('');setNotice('');
    try{
      await deleteDecision(pendingUnban.id,pendingUnban.instance_id || undefined);
      setPendingUnban(null);
      setNotice('IP ban removed.');
      reload();
    }catch(reason){setError(reason instanceof Error?reason.message:'Could not remove IP ban.');}
    finally{setUnbanning(false);}
  };
  return <div className="mx-auto w-full max-w-5xl space-y-5 pb-8">
    <div className="flex flex-wrap items-center justify-between gap-3">
      <div className="flex items-center gap-3">
        <ShieldBan className="h-7 w-7 text-red-600" aria-hidden="true"/>
        <div>
          <h1 className="text-2xl font-semibold text-gray-900 dark:text-white">Banned IPs</h1>
          <p className="text-sm text-gray-500">Manually imposed IP bans. Automatic temporary bans remain on Decisions.</p>
        </div>
      </div>
      <div className="flex gap-2">
        <button type="button" onClick={reload} disabled={loading}
          className="inline-flex items-center gap-2 rounded-md border border-gray-300 px-3 py-2 text-sm dark:border-gray-600">
          <RefreshCw className="h-4 w-4"/> Refresh
        </button>
        {canManage && <button type="button" onClick={()=>setShowAdd(true)}
          className="inline-flex items-center gap-2 rounded-md bg-red-700 px-4 py-2 text-sm font-medium text-white">
          <Ban className="h-4 w-4"/> Ban IP
        </button>}
      </div>
    </div>
    <Card>
      <CardHeader><CardTitle>Manual bans ({total})</CardTitle></CardHeader>
      <CardContent>
        <div className="mb-4 flex flex-wrap gap-3">
          <label className="flex min-w-0 flex-1 flex-col gap-1 text-sm">
            <span>Search current page</span>
            <span className="relative">
              <Search className="absolute left-3 top-2.5 h-4 w-4 text-gray-400"/>
              <input value={search} onChange={e=>setSearch(e.target.value)} placeholder="IP, server, or reason"
                className="w-full rounded-md border border-gray-300 bg-white py-2 pl-9 pr-3 dark:border-gray-700 dark:bg-gray-800"/>
            </span>
          </label>
          <label className="flex min-w-48 flex-col gap-1 text-sm">
            <span>Server</span>
            <select value={scope} onChange={e=>{setScope(e.target.value);setPage(1);setLoading(true);}}
              className="rounded-md border border-gray-300 bg-white p-2 dark:border-gray-700 dark:bg-gray-800">
              <option value="all">All servers</option>
              {instances.map(item=><option key={item.id} value={item.id}>{item.name}</option>)}
            </select>
          </label>
        </div>
        <div className="overflow-x-auto">
          <table className="w-full min-w-[560px] text-left text-sm">
            <thead className="border-b border-gray-200 text-xs uppercase text-gray-500 dark:border-gray-700">
              <tr><th className="px-3 py-3">IP / range</th><th className="px-3 py-3">Server</th>
                <th className="px-3 py-3">Reason</th><th className="px-3 py-3">Expires</th>
                {canManage && <th className="px-3 py-3 text-right">Action</th>}</tr>
            </thead>
            <tbody>
              {!loading && visible.map(item=><tr key={String(item.instance_id||'')+':'+item.id}
                className="border-b border-gray-100 dark:border-gray-800">
                <td className="px-3 py-3 font-mono">{item.value||'—'}</td>
                <td className="px-3 py-3">{item.instance_name||instances.find(server=>server.id===item.instance_id)?.name||'—'}</td>
                <td className="px-3 py-3">{item.detail?.reason||item.scenario||'—'}</td>
                <td className="px-3 py-3">{item.detail?.expiration ? new Date(item.detail.expiration).toLocaleString() : '—'}</td>
                {canManage && <td className="px-3 py-3 text-right">
                  <button type="button" onClick={()=>setPendingUnban(item)}
                    className="rounded-md border border-red-300 px-3 py-1.5 text-red-700 hover:bg-red-50 dark:border-red-800 dark:text-red-300">
                    Unban
                  </button>
                </td>}
              </tr>)}
              {loading && <tr><td colSpan={canManage?5:4} className="px-3 py-8 text-center text-gray-500">Loading active IP bans…</td></tr>}
              {!loading && visible.length===0 && <tr><td colSpan={canManage?5:4} className="px-3 py-8 text-center text-gray-500">No manual bans match this view.</td></tr>}
            </tbody>
          </table>
        </div>
        <div className="mt-4 flex items-center justify-between gap-3 text-sm">
          <span className="text-gray-500">Page {page} of {Math.max(1,Math.ceil(total/PAGE_SIZE))}</span>
          <div className="flex gap-2">
            <button type="button" disabled={loading||page===1} onClick={()=>{setPage(value=>value-1);setLoading(true);}}
              className="rounded border border-gray-300 px-3 py-1.5 disabled:opacity-40 dark:border-gray-700">Previous</button>
            <button type="button" disabled={loading||page*PAGE_SIZE>=total} onClick={()=>{setPage(value=>value+1);setLoading(true);}}
              className="rounded border border-gray-300 px-3 py-1.5 disabled:opacity-40 dark:border-gray-700">Next</button>
          </div>
        </div>
      </CardContent>
    </Card>
    <Modal isOpen={!!error||!!notice} onClose={()=>{setError('');setNotice('');}}
      title={error?'Banned IPs — Error':'Banned IPs'}>
      <p className="text-sm">{error||notice}</p>
      <div className="mt-5 flex justify-end"><button type="button" onClick={()=>{setError('');setNotice('');}}
        className="rounded-md bg-blue-600 px-5 py-2 text-sm text-white">OK</button></div>
    </Modal>
    <Modal isOpen={pendingUnban!==null} onClose={()=>{if(!unbanning)setPendingUnban(null);}} title="Confirm unban">
      <p className="text-sm">Remove the ban on <strong className="font-mono">{pendingUnban?.value}</strong> from {pendingUnban?.instance_name||'the selected server'}?</p>
      <div className="mt-5 flex justify-end gap-2">
        <button type="button" disabled={unbanning} onClick={()=>setPendingUnban(null)}
          className="rounded border border-gray-300 px-4 py-2 dark:border-gray-700">Cancel</button>
        <button type="button" disabled={unbanning} onClick={()=>void unban()}
          className="rounded bg-red-700 px-4 py-2 text-white disabled:opacity-40">
          {unbanning?'Removing…':'Unban'}
        </button>
      </div>
    </Modal>
    {showAdd && <AddDecisionModal
      initialDecision={{ip:'',type:'ban',duration:'4h',reason:'manual'}}
      instances={instances}
      multipleInstances={instances.length>1}
      currentInstanceId={scope!=='all'?scope:undefined}
      currentInstanceName={instances.find(server=>server.id===scope)?.name}
      defaultAllInstances={scope==='all'}
      onClose={()=>setShowAdd(false)}
      onDecisionAdded={async()=>{reload();}}
    />}
  </div>;
}
