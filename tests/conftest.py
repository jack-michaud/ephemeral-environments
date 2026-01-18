"""
Pytest configuration and fixtures for E2E tests.
"""

import os
import pytest
from dotenv import load_dotenv

# Load test environment variables
load_dotenv('.env.test')


@pytest.fixture(scope='session')
def test_config():
    """Get test configuration from environment."""
    config = {
        'github_repo': os.environ.get('TEST_GITHUB_REPO'),
        'github_token': os.environ.get('TEST_GITHUB_TOKEN'),
        'cf_service_token_id': os.environ.get('CF_SERVICE_TOKEN_ID'),
        'cf_service_token_secret': os.environ.get('CF_SERVICE_TOKEN_SECRET'),
        # Direct secret (stored in Secrets Manager manifest)
        'test_repo_secret': os.environ.get('TEST_REPO_SECRET', 'e2e-test-secret-value-12345'),
        # Secrets Manager reference (resolved from separate SM secret)
        'test_sm_secret': os.environ.get('TEST_SM_SECRET', 'e2e-secretsmanager-resolved-value'),
        # SSM Parameter Store reference (resolved from SSM parameter)
        'test_ssm_secret': os.environ.get('TEST_SSM_SECRET', 'e2e-ssm-parameter-resolved-value'),
    }

    # Validate required config (secrets have defaults)
    required = ['github_repo', 'github_token', 'cf_service_token_id', 'cf_service_token_secret']
    missing = [k for k in required if not config.get(k)]
    if missing:
        pytest.skip(f"Missing test config: {', '.join(missing)}")

    return config


@pytest.fixture(scope='session')
def github_client(test_config):
    """Get authenticated GitHub client."""
    from github import Github
    return Github(test_config['github_token'])


@pytest.fixture(scope='session')
def test_repo(github_client, test_config):
    """Get the test repository."""
    return github_client.get_repo(test_config['github_repo'])
