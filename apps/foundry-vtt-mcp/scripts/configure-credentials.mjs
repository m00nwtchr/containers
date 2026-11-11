import { randomUUID } from 'node:crypto';
import { access, mkdir, rename, rm, writeFile } from 'node:fs/promises';
import { dirname } from 'node:path';

function required(name) {
  const value = process.env[name];
  if (!value || !value.trim()) throw new Error(`Required environment variable is missing: ${name}`);
  return value;
}

// FOUNDRY_<INSTANCE>_<FIELD> variables configure an instance.
// An instance is complete with HOSTNAME, USERNAME or USERID, and PASSWORD.
const instanceFields = /^(?:FOUNDRY_)([A-Z][A-Z0-9_]*)_(HOSTNAME|USERNAME|USERID|PASSWORD|ALLOW_INSECURE_TLS)$/;
const configuredInstances = new Set();

for (const name of Object.keys(process.env)) {
  const match = instanceFields.exec(name);
  if (match) configuredInstances.add(match[1]);
}

const credentialsPath = process.env.FOUNDRY_CREDENTIALS || '/tmp/foundry_credentials.json';

const instances = [...configuredInstances].filter((instance) => {
  const prefix = `FOUNDRY_${instance}_`;
  const hasIdentity = process.env[`${prefix}USERNAME`]?.trim() || process.env[`${prefix}USERID`]?.trim();
  return Boolean(
    process.env[`${prefix}HOSTNAME`]?.trim()
      && hasIdentity
      && process.env[`${prefix}PASSWORD`]?.trim(),
  );
});

for (const instance of configuredInstances) {
  if (!instances.includes(instance)) {
    console.warn(`Ignoring incomplete Foundry instance ${instance}: set FOUNDRY_${instance}_HOSTNAME, USERNAME/USERID, and PASSWORD.`);
  }
}

if (instances.length === 0) {
  // Preserve upstream's native mode: a mounted credentials file is read by
  // the server and must not be replaced when no complete env configuration exists.
  try {
    await access(credentialsPath);
    process.exit(0);
  } catch {
    // No existing credentials file; report the missing configuration below.
  }

  throw new Error('No Foundry instances configured. Set FOUNDRY_<INSTANCE>_HOSTNAME, USERNAME/USERID, and PASSWORD.');
}

const credentials = instances.sort().map((instance) => {
  const prefix = `FOUNDRY_${instance}_`;
  const username = process.env[`${prefix}USERNAME`]?.trim();
  const userid = process.env[`${prefix}USERID`]?.trim();

  if (!username && !userid) {
    throw new Error(`Set either ${prefix}USERNAME or ${prefix}USERID`);
  }

  const tls = (process.env[`${prefix}ALLOW_INSECURE_TLS`] ?? '').trim().toLowerCase() || 'false';

  if (tls !== 'true' && tls !== 'false') {
    throw new Error(`${prefix}ALLOW_INSECURE_TLS must be true or false`);
  }

  return {
    _id: instance.toLowerCase(),
    hostname: required(`${prefix}HOSTNAME`).trim(),
    ...(username ? { username } : {}),
    ...(userid ? { userid } : {}),
    password: required(`${prefix}PASSWORD`),
    allow_insecure_tls: tls === 'true',
  };
});

const output = credentialsPath;

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
