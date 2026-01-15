/**
 * Tunnel Router Worker
 *
 * Routes requests to Cloudflare Tunnels via path-based routing:
 * https://tunnel-router.lomz.workers.dev/t/{tunnel-id}/{path}
 *
 * This proxies to {tunnel-id}.cfargotunnel.com/{path}
 */

export interface Env {}

export default {
  async fetch(request: Request, env: Env): Promise<Response> {
    const url = new URL(request.url);
    const pathname = url.pathname;

    // Extract tunnel ID from path: /t/{tunnel-id}/...
    const tunnelMatch = pathname.match(/^\/t\/([a-f0-9-]+)(\/.*)?$/i);

    if (!tunnelMatch) {
      return new Response(JSON.stringify({
        error: 'Invalid path',
        usage: '/t/{tunnel-id}/{optional-path}',
        example: '/t/abc123-def456-ghi789/api/health'
      }), {
        status: 400,
        headers: { 'Content-Type': 'application/json' }
      });
    }

    const tunnelId = tunnelMatch[1];
    const targetPath = tunnelMatch[2] || '/';

    // Proxy to the actual tunnel URL
    const tunnelHostname = `${tunnelId}.cfargotunnel.com`;
    const tunnelUrl = `https://${tunnelHostname}${targetPath}${url.search}`;

    // Create new headers with the correct Host
    const proxyHeaders = new Headers(request.headers);
    proxyHeaders.set('Host', tunnelHostname);
    // Remove CF headers that shouldn't be forwarded
    proxyHeaders.delete('CF-Connecting-IP');
    proxyHeaders.delete('CF-Ray');
    proxyHeaders.delete('CF-IPCountry');

    // Forward the request to the tunnel
    const proxyRequest = new Request(tunnelUrl, {
      method: request.method,
      headers: proxyHeaders,
      body: request.body,
      redirect: 'manual',
    });

    try {
      const response = await fetch(proxyRequest);

      // Return the response from the tunnel
      return new Response(response.body, {
        status: response.status,
        statusText: response.statusText,
        headers: response.headers,
      });
    } catch (error) {
      return new Response(`Tunnel proxy error: ${error}`, { status: 502 });
    }
  },
};
