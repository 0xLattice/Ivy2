// The core as a WebAssembly module: loading it, and stepping a core with
// encoded events. Sources/IvyWasm/main.swift is the other side of this ABI.

import {
  type Effect,
  type Event,
  type IvyConfig,
  type PeerEndpoint,
  type PeerID,
  decodeEffects,
  decodeEndpoints,
  decodePeers,
  encodeConfig,
  encodeEvent,
} from './codec.js';

/// The instant a step runs at. The module has no clock of its own.
export interface Timestamp {
  /// Monotonic, from any origin.
  uptimeNanoseconds: bigint;
  unixSeconds: bigint;
}

interface Exports {
  memory: WebAssembly.Memory;
  _initialize(): void;
  ivy_alloc(length: number): number;
  ivy_free(pointer: number): void;
  ivy_write_high_water_mark(): number;
  ivy_core_create(pointer: number, length: number): number;
  ivy_core_destroy(handle: number): void;
  ivy_core_step(
    handle: number,
    pointer: number,
    length: number,
    uptimeNanoseconds: bigint,
    unixSeconds: bigint,
  ): number;
  ivy_core_public_key(handle: number): number;
  ivy_core_connected_peers(handle: number): number;
  ivy_core_connected_peer_endpoints(handle: number): number;
  ivy_core_known_peer_endpoints(handle: number): number;
  ivy_core_providers(handle: number, pointer: number, length: number): number;
}

const errnoBadDescriptor = 8;
const errnoNotSupported = 52;

/// The WASI imports the module links against. It needs randomness and
/// somewhere to print a trap's message. Everything else is refused, and a
/// read of the clock throws: the module is given the time, and a step that
/// looked for it elsewhere would not be repeatable.
function wasiImports(module: WebAssembly.Module, memory: () => WebAssembly.Memory) {
  const view = () => new DataView(memory().buffer);
  const implemented: Record<string, (...args: number[]) => number> = {
    random_get(pointer, length) {
      const bytes = new Uint8Array(memory().buffer, pointer, length);
      // getRandomValues takes at most 64 KiB a call.
      for (let offset = 0; offset < length; offset += 65536) {
        crypto.getRandomValues(bytes.subarray(offset, Math.min(offset + 65536, length)));
      }
      return 0;
    },
    fd_write(_descriptor, vectors, count, written) {
      let message = '';
      let total = 0;
      for (let index = 0; index < count; index++) {
        const pointer = view().getUint32(vectors + index * 8, true);
        const length = view().getUint32(vectors + index * 8 + 4, true);
        message += new TextDecoder().decode(new Uint8Array(memory().buffer, pointer, length));
        total += length;
      }
      if (message.trim() !== '') console.error(message.trimEnd());
      view().setUint32(written, total, true);
      return 0;
    },
    args_sizes_get(count, size) {
      view().setUint32(count, 0, true);
      view().setUint32(size, 0, true);
      return 0;
    },
    environ_sizes_get(count, size) {
      view().setUint32(count, 0, true);
      view().setUint32(size, 0, true);
      return 0;
    },
    args_get: () => 0,
    environ_get: () => 0,
    // No preopened directories.
    fd_prestat_get: () => errnoBadDescriptor,
    clock_time_get() {
      throw new Error('the Ivy module read a clock');
    },
    proc_exit(code) {
      throw new Error(`the Ivy module exited with code ${code}`);
    },
  };
  const imports: Record<string, (...args: number[]) => number> = {};
  for (const entry of WebAssembly.Module.imports(module)) {
    if (entry.module !== 'wasi_snapshot_preview1') {
      throw new Error(`the Ivy module imports ${entry.module}.${entry.name}`);
    }
    imports[entry.name] = implemented[entry.name] ?? (() => errnoNotSupported);
  }
  return { wasi_snapshot_preview1: imports };
}

/// One instance of the module. Any number of cores live in it.
export class IvyModule {
  /// Bytes a connection may be written before the core waits for `writable`.
  readonly writeHighWaterMark: number;

  private constructor(private readonly exports: Exports) {
    this.writeHighWaterMark = exports.ivy_write_high_water_mark();
  }

  /// Loads the module from its bytes, or from one already compiled.
  static async load(source: BufferSource | WebAssembly.Module): Promise<IvyModule> {
    const module =
      source instanceof WebAssembly.Module ? source : await WebAssembly.compile(source);
    let exports: Exports | undefined;
    const instance = await WebAssembly.instantiate(
      module,
      wasiImports(module, () => exports!.memory),
    );
    exports = instance.exports as unknown as Exports;
    exports._initialize();
    return new IvyModule(exports);
  }

  /// Throws if the configuration is not one the core accepts.
  createCore(config: IvyConfig): Core {
    const handle = this.withInput(encodeConfig(config), (pointer, length) =>
      this.exports.ivy_core_create(pointer, length),
    );
    if (handle === 0) throw new Error('the configuration is not valid');
    return new Core(this, handle);
  }

  private withInput<Value>(bytes: Uint8Array, call: (pointer: number, length: number) => Value): Value {
    if (bytes.length === 0) return call(0, 0);
    const pointer = this.exports.ivy_alloc(bytes.length) >>> 0;
    new Uint8Array(this.exports.memory.buffer, pointer, bytes.length).set(bytes);
    try {
      return call(pointer, bytes.length);
    } finally {
      this.exports.ivy_free(pointer);
    }
  }

  /// Reads a returned block: a little-endian length, then the bytes. The
  /// view is of the module's memory and is gone once the block is freed.
  private withBlock<Value>(pointer: number, read: (bytes: Uint8Array) => Value): Value {
    pointer >>>= 0;
    if (pointer === 0) throw new Error('the Ivy module refused the call');
    try {
      const buffer = this.exports.memory.buffer;
      const length = new DataView(buffer).getUint32(pointer, true);
      return read(new Uint8Array(buffer, pointer + 4, length));
    } finally {
      this.exports.ivy_free(pointer);
    }
  }

  /** @internal */
  step(handle: number, event: Event, now: Timestamp): Effect[] {
    const pointer = this.withInput(encodeEvent(event), (pointer, length) =>
      this.exports.ivy_core_step(handle, pointer, length, now.uptimeNanoseconds, now.unixSeconds),
    );
    return this.withBlock(pointer, decodeEffects);
  }

  /** @internal */
  query<Value>(
    name: 'public_key' | 'connected_peers' | 'connected_peer_endpoints' | 'known_peer_endpoints',
    handle: number,
    read: (bytes: Uint8Array) => Value,
  ): Value {
    return this.withBlock(this.exports[`ivy_core_${name}`](handle), read);
  }

  /** @internal */
  providers(handle: number, rootCID: string): PeerID[] {
    const pointer = this.withInput(new TextEncoder().encode(rootCID), (pointer, length) =>
      this.exports.ivy_core_providers(handle, pointer, length),
    );
    return this.withBlock(pointer, decodePeers);
  }

  /** @internal */
  destroy(handle: number) {
    this.exports.ivy_core_destroy(handle);
  }
}

/// One `IvyCore`: events in, effects out. It does nothing until stepped.
export class Core {
  /// The node's 32-byte Ed25519 public key.
  readonly publicKey: Uint8Array;

  /** @internal */
  constructor(
    private readonly module: IvyModule,
    private readonly handle: number,
  ) {
    this.publicKey = module.query('public_key', handle, (bytes) => bytes.slice());
  }

  step(event: Event, now: Timestamp): Effect[] {
    return this.module.step(this.handle, event, now);
  }

  get connectedPeers(): PeerID[] {
    return this.module.query('connected_peers', this.handle, decodePeers);
  }

  get connectedPeerEndpoints(): PeerEndpoint[] {
    return this.module.query('connected_peer_endpoints', this.handle, decodeEndpoints);
  }

  get knownPeerEndpoints(): PeerEndpoint[] {
    return this.module.query('known_peer_endpoints', this.handle, decodeEndpoints);
  }

  /// The peers with an unexpired provider record for `rootCID`.
  providers(rootCID: string): PeerID[] {
    return this.module.providers(this.handle, rootCID);
  }

  /// Frees the core. Stepping it afterwards throws.
  destroy() {
    this.module.destroy(this.handle);
  }
}
