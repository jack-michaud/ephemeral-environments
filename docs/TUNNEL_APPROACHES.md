# Cloudflare Tunnel Approaches - Technical Handoff

This document details the different approaches we tried for exposing ephemeral environments via Cloudflare before settling on Quick Tunnels.

## Goal

Expose docker-compose applications running on EC2 instances to the internet with unique URLs per PR, protected by Cloudflare Access.

## Approach 1: Named Tunnels with Custom Domain DNS

**Concept**: Create named Cloudflare Tunnels via API, configure ingress rules, and create DNS CNAME records pointing to `<tunnel-id>.cfargotunnel.com`.

**Implementation**:
- Lambda creates tunnel via `POST /accounts/{id}/cfd_tunnel`
- Configure tunnel ingress to route `pr-{number}.envs.yourdomain.com` → `http://localhost:80`
- Create DNS CNAME: `pr-{number}.envs.yourdomain.com` → `<tunnel-id>.cfargotunnel.com`
- EC2 runs `cloudflared tunnel run --token <token>`

**Why it failed**:
- Cloudflare API token lacked `Zone:DNS:Edit` permission
- Error: `Authentication error (code 10000)` when creating DNS records
- Would require additional API token permissions or manual DNS zone setup

**Code location**: `src/deployer/cloudflare_api.py` - `create_dns_record()` method

---

## Approach 2: Workers.dev Subdomain Routing

**Concept**: Use a Cloudflare Worker on `*.lomz.workers.dev` to proxy requests to the tunnel based on subdomain.

**Implementation**:
- Create tunnel-router Worker that extracts tunnel ID from subdomain
- Route `https://<tunnel-id>.lomz.workers.dev` → fetch to `https://<tunnel-id>.cfargotunnel.com`
- No DNS records needed since workers.dev is automatic

**Why it failed**:
- Workers cannot fetch to `*.cfargotunnel.com` directly
- Error 1102: "DNS points to local or disallowed IPv6 address"
- Cloudflare blocks Workers from fetching to internal tunnel endpoints
- The `*.cfargotunnel.com` hostnames are only routable via DNS CNAME, not direct fetch

**Code location**: `worker/tunnel-router/` (abandoned)

---

## Approach 3: Quick Tunnels (trycloudflare.com) ✅

**Concept**: Use Cloudflare's free Quick Tunnel feature which automatically provisions a random `*.trycloudflare.com` URL.

**Implementation**:
```bash
cloudflared tunnel --url http://localhost:80 > /tmp/cloudflared.log 2>&1 &
# Wait for URL to appear in logs
TUNNEL_URL=$(grep -o 'https://[a-zA-Z0-9-]*\.trycloudflare\.com' /tmp/cloudflared.log)
```

**Why it works**:
- No API calls needed to create tunnels
- No DNS configuration required
- URL is automatically generated and publicly routable
- cloudflared handles everything locally

**Trade-offs**:
- URLs are random (e.g., `https://item-dietary-resume-symbols.trycloudflare.com`)
- Cannot use custom domains without DNS setup
- Tunnel ID is extracted from URL subdomain for reference only

**Code location**: `src/deployer/ssm_commands.py` - `run_start_environment()` method

---

## Key Learnings

### 1. cfargotunnel.com is not directly routable
The `*.cfargotunnel.com` hostnames only work when:
- You have a DNS CNAME pointing to them from a domain you control
- The request comes through Cloudflare's proxy (orange cloud)

They do NOT work:
- Direct browser access to `https://<id>.cfargotunnel.com`
- Fetch from Cloudflare Workers
- Any non-proxied request

### 2. Named Tunnels require DNS or Access Applications
To use named tunnels without custom DNS, you need:
- Cloudflare Access Application with the tunnel hostname
- Or a proxied DNS record

### 3. Quick Tunnels are ideal for ephemeral use cases
- Zero configuration
- Automatic cleanup when process exits
- No API token permissions needed
- Perfect for short-lived environments

### 4. SSM script output parsing
When running cloudflared via SSM, the tunnel URL appears in stderr/stdout. Key considerations:
- Use `2>&1` to capture both streams
- grep regex must handle the random subdomain format
- Allow 30 seconds for tunnel URL to appear in logs

---

## URL Format Comparison

| Approach | URL Format | Example |
|----------|------------|---------|
| Named + DNS | `https://pr-{n}.envs.{domain}` | `https://pr-25.envs.example.com` |
| Quick Tunnel | `https://{random}.trycloudflare.com` | `https://item-dietary-resume-symbols.trycloudflare.com` |

---

## Future Improvements

If custom domains are needed later:
1. Add `Zone:DNS:Edit` permission to Cloudflare API token
2. Re-enable DNS record creation in `cloudflare_api.py`
3. Configure tunnel ingress with custom hostname
4. Or use Cloudflare Access Applications with tunnel routing

For now, Quick Tunnels provide the simplest path with zero DNS configuration.
