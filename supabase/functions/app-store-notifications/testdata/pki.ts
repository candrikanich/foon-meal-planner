// A throwaway test PKI, made fresh each test run with Web Crypto so no key is ever committed: root -> intermediate ->
// leaf, P-256 and ECDSA-SHA256 like Apple's, with the marker extensions Apple's chain has (1.2.840.113635.100.6.2.1 on the
// intermediate, 1.2.840.113635.100.6.11.1 on the leaf). Production trusts only Apple Root CA - G3, never this root.

const concat = (parts: Uint8Array[]): Uint8Array<ArrayBuffer> => {
  const out = new Uint8Array(parts.reduce((n, p) => n + p.length, 0));
  let offset = 0;
  for (const part of parts) {
    out.set(part, offset);
    offset += part.length;
  }
  return out;
};

function length(n: number): Uint8Array {
  if (n < 0x80) return Uint8Array.of(n);
  const bytes: number[] = [];
  for (let rest = n; rest > 0; rest >>= 8) bytes.unshift(rest & 0xff);
  return Uint8Array.of(0x80 | bytes.length, ...bytes);
}

const tlv = (tag: number, ...parts: Uint8Array[]) => {
  const body = concat(parts);
  return concat([Uint8Array.of(tag), length(body.length), body]);
};
const sequence = (...parts: Uint8Array[]) => tlv(0x30, ...parts);
const ascii = (text: string) => new TextEncoder().encode(text);

function integer(bytes: Uint8Array): Uint8Array {
  let start = 0;
  while (start < bytes.length - 1 && bytes[start] === 0) start++;
  const trimmed = bytes.slice(start);
  return tlv(0x02, trimmed[0] & 0x80 ? concat([Uint8Array.of(0), trimmed]) : trimmed);
}

function oid(dotted: string): Uint8Array {
  const [first, second, ...rest] = dotted.split(".").map(Number);
  const body = [40 * first + second];
  for (const arc of rest) {
    const chunk = [arc & 0x7f];
    for (let value = arc >> 7; value > 0; value >>= 7) chunk.unshift(0x80 | (value & 0x7f));
    body.push(...chunk);
  }
  return tlv(0x06, Uint8Array.from(body));
}

const ecdsaWithSHA256 = sequence(oid("1.2.840.10045.4.3.2"));
const name = (commonName: string) => sequence(tlv(0x31, sequence(oid("2.5.4.3"), tlv(0x0c, ascii(commonName)))));
const extension = (id: string, critical: boolean, value: Uint8Array) =>
  sequence(oid(id), ...(critical ? [tlv(0x01, Uint8Array.of(0xff))] : []), tlv(0x04, value));
const isCA = extension("2.5.29.19", true, sequence(tlv(0x01, Uint8Array.of(0xff))));
const appleMarker = (id: string) => extension(id, false, Uint8Array.of(0x05, 0x00));

// Web Crypto signs ECDSA as raw r||s; X.509 wants SEQUENCE { INTEGER r, INTEGER s }.
const derSignature = (raw: Uint8Array) => sequence(integer(raw.slice(0, 32)), integer(raw.slice(32)));

const keyPair = () =>
  crypto.subtle.generateKey({ name: "ECDSA", namedCurve: "P-256" }, true, ["sign", "verify"]) as Promise<CryptoKeyPair>;

async function certificate(
  serial: number,
  subject: string,
  issuer: string,
  publicKey: CryptoKey,
  signingKey: CryptoKey,
  extensions: Uint8Array[],
): Promise<Uint8Array<ArrayBuffer>> {
  const tbs = sequence(
    tlv(0xa0, integer(Uint8Array.of(2))),
    integer(Uint8Array.of(serial)),
    ecdsaWithSHA256,
    name(issuer),
    sequence(tlv(0x17, ascii("200101000000Z")), tlv(0x18, ascii("21000101000000Z"))),
    name(subject),
    new Uint8Array(await crypto.subtle.exportKey("spki", publicKey)),
    tlv(0xa3, sequence(...extensions)),
  );
  const raw = new Uint8Array(await crypto.subtle.sign({ name: "ECDSA", hash: "SHA-256" }, signingKey, tbs));
  return sequence(tbs, ecdsaWithSHA256, tlv(0x03, Uint8Array.of(0), derSignature(raw)));
}

export interface TestPki {
  rootDer: Uint8Array<ArrayBuffer>;
  intermediateDer: Uint8Array<ArrayBuffer>;
  leafDer: Uint8Array<ArrayBuffer>;
  leafKey: CryptoKey;
}

export async function makeTestPki(): Promise<TestPki> {
  const [root, intermediate, leaf] = await Promise.all([keyPair(), keyPair(), keyPair()]);
  const rootName = "Foon Test Root";
  const intermediateName = "Foon Test Intermediate";
  return {
    rootDer: await certificate(1, rootName, rootName, root.publicKey, root.privateKey, [isCA]),
    intermediateDer: await certificate(2, intermediateName, rootName, intermediate.publicKey, root.privateKey, [
      isCA,
      appleMarker("1.2.840.113635.100.6.2.1"),
    ]),
    leafDer: await certificate(3, "Foon Test Leaf", intermediateName, leaf.publicKey, intermediate.privateKey, [
      appleMarker("1.2.840.113635.100.6.11.1"),
    ]),
    leafKey: leaf.privateKey,
  };
}

export const testPki = await makeTestPki();
