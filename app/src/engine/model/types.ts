/**
 * OpenLive project model, format version 1 (Milestone 1).
 *
 * The document is a normalized map of nodes. Groups ("Parts") hold ordered
 * children, top-to-bottom as in Photoshop; layers reference an image asset by
 * id. Pixel data never lives in the document: assets are stored separately
 * (IndexedDB / zip entries) so the document stays small and cheap to snapshot
 * for undo.
 */
export type Id = string;

export type BlendMode = 'normal' | 'multiply' | 'additive';

export interface NodeBase {
  id: Id;
  name: string;
  parentId: Id | null;
  visible: boolean;
  locked: boolean;
  /** 0..1 */
  opacity: number;
}

/** A group of nodes ("Part"); imported from PSD groups. */
export interface GroupNode extends NodeBase {
  kind: 'group';
  childIds: Id[];
  /** UI-only: whether the hierarchy row is expanded. */
  expanded: boolean;
}

/** A pixel layer: an image placed on the canvas. Becomes an ArtMesh source in M2. */
export interface LayerNode extends NodeBase {
  kind: 'layer';
  imageId: Id;
  /** top-left position on the canvas (px) */
  x: number;
  y: number;
  width: number;
  height: number;
  blendMode: BlendMode;
  /** PSD clipping flag (preserved; rendered as clipping mask from M2). */
  clipping: boolean;
}

export type Node = GroupNode | LayerNode;

export interface Doc {
  formatVersion: 1;
  id: Id;
  name: string;
  width: number;
  height: number;
  nodes: Record<Id, Node>;
  /** root children, top-to-bottom */
  rootIds: Id[];
  createdAt: string;
  updatedAt: string;
}

/** Image asset: cropped PNG bytes plus its size. */
export interface Asset {
  id: Id;
  width: number;
  height: number;
  mime: 'image/png' | 'image/jpeg';
  bytes: ArrayBuffer;
}

export const FORMAT_VERSION = 1 as const;
