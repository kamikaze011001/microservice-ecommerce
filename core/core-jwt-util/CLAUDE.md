# core-jwt-util

JWT (RS256) creation + verification helpers. Used by authorization-server (issue) and gateway (verify).

## Layout
- `util/` — encode/decode/verify helpers
- `dto/` — claim payload types
- `constant/` — claim keys, header names

## Convention
Business services do **not** depend on this module. The gateway extracts `userId` from the JWT and forwards it as `X-User-Id`; downstreams read the header. If you find yourself parsing a JWT inside a non-gateway, non-auth service — stop and rethink.

## Keys
RS256 keypair lives in Vault. Public key reaches the gateway via Vault import; private key reaches authorization-server via Vault import. Never commit either.
