// Where a node keeps the Volumes it serves: IndexedDB in a browser, memory
// in Node and in tests. Both hold whole Volumes by root within a budget of
// bytes, and make room by dropping the Volume served longest ago.

import type { AuthenticatedPeer, ContentEntry } from './codec.js';
import type { ContentSource } from './shell.js';

export interface VolumeStoreOptions {
  /// The most the stored Volumes may add up to, each counted as the archive
  /// it is sent as.
  budget: number;
  /// Whether `peer` may read the Volume. Left out: anyone may.
  authorizes?: (peer: AuthenticatedPeer, rootCID: string) => boolean | Promise<boolean>;
}

/// A `ContentSource` that is also written to.
export interface VolumeStore extends Required<ContentSource> {
  /// Stores the complete Volume rooted at `rootCID`, the root's own entry
  /// included, in place of any already there. Volumes served longest ago
  /// are dropped to make room. Rejects with a `RangeError` when the Volume
  /// alone is over the budget.
  put(rootCID: string, entries: ContentEntry[]): Promise<void>;
  has(rootCID: string): Promise<boolean>;
  /// Drops the Volume and its bundle.
  delete(rootCID: string): Promise<void>;
  roots(): Promise<string[]>;
  /// Names the Volumes bundled under `rootCID`, its own first. The bundle
  /// lasts as long as that Volume: false, and nothing stored, without it.
  putBundle(rootCID: string, roots: string[]): Promise<boolean>;
}

/// What is kept of a Volume beside its entries.
interface VolumeRecord {
  root: string;
  bytes: number;
  /// When it was last served or stored; larger is later.
  served: number;
  bundle: string[];
}

/// The size of the archive a Volume is sent as, which is what the core's
/// `maxDataBytes` bounds: a count, then each entry's identifier and data
/// with their lengths. Identifiers are ASCII.
export function volumeArchiveBytes(entries: ContentEntry[]): number {
  let bytes = 2;
  for (const entry of entries) bytes += 2 + entry.cid.length + 4 + entry.data.length;
  return bytes;
}

/// The Volumes to drop, least recently served first, so that one of `bytes`
/// at `root` fits in `budget` beside the rest.
function evictions(records: VolumeRecord[], root: string, bytes: number, budget: number): string[] {
  if (bytes > budget) throw new RangeError(`a Volume of ${bytes} bytes is over the budget of ${budget}`);
  const others = records.filter((record) => record.root !== root).sort((a, b) => a.served - b.served);
  let total = others.reduce((sum, record) => sum + record.bytes, bytes);
  const dropped: string[] = [];
  for (const record of others) {
    if (total <= budget) break;
    total -= record.bytes;
    dropped.push(record.root);
  }
  return dropped;
}

abstract class Store {
  private lastServed = 0;

  constructor(protected readonly options: VolumeStoreOptions) {}

  /// Later than every time this store has given, also when the clock is not.
  protected now(): number {
    this.lastServed = Math.max(Date.now(), this.lastServed + 1);
    return this.lastServed;
  }

  async authorizesVolumeRequest(peer: AuthenticatedPeer, rootCID: string): Promise<boolean> {
    return (await this.options.authorizes?.(peer, rootCID)) ?? true;
  }
}

export class MemoryContentSource extends Store implements VolumeStore {
  private readonly volumes = new Map<string, VolumeRecord & { entries: ContentEntry[] }>();

  async put(rootCID: string, entries: ContentEntry[]) {
    const bytes = volumeArchiveBytes(entries);
    for (const root of evictions([...this.volumes.values()], rootCID, bytes, this.options.budget)) {
      this.volumes.delete(root);
    }
    const bundle = this.volumes.get(rootCID)?.bundle ?? [];
    this.volumes.set(rootCID, { root: rootCID, bytes, served: this.now(), bundle, entries });
  }

  async has(rootCID: string) {
    return this.volumes.has(rootCID);
  }

  async delete(rootCID: string) {
    this.volumes.delete(rootCID);
  }

  async roots() {
    return [...this.volumes.keys()];
  }

  async putBundle(rootCID: string, roots: string[]) {
    const volume = this.volumes.get(rootCID);
    if (volume !== undefined) volume.bundle = roots;
    return volume !== undefined;
  }

  async volume(rootCID: string, maxDataBytes: number, signal: AbortSignal) {
    const volume = this.volumes.get(rootCID);
    if (volume === undefined || volume.bytes > maxDataBytes || signal.aborted) return [];
    volume.served = this.now();
    return volume.entries;
  }

  async volumeBundle(rootCID: string) {
    return this.volumes.get(rootCID)?.bundle ?? [];
  }
}

const result = <T>(request: IDBRequest<T>): Promise<T> =>
  new Promise((resolve, reject) => {
    request.onsuccess = () => resolve(request.result);
    request.onerror = () => reject(request.error);
  });

/// Volumes in an IndexedDB database of the page's origin. Two stores, both
/// keyed by root: `volumes` holds a record of each, small enough to read
/// them all when making room, and `entries` holds its entries.
export class IndexedDBContentSource extends Store implements VolumeStore {
  private constructor(
    private readonly database: IDBDatabase,
    options: VolumeStoreOptions,
  ) {
    super(options);
  }

  /// Opens the database `name`, making it if it is not there.
  static async open(name: string, options: VolumeStoreOptions): Promise<IndexedDBContentSource> {
    const request = indexedDB.open(name, 1);
    request.onupgradeneeded = () => {
      request.result.createObjectStore('volumes', { keyPath: 'root' });
      request.result.createObjectStore('entries');
    };
    return new IndexedDBContentSource(await result(request), options);
  }

  close() {
    this.database.close();
  }

  /// Runs `body` in one transaction over both stores and resolves with what
  /// it returned once the transaction has committed. Aborting `signal`
  /// aborts the transaction, which rejects.
  private transact<T>(
    mode: IDBTransactionMode,
    body: (volumes: IDBObjectStore, entries: IDBObjectStore) => Promise<T>,
    signal?: AbortSignal,
  ): Promise<T> {
    return new Promise((resolve, reject) => {
      const transaction = this.database.transaction(['volumes', 'entries'], mode);
      const abort = () => transaction.abort();
      signal?.addEventListener('abort', abort);
      const settled = () => signal?.removeEventListener('abort', abort);
      let value: T;
      transaction.oncomplete = () => (settled(), resolve(value));
      transaction.onabort = () => (settled(), reject(transaction.error ?? new Error('aborted')));
      body(transaction.objectStore('volumes'), transaction.objectStore('entries')).then(
        (returned) => (value = returned),
        (error: unknown) => {
          reject(error);
          // Already aborted when the failure was a request of its own.
          try {
            transaction.abort();
          } catch {}
        },
      );
    });
  }

  put(rootCID: string, entries: ContentEntry[]) {
    const bytes = volumeArchiveBytes(entries);
    // An array that is a view of a larger buffer is stored as the whole of
    // that buffer, so it is copied down to its own bytes first.
    const stored = entries.map(({ cid, data }) => ({
      cid,
      data: data.byteLength === data.buffer.byteLength ? data : data.slice(),
    }));
    return this.transact('readwrite', async (volumes, entryStore) => {
      const records: VolumeRecord[] = await result(volumes.getAll());
      for (const root of evictions(records, rootCID, bytes, this.options.budget)) {
        volumes.delete(root);
        entryStore.delete(root);
      }
      const bundle = records.find((record) => record.root === rootCID)?.bundle ?? [];
      volumes.put({ root: rootCID, bytes, served: this.now(), bundle } satisfies VolumeRecord);
      entryStore.put(stored, rootCID);
    });
  }

  has(rootCID: string) {
    return this.transact('readonly', async (volumes) => (await result(volumes.count(rootCID))) > 0);
  }

  delete(rootCID: string) {
    return this.transact('readwrite', async (volumes, entries) => {
      volumes.delete(rootCID);
      entries.delete(rootCID);
    });
  }

  roots() {
    return this.transact('readonly', async (volumes) => (await result(volumes.getAllKeys())) as string[]);
  }

  putBundle(rootCID: string, roots: string[]) {
    return this.transact('readwrite', async (volumes) => {
      const record: VolumeRecord | undefined = await result(volumes.get(rootCID));
      if (record !== undefined) volumes.put({ ...record, bundle: roots });
      return record !== undefined;
    });
  }

  async volume(rootCID: string, maxDataBytes: number, signal: AbortSignal): Promise<ContentEntry[]> {
    if (signal.aborted) return [];
    const read = this.transact(
      'readwrite',
      async (volumes, entries) => {
        const record: VolumeRecord | undefined = await result(volumes.get(rootCID));
        if (record === undefined || record.bytes > maxDataBytes) return [];
        volumes.put({ ...record, served: this.now() });
        return result<ContentEntry[]>(entries.get(rootCID));
      },
      signal,
    );
    // The core no longer wants the answer.
    return read.catch((error: unknown) => {
      if (signal.aborted) return [];
      throw error;
    });
  }

  volumeBundle(rootCID: string) {
    return this.transact('readonly', async (volumes) => {
      const record: VolumeRecord | undefined = await result(volumes.get(rootCID));
      return record?.bundle ?? [];
    });
  }
}
