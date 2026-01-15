/**
 * Ephemeral Environments - GitHub Webhook Handler
 *
 * This Cloudflare Worker receives GitHub pull_request webhooks and
 * sends messages to SQS for processing by the deploy Lambda.
 */

import { SQSClient, SendMessageCommand } from '@aws-sdk/client-sqs';

interface Env {
  GITHUB_WEBHOOK_SECRET: string;
  AWS_ACCESS_KEY_ID: string;
  AWS_SECRET_ACCESS_KEY: string;
  AWS_REGION: string;
  SQS_QUEUE_URL: string;
}

interface PullRequestEvent {
  action: string;
  number: number;
  pull_request: {
    id: number;
    number: number;
    title: string;
    head: {
      ref: string;  // branch name
      sha: string;  // commit SHA
      repo: {
        full_name: string;  // owner/repo
        clone_url: string;
        private: boolean;
      };
    };
    base: {
      ref: string;
    };
    user: {
      login: string;
    };
    html_url: string;
  };
  repository: {
    full_name: string;
    clone_url: string;
    private: boolean;
  };
  sender: {
    login: string;
  };
}

// Verify GitHub webhook signature
async function verifySignature(
  payload: string,
  signature: string | null,
  secret: string
): Promise<boolean> {
  if (!signature) return false;

  const encoder = new TextEncoder();
  const key = await crypto.subtle.importKey(
    'raw',
    encoder.encode(secret),
    { name: 'HMAC', hash: 'SHA-256' },
    false,
    ['sign']
  );

  const signatureBytes = await crypto.subtle.sign(
    'HMAC',
    key,
    encoder.encode(payload)
  );

  const expectedSignature = 'sha256=' + Array.from(new Uint8Array(signatureBytes))
    .map(b => b.toString(16).padStart(2, '0'))
    .join('');

  return signature === expectedSignature;
}

// Send message to SQS
async function sendToSQS(env: Env, message: object): Promise<void> {
  const client = new SQSClient({
    region: env.AWS_REGION,
    credentials: {
      accessKeyId: env.AWS_ACCESS_KEY_ID,
      secretAccessKey: env.AWS_SECRET_ACCESS_KEY,
    },
  });

  const command = new SendMessageCommand({
    QueueUrl: env.SQS_QUEUE_URL,
    MessageBody: JSON.stringify(message),
  });

  await client.send(command);
}

export default {
  async fetch(request: Request, env: Env): Promise<Response> {
    // Only accept POST requests
    if (request.method !== 'POST') {
      return new Response('Method not allowed', { status: 405 });
    }

    // Get the GitHub event type
    const eventType = request.headers.get('X-GitHub-Event');
    if (!eventType) {
      return new Response('Missing X-GitHub-Event header', { status: 400 });
    }

    // We only care about pull_request events
    if (eventType !== 'pull_request') {
      return new Response('Event ignored', { status: 200 });
    }

    // Get the payload
    const payload = await request.text();

    // Verify the signature
    const signature = request.headers.get('X-Hub-Signature-256');
    const isValid = await verifySignature(payload, signature, env.GITHUB_WEBHOOK_SECRET);

    if (!isValid) {
      console.error('Invalid signature');
      return new Response('Invalid signature', { status: 401 });
    }

    // Parse the event
    let event: PullRequestEvent;
    try {
      event = JSON.parse(payload);
    } catch (e) {
      return new Response('Invalid JSON', { status: 400 });
    }

    // Handle the action
    const action = event.action;
    const repo = event.repository.full_name;
    const prNumber = event.pull_request.number;
    const branch = event.pull_request.head.ref;
    const sha = event.pull_request.head.sha;

    console.log(`Received ${action} for ${repo}#${prNumber} (${branch})`);

    // Actions we care about
    const deployActions = ['opened', 'synchronize', 'reopened'];
    const destroyActions = ['closed'];

    if (!deployActions.includes(action) && !destroyActions.includes(action)) {
      console.log(`Ignoring action: ${action}`);
      return new Response('Action ignored', { status: 200 });
    }

    // Build the message for SQS
    const message = {
      action: destroyActions.includes(action) ? 'destroy' : 'deploy',
      repository: {
        fullName: repo,
        cloneUrl: event.repository.clone_url,
        isPrivate: event.repository.private,
      },
      pullRequest: {
        number: prNumber,
        title: event.pull_request.title,
        branch: branch,
        sha: sha,
        author: event.pull_request.user.login,
        url: event.pull_request.html_url,
      },
      sender: event.sender.login,
      timestamp: new Date().toISOString(),
    };

    // Send to SQS
    try {
      await sendToSQS(env, message);
      console.log(`Message sent to SQS for ${repo}#${prNumber}`);
    } catch (error) {
      console.error('Failed to send to SQS:', error);
      return new Response('Failed to queue message', { status: 500 });
    }

    return new Response(JSON.stringify({ status: 'queued', action: message.action }), {
      status: 200,
      headers: { 'Content-Type': 'application/json' },
    });
  },
};
