/** Messages and structures shared between the editor and the PSD import worker. */
import type { BlendMode } from '../model/types';

export interface ImportNode {
  /** path of indices from the root, e.g. "0/3/1" — stable id for this parse */
  key: string;
  name: string;
  kind: 'group' | 'layer';
  visible: boolean;
  opacity: number;
  blendMode: BlendMode;
  clipping: boolean;
  left: number;
  top: number;
  width: number;
  height: number;
  /** why this node cannot be imported (adjustment layer, empty...), if so */
  skipReason?: string;
  children?: ImportNode[];
}

export interface PsdStructure {
  width: number;
  height: number;
  bitsPerChannel: number;
  colorMode: number;
  tree: ImportNode[];
  layerCount: number;
  warnings: string[];
}

export interface DecodedImage {
  key: string;
  /** crop offset relative to the PSD layer's own bounds */
  left: number;
  top: number;
  width: number;
  height: number;
  png: ArrayBuffer;
}

export type ToWorker = { type: 'parse'; buffer: ArrayBuffer } | { type: 'decode'; keys: string[] } | { type: 'dispose' };

export type FromWorker =
  | { type: 'structure'; structure: PsdStructure }
  | { type: 'progress'; done: number; total: number; name: string }
  | { type: 'image'; image: DecodedImage }
  | { type: 'decoded'; warnings: string[] }
  | { type: 'error'; message: string };
