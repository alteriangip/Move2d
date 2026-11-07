/**
 * Native project file (.olive): a zip containing
 *   project.json            the Doc (format version 1) + asset index
 *   images/<assetId>.png    image bytes (or .jpg)
 * Only assets referenced by layers are written.
 */
import { zipSync, unzipSync, strToU8, strFromU8 } from 'fflate';
import type { Asset, Doc, Id } from '../model/types';
import { FORMAT_VERSION } from '../model/types';
import { referencedImages, validate } from '../model/ops';

interface ProjectJson {
  generator: string;
  formatVersion: number;
  doc: Doc;
  assets: { id: Id; width: number; height: number; mime: Asset['mime']; path: string }[];
}

export const GENERATOR = 'OpenLive 0.1';

export function writeProject(doc: Doc, assets: Map<Id, Asset>): Uint8Array {
  const used = referencedImages(doc);
  const files: Record<string, Uint8Array> = {};
  const index: ProjectJson['assets'] = [];
  for (const id of used) {
    const a = assets.get(id);
    if (!a) throw new Error(`Missing image data for asset ${id}`);
    const path = `images/${id}.${a.mime === 'image/jpeg' ? 'jpg' : 'png'}`;
    files[path] = new Uint8Array(a.bytes);
    index.push({ id, width: a.width, height: a.height, mime: a.mime, path });
  }
  const json: ProjectJson = { generator: GENERATOR, formatVersion: FORMAT_VERSION, doc, assets: index };
  files['project.json'] = strToU8(JSON.stringify(json));
  // PNG/JPEG are already compressed: store them, deflate only the JSON.
  return zipSync(
    Object.fromEntries(Object.entries(files).map(([k, v]) => [k, [v, { level: k.endsWith('.json') ? 6 : 0 }]])) as Record<string, [Uint8Array, { level: 0 | 6 }]>,
  );
}

export class ProjectFileError extends Error {}

export function readProject(bytes: Uint8Array): { doc: Doc; assets: Map<Id, Asset> } {
  let files: Record<string, Uint8Array>;
  try {
    files = unzipSync(bytes);
  } catch {
    throw new ProjectFileError('This file is not an OpenLive project (not a valid .olive archive).');
  }
  const raw = files['project.json'];
  if (!raw) throw new ProjectFileError('project.json is missing from the archive.');
  let json: ProjectJson;
  try {
    json = JSON.parse(strFromU8(raw));
  } catch {
    throw new ProjectFileError('project.json is not valid JSON.');
  }
  if (typeof json.formatVersion !== 'number') throw new ProjectFileError('project.json has no formatVersion.');
  if (json.formatVersion > FORMAT_VERSION)
    throw new ProjectFileError(`This project was saved by a newer OpenLive (format ${json.formatVersion}); this version reads format ${FORMAT_VERSION}.`);
  const doc = json.doc;
  if (!doc || typeof doc !== 'object' || !doc.nodes || !Array.isArray(doc.rootIds)) throw new ProjectFileError('project.json has no valid document.');
  const problems = validate(doc);
  if (problems.length) throw new ProjectFileError(`The project structure is damaged: ${problems.slice(0, 3).join('; ')}`);
  const assets = new Map<Id, Asset>();
  for (const a of json.assets ?? []) {
    const f = files[a.path];
    if (!f) throw new ProjectFileError(`Image ${a.path} is missing from the archive.`);
    assets.set(a.id, { id: a.id, width: a.width, height: a.height, mime: a.mime, bytes: f.slice().buffer });
  }
  for (const id of referencedImages(doc)) if (!assets.has(id)) throw new ProjectFileError(`A layer references image ${id}, which is not in the archive.`);
  return { doc, assets };
}
