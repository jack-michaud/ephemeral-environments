"""
Cloudflare API Manager - Handles Tunnel and Access operations.
"""

import json
import logging
import requests

logger = logging.getLogger(__name__)

CF_API_BASE = "https://api.cloudflare.com/client/v4"


class CloudflareManager:
    def __init__(self, api_token: str, account_id: str, zone_id: str = None, domain: str = None):
        self.api_token = api_token
        self.account_id = account_id
        self.zone_id = zone_id  # Zone ID for DNS records
        self.domain = domain    # Domain for tunnel hostnames (e.g., "hearingcenternh.com")
        self.headers = {
            "Authorization": f"Bearer {api_token}",
            "Content-Type": "application/json"
        }

    def _request(self, method: str, endpoint: str, data: dict = None) -> dict:
        """Make a request to the Cloudflare API."""
        url = f"{CF_API_BASE}{endpoint}"
        response = requests.request(
            method,
            url,
            headers=self.headers,
            json=data
        )

        result = response.json()
        if not result.get('success', False):
            errors = result.get('errors', [])
            raise Exception(f"Cloudflare API error: {errors}")

        return result.get('result', {})

    def get_tunnel_by_name(self, name: str) -> dict:
        """Find an existing tunnel by name."""
        url = f"{CF_API_BASE}/accounts/{self.account_id}/cfd_tunnel"
        response = requests.get(url, headers=self.headers, params={"name": name})
        result = response.json()

        if result.get('success') and result.get('result'):
            for tunnel in result['result']:
                if tunnel['name'] == name and tunnel.get('deleted_at') is None:
                    return tunnel
        return None

    def create_tunnel(self, name: str) -> tuple:
        """
        Create a new Cloudflare Tunnel, or reuse existing one with same name.
        Returns: (tunnel_id, tunnel_token)
        """
        # Check if tunnel already exists
        existing = self.get_tunnel_by_name(name)
        if existing:
            tunnel_id = existing['id']
            logger.info(f"Found existing tunnel: {tunnel_id}")
            # Delete and recreate to get fresh token
            self.delete_tunnel(tunnel_id)

        # Create tunnel
        data = {"name": name, "config_src": "cloudflare"}
        result = self._request(
            "POST",
            f"/accounts/{self.account_id}/cfd_tunnel",
            data
        )

        tunnel_id = result['id']
        logger.info(f"Created tunnel: {tunnel_id}")

        # Get tunnel token
        token_result = self._request(
            "GET",
            f"/accounts/{self.account_id}/cfd_tunnel/{tunnel_id}/token"
        )
        tunnel_token = token_result

        # Configure tunnel ingress (public hostname routing)
        self.configure_tunnel_ingress(tunnel_id)

        return tunnel_id, tunnel_token

    def get_tunnel_hostname(self, tunnel_id: str) -> str:
        """Get the public hostname for a tunnel."""
        # Use workers.dev subdomain format for public access
        return f"{tunnel_id}.lomz.workers.dev"

    def configure_tunnel_ingress(self, tunnel_id: str):
        """Configure tunnel to route traffic to localhost:80."""
        hostname = self.get_tunnel_hostname(tunnel_id)
        config = {
            "config": {
                "ingress": [
                    {
                        "hostname": hostname,
                        "service": "http://localhost:80"
                    },
                    {
                        "service": "http_status:404"
                    }
                ]
            }
        }

        self._request(
            "PUT",
            f"/accounts/{self.account_id}/cfd_tunnel/{tunnel_id}/configurations",
            config
        )
        logger.info(f"Configured tunnel ingress for {hostname}")

        # Create DNS record pointing hostname to tunnel
        if self.zone_id and self.domain:
            self.create_dns_record(tunnel_id)

    def create_dns_record(self, tunnel_id: str):
        """Create DNS CNAME record pointing to the tunnel."""
        hostname = self.get_tunnel_hostname(tunnel_id)
        subdomain = hostname.replace(f".{self.domain}", "")

        data = {
            "type": "CNAME",
            "name": subdomain,
            "content": f"{tunnel_id}.cfargotunnel.com",
            "proxied": True,
            "ttl": 1  # Auto TTL when proxied
        }

        try:
            result = self._request(
                "POST",
                f"/zones/{self.zone_id}/dns_records",
                data
            )
            logger.info(f"Created DNS record: {hostname} -> {tunnel_id}.cfargotunnel.com")
            return result.get('id')
        except Exception as e:
            logger.warning(f"Failed to create DNS record: {e}")
            return None

    def delete_dns_record(self, tunnel_id: str):
        """Delete DNS record for tunnel."""
        if not self.zone_id or not self.domain:
            return

        hostname = self.get_tunnel_hostname(tunnel_id)

        try:
            # Find the DNS record
            records = self._request(
                "GET",
                f"/zones/{self.zone_id}/dns_records?name={hostname}"
            )
            for record in records if isinstance(records, list) else []:
                if record.get('name') == hostname:
                    self._request(
                        "DELETE",
                        f"/zones/{self.zone_id}/dns_records/{record['id']}"
                    )
                    logger.info(f"Deleted DNS record: {hostname}")
                    break
        except Exception as e:
            logger.warning(f"Failed to delete DNS record: {e}")

    def wait_for_tunnel_connection(self, tunnel_id: str, timeout: int = 60) -> bool:
        """Wait for cloudflared to connect to the tunnel."""
        import time
        start = time.time()
        while time.time() - start < timeout:
            try:
                result = self._request(
                    "GET",
                    f"/accounts/{self.account_id}/cfd_tunnel/{tunnel_id}"
                )
                if result.get('status') == 'healthy':
                    logger.info(f"Tunnel {tunnel_id} is connected")
                    return True
                connections = result.get('connections', [])
                if connections and len(connections) > 0:
                    logger.info(f"Tunnel {tunnel_id} has {len(connections)} connections")
                    return True
            except Exception as e:
                logger.warning(f"Error checking tunnel status: {e}")
            time.sleep(5)
        logger.warning(f"Tunnel {tunnel_id} did not connect within {timeout}s")
        return False

    def delete_tunnel(self, tunnel_id: str):
        """Delete a Cloudflare Tunnel and its DNS record."""
        # Delete DNS record first
        self.delete_dns_record(tunnel_id)

        try:
            # Clean up any connections
            self._request(
                "DELETE",
                f"/accounts/{self.account_id}/cfd_tunnel/{tunnel_id}/connections"
            )
        except Exception as e:
            logger.warning(f"Failed to clean tunnel connections: {e}")

        try:
            self._request(
                "DELETE",
                f"/accounts/{self.account_id}/cfd_tunnel/{tunnel_id}"
            )
            logger.info(f"Deleted tunnel: {tunnel_id}")
        except Exception as e:
            logger.error(f"Failed to delete tunnel {tunnel_id}: {e}")

    def get_tunnel_url(self, tunnel_id: str) -> str:
        """Get the URL for a tunnel."""
        hostname = self.get_tunnel_hostname(tunnel_id)
        return f"https://{hostname}"

    def create_access_application(
        self,
        tunnel_id: str,
        name: str,
        allowed_emails: list = None
    ) -> str:
        """
        Create a Cloudflare Access application to protect the tunnel.
        Returns: application_id
        """
        tunnel_url = self.get_tunnel_url(tunnel_id)

        # Create Access application
        hostname = self.get_tunnel_hostname(tunnel_id)
        app_data = {
            "name": name,
            "domain": hostname,
            "type": "self_hosted",
            "session_duration": "24h",
            "auto_redirect_to_identity": True,
        }

        result = self._request(
            "POST",
            f"/accounts/{self.account_id}/access/apps",
            app_data
        )

        app_id = result['id']
        logger.info(f"Created Access application: {app_id}")

        # Create Access policy for service tokens (used by tests)
        service_token_policy = {
            "name": f"{name}-service-token-policy",
            "decision": "non_identity",
            "include": [{"any_valid_service_token": {}}],
            "precedence": 1,
        }

        try:
            self._request(
                "POST",
                f"/accounts/{self.account_id}/access/apps/{app_id}/policies",
                service_token_policy
            )
            logger.info(f"Created service token policy for {app_id}")
        except Exception as e:
            logger.warning(f"Failed to create service token policy: {e}")

        # Create Access policy for identity-based access
        policy_data = {
            "name": f"{name}-policy",
            "decision": "allow",
            "include": [],
            "precedence": 2,
        }

        # Add email-based access if specified
        if allowed_emails:
            policy_data["include"].append({
                "email": {"email": allowed_emails[0]}  # Primary user
            })

        # Also allow anyone in the account (for team access)
        policy_data["include"].append({
            "everyone": {}
        })

        try:
            self._request(
                "POST",
                f"/accounts/{self.account_id}/access/apps/{app_id}/policies",
                policy_data
            )
            logger.info(f"Created Access policy for {app_id}")
        except Exception as e:
            logger.warning(f"Failed to create Access policy: {e}")

        return app_id

    def delete_access_application(self, tunnel_id: str):
        """Delete Access application for a tunnel."""
        try:
            # Find application by domain
            result = self._request(
                "GET",
                f"/accounts/{self.account_id}/access/apps"
            )

            hostname = self.get_tunnel_hostname(tunnel_id)
            for app in result:
                if app.get('domain') == hostname:
                    self._request(
                        "DELETE",
                        f"/accounts/{self.account_id}/access/apps/{app['id']}"
                    )
                    logger.info(f"Deleted Access application: {app['id']}")
                    break
        except Exception as e:
            logger.warning(f"Failed to delete Access application: {e}")

    def create_service_token(self, name: str) -> tuple:
        """
        Create a service token for API access (bypasses OAuth).
        Returns: (client_id, client_secret)
        """
        data = {"name": name}
        result = self._request(
            "POST",
            f"/accounts/{self.account_id}/access/service_tokens",
            data
        )

        return result['client_id'], result['client_secret']
