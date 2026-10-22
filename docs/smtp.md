# Outgoing mail (SMTP)

SMTP lets Authelia send password-reset mail and lets Nextcloud and Forgejo
send notifications. It's **off by default** and set up per host.

## Enable it

In `host_vars/<host>/vars.yml`:

```yaml
enable_smtp: true
smtp_host: "smtp-relay.brevo.com"
smtp_port: 587
smtp_security: "starttls"            # starttls (587) | tls (465) | none (25)
smtp_from: "noreply@yourdomain.com"  # default: noreply@<domain>; must be on a domain the relay has verified
```

In `host_vars/<host>/vault.yml`:

```yaml
vault_smtp_user:     "your-relay-login"
vault_smtp_password: "your-relay-password-or-api-key"
```

Then deploy the roles that send mail:
`./deploy.sh --limit <host> --tags authelia,nextcloud,forgejo`.

Without SMTP, Authelia writes reset links to a file instead; see
[runbook.md](runbook.md#password-reset-mail).

## Choosing a relay

Mail sent straight from the server's IP is rejected by most providers, so use
a relay. **[Brevo](https://www.brevo.com)**'s free tier allows 300 mails a day
with SMTP relay, which is plenty for resets and notifications.

Since February 2024 the big mail providers drop mail whose sender domain
lacks **SPF, DKIM and DMARC**. So `smtp_from` must be on a domain whose DNS
you control. A `polimi.it` subdomain won't work unless Polimi IT adds the
records.

## Brevo setup

1. Create an account at [brevo.com](https://www.brevo.com).
2. Settings → Senders & IP → Domains → **Add a domain** (one you control).
3. Add the SPF, DKIM and DMARC records Brevo shows at your DNS provider.
   - **SPF:** merge into the existing record. Never two SPF TXT records on
     one name, e.g. `v=spf1 include:_spf.aruba.it include:spf.brevo.com ~all`.
   - **DMARC:** if one exists, merge into it.
4. Click **Verify** in Brevo (usually 15–30 minutes, up to 48 hours).
5. Settings → SMTP & API → SMTP → **Generate a new SMTP key**. It's shown
   only once.
6. Security → Authorized IPs: add the server's public IP
   (`curl -sS https://api.ipify.org` on the server), then turn on IP
   blocking.
7. Fill in `vars.yml` and the vault as above, and deploy.

## Test the relay before deploying

From the server, so the authorized-IP check applies:

```bash
swaks \
  --to 'you@example.com' \
  --from 'noreply@yourdomain.com' \
  --server smtp-relay.brevo.com \
  --port 587 --tls \
  --auth LOGIN \
  --auth-user 'your-brevo-login' \
  --auth-password 'your-smtp-key' \
  --header 'Subject: SMTP test' \
  --body 'Relay is working.'
```

Brevo's dashboard (Transactional → Email → Logs) shows every message with
its recipient and status (Delivered, Bounced, Blocked).
