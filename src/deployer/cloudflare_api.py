"""
Cloudflare API Manager - Handles Tunnel and Access operations.
"""

import json
import logging
import requests

logger = logging.getLogger(__name__)

CF_API_BASE = "https://api.cloudflare.com/client/v4"


class CloudflareManager:
    def __init__(self, api_token: str, account_id: str):
        self.api_token = api_token
        self.account_id = account_id
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

    def create_tunnel(self, name: str) -> tuple:
        """
        Create a new Cloudflare Tunnel.
        Returns: (tunnel_id, tunnel_token)
        """
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

        return tunnel_id, tunnel_token

    def delete_tunnel(self, tunnel_id: str):
        """Delete a Cloudflare Tunnel."""
        try:
            # First, clean up any connections
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
        return f"https://{tunnel_id}.cfargotunnel.com"

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
        app_data = {
            "name": name,
            "domain": f"{tunnel_id}.cfargotunnel.com",
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

        # Create Access policy
        policy_data = {
            "name": f"{name}-policy",
            "decision": "allow",
            "include": [],
            "precedence": 1,
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

            domain = f"{tunnel_id}.cfargotunnel.com"
            for app in result:
                if app.get('domain') == domain:
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
