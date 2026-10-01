-- 05: credentials and people. EDIT BEFORE RUNNING: replace every <...> placeholder.
-- Run as SECURITYADMIN. Don't commit the edited copy (public keys aren't secret, but your edits
-- will also name real users).
--
-- 1. Generate one key pair per service user, on your machine (never in the repo):
--      openssl genrsa 2048 | openssl pkcs8 -topk8 -inform PEM -out svc_loader.p8 -nocrypt
--      openssl rsa -in svc_loader.p8 -pubout -out svc_loader.pub
--    Repeat for svc_dbt_prod and svc_dbt_ci.
-- 2. Paste the body of each .pub file (without the BEGIN/END lines) below.
-- 3. Store each .p8 file's full contents as a GitHub Actions secret (see docs/CI_CD.md).
--
-- To rotate a key without downtime: set RSA_PUBLIC_KEY_2 to the new key, switch the secret,
-- then unset RSA_PUBLIC_KEY.
use role securityadmin;

alter user svc_loader   set rsa_public_key = '<svc_loader public key>';
alter user svc_dbt_prod set rsa_public_key = '<svc_dbt_prod public key>';
alter user svc_dbt_ci   set rsa_public_key = '<svc_dbt_ci public key>';

-- People keep their own user and their own login (SSO or password + MFA). They get roles, never
-- the service users' keys.
grant role developer to user <your_snowflake_user>;
-- grant role reporter to user <analyst_user>;
