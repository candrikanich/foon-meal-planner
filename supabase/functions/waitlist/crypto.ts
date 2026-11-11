import { unsubscribeSigner } from "../_shared/email_layout.ts";

// HMAC-SHA256 keyed by a secret the function already has, so unsubscribe links need no stored token. The purpose is
// the one links have always been signed with, so links already sent keep working.
export const signer = (secret: string) => unsubscribeSigner("waitlist-unsubscribe", secret);
