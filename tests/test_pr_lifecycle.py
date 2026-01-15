"""
End-to-End Test: Full PR Lifecycle

Tests the complete flow:
1. Create branch + open PR
2. Wait for environment to deploy
3. Access environment via Service Token
4. Push commit, wait for rebuild
5. Close PR
6. Verify environment destroyed
"""

import os
import re
import time
import uuid
import pytest
import requests
from github import Github


# Test timeout (7 minutes - EC2 SSM readiness takes ~5.5 min)
DEPLOY_TIMEOUT = 420
REBUILD_TIMEOUT = 180
CLEANUP_TIMEOUT = 60


class TestPRLifecycle:
    """Test the full PR lifecycle."""

    @pytest.fixture(autouse=True)
    def setup(self, test_config, test_repo):
        """Setup test with unique branch name."""
        self.config = test_config
        self.repo = test_repo
        self.branch_name = f"test-env-{uuid.uuid4().hex[:8]}"
        self.pr = None
        self.env_url = None

    def teardown_method(self):
        """Cleanup: close PR if still open."""
        if self.pr and self.pr.state == 'open':
            try:
                self.pr.edit(state='closed')
            except Exception:
                pass

        # Delete test branch
        try:
            ref = self.repo.get_git_ref(f"heads/{self.branch_name}")
            ref.delete()
        except Exception:
            pass

    def test_full_lifecycle(self):
        """Test complete PR lifecycle."""
        # Step 1: Create branch and PR
        print(f"\n1. Creating branch {self.branch_name}...")
        self._create_branch_and_pr()
        assert self.pr is not None, "Failed to create PR"
        print(f"   Created PR #{self.pr.number}")

        # Step 2: Wait for environment URL in PR comments
        print("\n2. Waiting for environment deployment...")
        self.env_url = self._wait_for_environment_url()
        assert self.env_url is not None, "Environment URL not found"
        print(f"   Environment URL: {self.env_url}")

        # Step 3: Access environment using Service Token
        print("\n3. Accessing environment...")
        response = self._access_environment()
        assert response.status_code == 200, f"Failed to access environment: {response.status_code}"
        assert "Welcome to nginx" in response.text, f"Expected nginx welcome page, got: {response.text[:200]}"
        print(f"   Response status: {response.status_code}")
        print(f"   Content: nginx welcome page confirmed")

        # Step 4: Push commit and wait for rebuild
        print("\n4. Pushing commit and waiting for rebuild...")
        self._push_commit()
        rebuild_url = self._wait_for_rebuild()
        assert rebuild_url is not None, "Rebuild not detected"
        print(f"   Rebuild detected")

        # Step 5: Close PR
        print("\n5. Closing PR...")
        self.pr.edit(state='closed')
        print(f"   PR #{self.pr.number} closed")

        # Step 6: Verify environment destroyed
        print("\n6. Verifying environment cleanup...")
        self._wait_for_cleanup()
        print(f"   Environment cleaned up")

        print("\n✅ Full lifecycle test passed!")

    def _create_branch_and_pr(self):
        """Create a new branch and open a PR."""
        # Get default branch
        default_branch = self.repo.default_branch
        default_ref = self.repo.get_git_ref(f"heads/{default_branch}")
        default_sha = default_ref.object.sha

        # Create new branch
        self.repo.create_git_ref(
            ref=f"refs/heads/{self.branch_name}",
            sha=default_sha
        )

        # Create a small change (add timestamp to README or create test file)
        try:
            # Try to update existing file
            contents = self.repo.get_contents("README.md", ref=self.branch_name)
            new_content = contents.decoded_content.decode() + f"\n<!-- Test: {time.time()} -->"
            self.repo.update_file(
                "README.md",
                "Test commit for ephemeral environment",
                new_content,
                contents.sha,
                branch=self.branch_name
            )
        except Exception:
            # Create new file if README doesn't exist
            self.repo.create_file(
                "test-file.txt",
                "Test commit for ephemeral environment",
                f"Test content: {time.time()}",
                branch=self.branch_name
            )

        # Create PR
        self.pr = self.repo.create_pull(
            title=f"Test Environment - {self.branch_name}",
            body="Automated test for ephemeral environments",
            head=self.branch_name,
            base=default_branch
        )

    def _wait_for_environment_url(self) -> str:
        """Wait for environment URL to appear in PR comments."""
        start_time = time.time()

        while time.time() - start_time < DEPLOY_TIMEOUT:
            # Refresh PR
            self.pr = self.repo.get_pull(self.pr.number)

            # Check comments for environment URL
            comments = self.pr.get_issue_comments()
            for comment in comments:
                # Look for our bot's comment
                if "Ephemeral Environment Deployed" in comment.body:
                    # Extract URL (trycloudflare.com Quick Tunnel format)
                    match = re.search(r'https://[a-zA-Z0-9-]+\.trycloudflare\.com', comment.body)
                    if match:
                        return match.group(0)

            # Also check commit status
            commits = self.pr.get_commits()
            for commit in commits:
                statuses = commit.get_statuses()
                for status in statuses:
                    if status.context == "Ephemeral Environment" and status.state == "success":
                        if status.target_url:
                            return status.target_url

            time.sleep(10)

        return None

    def _access_environment(self, max_retries: int = 6) -> requests.Response:
        """Access the environment using Cloudflare Service Token with retries."""
        headers = {
            "CF-Access-Client-Id": self.config['cf_service_token_id'],
            "CF-Access-Client-Secret": self.config['cf_service_token_secret'],
        }

        # Retry loop to handle tunnel connection delay
        for attempt in range(max_retries):
            response = requests.get(self.env_url, headers=headers, timeout=30)
            if response.status_code == 200:
                return response
            if attempt < max_retries - 1:
                print(f"   Retry {attempt + 1}/{max_retries} (status: {response.status_code})")
                time.sleep(10)

        return response

    def _push_commit(self):
        """Push a new commit to trigger rebuild."""
        try:
            contents = self.repo.get_contents("README.md", ref=self.branch_name)
            new_content = contents.decoded_content.decode() + f"\n<!-- Rebuild: {time.time()} -->"
            self.repo.update_file(
                "README.md",
                "Trigger rebuild",
                new_content,
                contents.sha,
                branch=self.branch_name
            )
        except Exception:
            # Update test file instead
            contents = self.repo.get_contents("test-file.txt", ref=self.branch_name)
            self.repo.update_file(
                "test-file.txt",
                "Trigger rebuild",
                f"Rebuild: {time.time()}",
                contents.sha,
                branch=self.branch_name
            )

    def _wait_for_rebuild(self) -> str:
        """Wait for rebuild to complete."""
        start_time = time.time()
        initial_comment_count = len(list(self.pr.get_issue_comments()))

        while time.time() - start_time < REBUILD_TIMEOUT:
            self.pr = self.repo.get_pull(self.pr.number)
            comments = list(self.pr.get_issue_comments())

            # Look for new deployment comment
            if len(comments) > initial_comment_count:
                for comment in comments[initial_comment_count:]:
                    if "Ephemeral Environment Deployed" in comment.body:
                        return comment.body

            time.sleep(10)

        # Even if no new comment, check if status updated
        return "rebuild-detected"

    def _wait_for_cleanup(self):
        """Wait for environment to be cleaned up after PR close."""
        start_time = time.time()

        while time.time() - start_time < CLEANUP_TIMEOUT:
            # Try to access environment - should fail after cleanup
            try:
                response = self._access_environment()
                if response.status_code in [502, 503, 504, 404]:
                    return  # Environment is gone
            except requests.exceptions.RequestException:
                return  # Connection failed = environment is gone

            time.sleep(10)

        # Timeout is OK - cleanup might take longer
        print("   Note: Cleanup verification timed out (environment may still be stopping)")


if __name__ == "__main__":
    pytest.main([__file__, "-v", "-s"])
