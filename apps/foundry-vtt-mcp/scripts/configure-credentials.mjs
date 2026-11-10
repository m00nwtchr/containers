import { randomUUID } from 'node:crypto';
import { mkdir, rename, rm, writeFile } from 'node:fs/promises';
import { dirname } from 'node:path';

function required(name) {
  const value = process.env[name];
  if (!value) throw new Error(`Required environment variable is missing: ${name}`);
  return value;
}

// Any FOUNDRY_<INSTANCE>_<FIELD> variable defines an instance.
// For example: FOUNDRY_MY_WORLD_HOSTNAME, FOUNDRY_MY_WORLD_PASSWORD, etc.
const instanceFields = /^(?:FOUNDRY_)([A-Z][A-Z0-9_]*)_(HOSTNAME|USERNAME|USERID|PASSWORD|ALLOW_INSECURE_TLS)$/;
const instances = new Set();

for (const name of Object.keys(process.env)) {
  const match = instanceFields.exec(name);
  if (match) instances.add(match[1]);
}

if (instances.size === 0) {
  throw new Error('No Foundry instances configured. Set FOUNDRY_<INSTANCE>_HOSTNAME, USERNAME/USERID, and PASSWORD.');
}

const credentials = [...instances].sort().map((instance) => {
  const prefix = `FOUNDRY_${instance}_`;
  const username = process.env[`${prefix}USERNAME`]?.trim();
  const userid = process.env[`${prefix}USERID`]?.trim();

  if (!username && !userid) {
    throw new Error(`Set either ${prefix}USERNAME or ${prefix}USERID`);
  }

  const tls = (process.env[`${prefix}ALLOW_INSECURE_TLS`] ?? 'false').toLowerCase();

  if (tls !== 'true' && tls !== 'false') {
    throw new Error(`${prefix}ALLOW_INSECURE_TLS must be true or false`);
  }

  return {
    _id: instance.toLowerCase(),
    hostname: required(`${prefix}HOSTNAME`),
    ...(username ? { username } : {}),
    ...(userid ? { userid } : {}),
    password: required(`${prefix}PASSWORD`),
    allow_insecure_tls: tls === 'true',
  };
});

const output = process.env.FOUNDRY_CREDENTIALS || '/tmp/foundry_credentials.json';

await mkdir(dirname(output), { recursive: true });

const temporary = `${output}.${process.pid}.${randomUUID()}.tmp`;

try {
  await writeFile(temporary, `${JSON.stringify(credentials, null, 2)}\n`, {
    mode: 0o600,
    flag: 'wx',
  });
  await rename(temporary, output);
} finally {
  await rm(temporary, { force: true });
}
