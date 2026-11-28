// The backend's own command line, for every hint that asks a person to run it.
// The script path is absolute, so a hint copied out of the reader's status line
// runs from any shell.
import path from 'node:path';
import { fileURLToPath } from 'node:url';

export const SCRIPT = path.resolve(fileURLToPath(import.meta.url), '../../weread.mjs');
export const CLI_DIR = path.dirname(SCRIPT);

const quote = (value) => (/^[A-Za-z0-9_@%+=:,./-]+$/.test(value) ? value : `"${value}"`);

/** The command that runs this backend: `node "/…/backends/weread/weread.mjs"`. */
export const cliCommand = () => `node ${quote(SCRIPT)}`;
