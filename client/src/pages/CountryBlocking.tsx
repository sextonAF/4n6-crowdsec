import { useEffect, useMemo, useState } from 'react';
import { AlertTriangle, Globe2, LockKeyhole, Search, Server, ShieldBan } from 'lucide-react';
import { Card, CardContent, CardHeader, CardTitle } from '../components/ui/Card';
import { fetchConfig } from '../lib/api';
import { useAuth } from '../contexts/AuthContext';

const COUNTRIES = [
  { code: 'CN', name: 'China' },
  { code: 'RU', name: 'Russia' },
  { code: 'KP', name: 'North Korea' },
  { code: 'IR', name: 'Iran' },
  { code: 'BY', name: 'Belarus' },
  { code: 'VN', name: 'Vietnam' },
] as const;

type Instance = { id: string; name: string };

export function CountryBlocking() {
  const { user } = useAuth();
  const [instances, setInstances] = useState<Instance[]>([]);
  const [selectedInstance, setSelectedInstance] = useState('');
  const [loadError, setLoadError] = useState('');
  const [search, setSearch] = useState('');
  const [drafts, setDrafts] = useState<Record<string, string[]>>({});

  useEffect(() => {
    let cancelled = false;
    void fetchConfig()
      .then((config) => {
        if (cancelled) return;
        const available = (config.instances ?? []).map(({ id, name }) => ({ id, name }));
        setInstances(available);
        setSelectedInstance((previous) => previous || available[0]?.id || '');
      })
      .catch(() => {
        if (!cancelled) setLoadError('Unable to load the configured servers.');
      });
    return () => { cancelled = true; };
  }, []);

  const selected = drafts[selectedInstance] ?? [];
  const matches = useMemo(
    () => COUNTRIES.filter(({ code, name }) =>
      code.toLowerCase().includes(search.trim().toLowerCase())
      || name.toLowerCase().includes(search.trim().toLowerCase())),
    [search],
  );

  const toggle = (code: string) => {
    setDrafts((current) => {
      const previous = current[selectedInstance] ?? [];
      const next = previous.includes(code)
        ? previous.filter((item) => item !== code)
        : [...previous, code];
      return { ...current, [selectedInstance]: next };
    });
  };

  return (
    <div className="mx-auto w-full max-w-5xl space-y-6 pb-8">
      <div>
        <div className="flex items-center gap-3">
          <Globe2 aria-hidden="true" className="h-7 w-7 text-primary-600 dark:text-primary-400" />
          <h1 className="text-2xl font-semibold text-gray-900 dark:text-white">Country Blocking</h1>
        </div>
        <p className="mt-2 text-sm text-gray-600 dark:text-gray-400">
          Configure inbound geographic firewall restrictions separately for each server.
        </p>
      </div>

      <div role="status" className="flex items-start gap-3 rounded-lg border border-amber-300 bg-amber-50 p-4 text-sm text-amber-950 dark:border-amber-800 dark:bg-amber-950/30 dark:text-amber-100">
        <AlertTriangle aria-hidden="true" className="mt-0.5 h-5 w-5 shrink-0" />
        <div>
          <p className="font-semibold">Configuration preview — firewall integration not installed</p>
          <p className="mt-1">
            Changes on this page stay in this browser session. No country blocks are currently applied or managed by this feature.
            The Apply action will remain unavailable until the authenticated server agent and verification are complete.
          </p>
        </div>
      </div>

      <Card>
        <CardHeader>
          <CardTitle className="flex items-center gap-2"><Server className="h-5 w-5" aria-hidden="true" /> Server</CardTitle>
        </CardHeader>
        <CardContent>
          {loadError ? <p role="alert" className="text-sm text-red-600">{loadError}</p> : null}
          <label htmlFor="country-blocking-instance" className="mb-2 block text-sm font-medium text-gray-700 dark:text-gray-300">
            Choose a server
          </label>
          <select
            id="country-blocking-instance"
            value={selectedInstance}
            onChange={(event) => setSelectedInstance(event.target.value)}
            disabled={instances.length === 0}
            className="w-full max-w-md rounded-lg border border-gray-300 bg-white px-3 py-2 text-gray-900 dark:border-gray-600 dark:bg-gray-800 dark:text-white"
          >
            {instances.length === 0 ? <option value="">No servers available</option> : null}
            {instances.map((instance) => <option key={instance.id} value={instance.id}>{instance.name}</option>)}
          </select>
          <p className="mt-2 text-xs text-gray-500 dark:text-gray-400">
            Each server has an independent draft. Switching servers does not apply changes.
          </p>
        </CardContent>
      </Card>

      <Card>
        <CardHeader>
          <CardTitle className="flex items-center gap-2"><ShieldBan className="h-5 w-5" aria-hidden="true" /> Countries</CardTitle>
        </CardHeader>
        <CardContent>
          <label htmlFor="country-blocking-search" className="mb-2 block text-sm font-medium text-gray-700 dark:text-gray-300">Find a country</label>
          <div className="relative max-w-md">
            <Search className="pointer-events-none absolute left-3 top-2.5 h-5 w-5 text-gray-400" aria-hidden="true" />
            <input
              id="country-blocking-search"
              type="search"
              value={search}
              onChange={(event) => setSearch(event.target.value)}
              placeholder="Search country name or code"
              className="w-full rounded-lg border border-gray-300 bg-white py-2 pl-10 pr-3 text-gray-900 dark:border-gray-600 dark:bg-gray-800 dark:text-white"
            />
          </div>
          <div className="mt-4 divide-y divide-gray-100 dark:divide-gray-700">
            {matches.map(({ code, name }) => (
              <label key={code} className="flex cursor-pointer items-center justify-between gap-3 py-3 text-sm text-gray-900 dark:text-gray-100">
                <span>{name} <span className="ml-1 text-gray-500 dark:text-gray-400">({code})</span></span>
                <input
                  type="checkbox"
                  disabled={!selectedInstance || user?.role !== 'admin'}
                  checked={selected.includes(code)}
                  onChange={() => toggle(code)}
                  className="h-4 w-4 rounded border-gray-300 text-primary-600"
                />
              </label>
            ))}
            {matches.length === 0 ? <p className="py-4 text-sm text-gray-500">No matching countries.</p> : null}
          </div>
        </CardContent>
      </Card>

      <Card>
        <CardHeader>
          <CardTitle>Pending draft</CardTitle>
        </CardHeader>
        <CardContent>
          <p className="text-sm text-gray-700 dark:text-gray-300">
            {selected.length === 0 ? 'No countries selected.' : selected.map((code) =>
              COUNTRIES.find((country) => country.code === code)?.name ?? code).join(', ')}
          </p>
          <p className="mt-2 text-sm text-gray-500 dark:text-gray-400">
            No IPv4/IPv6 ranges have been fetched, and no enforcement status is available.
          </p>
          <button
            type="button"
            disabled
            title="Firewall agent not configured"
            className="mt-4 inline-flex cursor-not-allowed items-center gap-2 rounded-lg bg-gray-200 px-4 py-2 text-sm font-medium text-gray-500 dark:bg-gray-700 dark:text-gray-400"
          >
            <LockKeyhole aria-hidden="true" className="h-4 w-4" /> Apply country blocks — unavailable
          </button>
        </CardContent>
      </Card>
    </div>
  );
}
